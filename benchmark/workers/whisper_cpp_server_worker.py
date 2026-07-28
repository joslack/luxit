#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def _emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _coerce_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _coerce_int(value: Any, default: int) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _coerce_float(value: Any, default: float) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _normalize_language(value: Any) -> str:
    normalized = str(value or "").strip().lower().replace("_", "-")
    if not normalized:
        return "en"
    return normalized


def _normalize_ms(value: Any) -> float | None:
    try:
        return float(value) * 1000.0
    except (TypeError, ValueError):
        return None


def _to_ms(value: Any) -> int | None:
    try:
        return int(round(float(value) * 1000.0))
    except (TypeError, ValueError):
        return None


def _assert_canonical_wav(audio_path: str) -> None:
    path = Path(audio_path)
    if not path.is_file():
        raise ValueError(f"audio file not found: {audio_path}")
    with wave.open(str(path), "rb") as handle:
        sample_rate = handle.getframerate()
        channels = handle.getnchannels()
        width = handle.getsampwidth()
    if channels != 1:
        raise ValueError(f"Expected mono 16kHz PCM WAV; got channels={channels}")
    if sample_rate != 16_000:
        raise ValueError(f"Expected mono 16kHz PCM WAV; got sample_rate={sample_rate}")
    if width != 2:
        raise ValueError(
            f"Expected mono 16kHz PCM WAV; got sample_width={width} bytes"
        )


def _normalize_segments(values: Any, *, keys: bool = True) -> list[dict[str, Any]]:
    if not isinstance(values, list):
        return []
    out: list[dict[str, Any]] = []
    for item in values:
        if not isinstance(item, dict):
            continue
        text = str(item.get("text", item.get("word", ""))).strip()
        out.append(
            {
                "start_ms": _to_ms(item.get("start")),
                "end_ms": _to_ms(item.get("end")),
                "text": text,
                **({"start": item.get("start"), "end": item.get("end")} if keys else {}),
            }
        )
    return out


def _multipart_request(
    url: str, fields: dict[str, str], audio_path: str, timeout: float = 30.0
) -> tuple[int | None, Any]:
    boundary = f"----whisperbench-{uuid.uuid4().hex}"
    parts: list[bytes] = []
    for key, value in fields.items():
        parts.append(
            f'--{boundary}\r\n'
            f'Content-Disposition: form-data; name="{key}"\r\n'
            f"\r\n{value}\r\n".encode("utf-8")
        )
    audio_data = Path(audio_path).read_bytes()
    parts.append(
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="file"; filename="{Path(audio_path).name}"\r\n'
        f"Content-Type: audio/wav\r\n\r\n".encode("utf-8")
    )
    parts.append(audio_data)
    parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode("utf-8"))
    body = b"".join(parts)
    request = urllib.request.Request(
        url=url,
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace").strip()
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace").strip()
        return error.code, raw
    except urllib.error.URLError as error:
        raise RuntimeError(f"{error.reason}") from error
    if not raw:
        return 200, {}
    try:
        return 200, json.loads(raw)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Non-JSON response from whisper-server: {raw}") from error


def _health_request(url: str, timeout: float = 0.5) -> None:
    request = urllib.request.Request(url=url, method="GET")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status != 200:
            raise RuntimeError(f"health failed with status {response.status}")
        raw = response.read().decode("utf-8", errors="replace").strip()
        payload = json.loads(raw) if raw else {}
        if payload.get("status") != "ok":
            raise RuntimeError(f"health status not ok: {payload!r}")


def _find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@dataclass
class _Profile:
    backend_id: str
    model: str
    model_path: str
    threads: int
    beam_size: int
    best_of: int
    temperature: float
    temperature_fallback: bool
    no_context: bool
    no_timestamps: bool
    supports_prompt: bool
    supports_language_override: bool
    supports_word_timestamps: bool
    flash_attention: bool
    whisper_server_binary: str
    timeout_seconds: float


class WhisperCppServerWorker:
    def __init__(self) -> None:
        self._profile: _Profile | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self._port: int | None = None
        self._load_ms: float | None = None
        self._stderr_file: Any = None

    @property
    def _server_url(self) -> str:
        if self._port is None:
            raise RuntimeError("Server is not started")
        return f"http://127.0.0.1:{self._port}"

    def _build_profile(self, payload: dict[str, Any]) -> _Profile:
        options = payload.get("options", {}) or {}
        model = str(payload.get("model") or options.get("model", "")).strip()
        if not model:
            raise RuntimeError("Missing model")
        model_path = str(payload.get("model_path") or options.get("model_path", "")).strip()
        if not model_path:
            raise RuntimeError("Missing model_path")
        model_file = Path(model_path)
        if not model_file.exists():
            raise RuntimeError(f"Model artifact missing: {model_path}")

        server_binary = str(
            options.get("whisper_server_binary", "whisper-server")
        ).strip()
        if not (shutil.which(server_binary) or model_file.parent.exists() and Path(server_binary).exists()):
            raise RuntimeError(f"Missing command: {server_binary}")

        return _Profile(
            backend_id=str(payload.get("backend_id", "whisper-cpp")),
            model=model,
            model_path=model_path,
            threads=_coerce_int(options.get("threads"), 6),
            beam_size=_coerce_int(options.get("beam_size"), 1),
            best_of=_coerce_int(options.get("best_of"), 1),
            temperature=_coerce_float(options.get("temperature"), 0.0),
            temperature_fallback=_coerce_bool(options.get("temperature_fallback")),
            no_context=_coerce_bool(options.get("no_context")),
            no_timestamps=_coerce_bool(options.get("no_timestamps")),
            supports_prompt=_coerce_bool(options.get("supports_prompt")),
            supports_language_override=_coerce_bool(options.get("supports_language_override")),
            supports_word_timestamps=_coerce_bool(options.get("supports_word_timestamps")),
            flash_attention=_coerce_bool(options.get("flash_attention"), ),
            whisper_server_binary=server_binary,
            timeout_seconds=_coerce_float(options.get("timeout_seconds"), 600),
        )

    def _start_server(self, profile: _Profile) -> None:
        if self._process and self._process.poll() is None and self._port is not None:
            return

        self._stop_server()
        self._port = _find_free_port()
        command = [
            profile.whisper_server_binary,
            "--host",
            "127.0.0.1",
            "--port",
            str(self._port),
            "--model",
            profile.model_path,
            "--threads",
            str(profile.threads),
        ]
        if profile.flash_attention:
            command.append("--flash-attn")
        else:
            command.append("--no-flash-attn")
        if profile.no_context:
            command.extend(["--max-context", "0"])
        if not profile.temperature_fallback:
            command.append("--no-fallback")
        if profile.no_timestamps:
            command.append("--no-timestamps")

        self._stderr_file = tempfile.TemporaryFile(mode="w+", encoding="utf-8")
        self._process = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=self._stderr_file,
            text=True,
        )

        started = time.perf_counter()
        deadline = time.time() + 20.0
        while time.time() < deadline:
            if self._process.poll() is not None:
                stderr = self._read_stderr()
                raise RuntimeError(f"whisper-server exited during startup: {stderr}")
            try:
                _health_request(f"{self._server_url}/health", timeout=0.5)
                self._load_ms = (time.perf_counter() - started) * 1000.0
                return
            except urllib.error.URLError:
                time.sleep(0.05)
                continue
            except RuntimeError as error:
                raise error
        stderr = self._read_stderr()
        raise TimeoutError(f"whisper-server did not become ready: {stderr}")

    def _read_stderr(self) -> str:
        if self._stderr_file is None:
            return ""
        self._stderr_file.flush()
        self._stderr_file.seek(0)
        stderr_output = self._stderr_file.read()
        return stderr_output.strip() if stderr_output else ""

    def _stop_server(self) -> None:
        if not self._process:
            self._port = None
            if self._stderr_file is not None:
                self._stderr_file.close()
                self._stderr_file = None
            return
        try:
            if self._process.poll() is None:
                self._process.terminate()
                try:
                    self._process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait(timeout=2)
        finally:
            self._process = None
            self._port = None
            if self._stderr_file is not None:
                self._stderr_file.close()
                self._stderr_file = None

    def load(self, payload: dict[str, Any]) -> dict[str, Any]:
        profile = self._build_profile(payload)
        same_model = (
            self._profile is not None
            and self._profile.model_path == profile.model_path
            and self._process is not None
            and self._process.poll() is None
        )
        self._profile = profile
        if same_model:
            return {
                "status": "loaded",
                "backend_id": profile.backend_id,
                "model": profile.model,
                "model_path": profile.model_path,
                "load_ms": self._load_ms,
            }
        self._load_ms = None
        start = time.perf_counter()
        self._start_server(profile)
        load_ms = self._load_ms if self._load_ms is not None else (
            time.perf_counter() - start
        ) * 1000.0
        self._load_ms = load_ms
        return {
            "status": "loaded",
            "backend_id": profile.backend_id,
            "model": profile.model,
            "model_path": profile.model_path,
            "server_url": self._server_url,
            "load_ms": load_ms,
        }

    def _validate_request(self, request: dict[str, Any], profile: _Profile) -> list[str]:
        errors: list[str] = []
        requested_language = _normalize_language(request.get("language"))
        if request.get("prompt") and not profile.supports_prompt:
            errors.append("Prompt is not supported by this backend")
        if _coerce_bool(request.get("word_timestamps")) and not profile.supports_word_timestamps:
            errors.append("Word timestamps are not supported by this backend")
        if not profile.supports_language_override and requested_language not in {"", "en", "en-us", "en-gb", "eng"}:
            errors.append("Language override is disabled")
        return errors

    def transcribe(self, request: dict[str, Any]) -> dict[str, Any]:
        if self._profile is None or self._process is None or self._process.poll() is not None:
            return {"error": "Worker is not loaded; send a load message first"}
        audio_path = str(request.get("audio_path", "")).strip()
        try:
            _assert_canonical_wav(audio_path)
        except ValueError as error:
            return {"error": str(error)}

        profile = self._profile
        errors = self._validate_request(request, profile)
        if errors:
            return {"error": "; ".join(errors)}

        language = _normalize_language(request.get("language"))
        if not language:
            language = "en"
        prompt = str(request.get("prompt") or "").strip()
        fields: dict[str, str] = {
            "model": profile.model_path,
            "task": "transcribe",
            "response_format": "verbose_json",
            "language": language,
            "beam_size": str(profile.beam_size),
            "best_of": str(profile.best_of),
            "temperature": str(profile.temperature),
        }
        if profile.temperature_fallback:
            fields["temperature_inc"] = "0.2"
        else:
            fields["no_fallback"] = "1"
        if profile.no_timestamps:
            fields["no_timestamps"] = "1"
        if profile.no_context:
            fields["max_context"] = "0"
        if prompt:
            fields["prompt"] = prompt
        if _coerce_bool(request.get("word_timestamps")):
            fields["token_timestamps"] = "1"
        started = time.perf_counter()
        status, payload = _multipart_request(
            f"{self._server_url}/inference",
            fields,
            audio_path,
            timeout=profile.timeout_seconds,
        )
        backend_ms = (time.perf_counter() - started) * 1000.0
        if status != 200:
            return {"error": f"inference request failed with status {status}: {payload}"}

        if not isinstance(payload, dict):
            return {
                "text": str(payload or ""),
                "segments": [],
                "words": [],
                "backend_ms": backend_ms,
                "metadata": {
                    "server_url": self._server_url,
                    "model": profile.model,
                    "model_path": profile.model_path,
                },
            }

        text = str(payload.get("text", "")).strip()
        segments = _normalize_segments(payload.get("segments"))
        words = _normalize_segments(payload.get("words"), keys=True)
        return {
            "backend_id": profile.backend_id,
            "text": text,
            "segments": segments,
            "words": words,
            "backend_ms": backend_ms,
            "metadata": {
                "model": profile.model,
                "model_path": profile.model_path,
                "server_url": self._server_url,
                "response": {
                    "language": payload.get("language"),
                    "audio_duration_ms": _normalize_ms(payload.get("duration")),
                },
            },
        }

    def list_models(self) -> dict[str, Any]:
        return {
            "backend_id": (self._profile.backend_id if self._profile else "whisper-cpp"),
            "models": [
                {
                    "logical_name": "large-v3-turbo",
                    "artifact": "ggml-large-v3-turbo-q5_0.bin",
                    "revision": "local",
                }
            ],
        }

    def unload(self) -> dict[str, Any]:
        self._stop_server()
        self._profile = None
        self._load_ms = None
        return {"status": "unloaded"}

    def shutdown(self) -> dict[str, Any]:
        self._stop_server()
        self._profile = None
        self._load_ms = None
        return {"status": "shutdown"}

    def dispatch(self, request: dict[str, Any]) -> dict[str, Any]:
        request_type = str(request.get("type", "")).strip()
        if request_type in {"initialize", "load"}:
            return self.load(request)
        if request_type == "list_models":
            return self.list_models()
        if request_type == "transcribe":
            return self.transcribe(request)
        if request_type == "unload":
            return self.unload()
        if request_type == "shutdown":
            return self.shutdown()
        return {"error": f"Unsupported message type: {request_type}"}


_WORKER = WhisperCppServerWorker()


def main() -> None:
    while True:
        raw_line = sys.stdin.readline()
        if not raw_line:
            break
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            message = json.loads(raw_line)
            response = _WORKER.dispatch(message)
            _emit(response)
            if message.get("type") in {"shutdown", "unload"} and response.get("status") == "shutdown":
                return
        except Exception as error:
            _emit({"error": str(error)})


if __name__ == "__main__":
    main()
