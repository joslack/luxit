from __future__ import annotations

import json
import os
import select
import subprocess
import threading
import time
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

from .types import BackendSpec, TranscriptRequest, TranscriptResult


def audio_duration(path: str) -> float:
    import wave

    with wave.open(path, "rb") as audio:
        return audio.getnframes() / float(audio.getframerate())


def _variables(spec: BackendSpec, request: TranscriptRequest) -> dict[str, str]:
    values = {
        "audio": request.audio_path,
        "language": request.language or "",
        "prompt": request.prompt or "",
        "model": spec.model,
        "model_path": spec.model_path,
        "word_timestamps": "true" if request.word_timestamps else "false",
    }
    values.update({key: str(value) for key, value in request.options.items()})
    values.update({key: str(value) for key, value in spec.options.items()})
    return values


def _render(parts: list[str], values: dict[str, str]) -> list[str]:
    rendered: list[str] = []
    for part in parts:
        try:
            value = part.format_map(values)
        except KeyError:
            value = part
        if value:
            rendered.append(value)
    return rendered


class BackendAdapter(ABC):
    def __init__(self, spec: BackendSpec):
        self.spec = spec

    @abstractmethod
    def transcribe(self, request: TranscriptRequest) -> TranscriptResult:
        raise NotImplementedError

    def close(self) -> None:
        return


class CommandAdapter(BackendAdapter):
    def transcribe(self, request: TranscriptRequest) -> TranscriptResult:
        values = _variables(self.spec, request)
        command = _render(self.spec.command, values)
        environment = os.environ.copy()
        environment.update(
            {key: value.format_map(values) for key, value in self.spec.environment.items()}
        )
        timeout = float(self.spec.options.get("timeout_seconds", 600))
        started = time.perf_counter()
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            env=environment,
            timeout=timeout,
            check=False,
        )
        wall_ms = (time.perf_counter() - started) * 1000.0
        duration = audio_duration(request.audio_path)
        if completed.returncode != 0:
            return TranscriptResult(
                backend_id=self.spec.id,
                text="",
                wall_ms=wall_ms,
                audio_seconds=duration,
                error=(completed.stderr or completed.stdout).strip(),
                metadata={"command": command, "returncode": completed.returncode},
            )

        output_format = self.spec.options.get("output_format", "plain")
        if output_format == "json":
            payload = json.loads(completed.stdout)
            text = payload.get("text", "")
            backend_ms = payload.get("backend_ms")
            segments = payload.get("segments", [])
            words = payload.get("words", [])
        else:
            text = completed.stdout.strip()
            backend_ms = None
            segments = []
            words = []
        return TranscriptResult(
            backend_id=self.spec.id,
            text=text,
            wall_ms=wall_ms,
            audio_seconds=duration,
            backend_ms=backend_ms,
            warm=False,
            segments=segments,
            words=words,
            metadata={"command": command, "stderr": completed.stderr.strip()},
        )


class JsonlWorkerAdapter(BackendAdapter):
    def __init__(self, spec: BackendSpec):
        super().__init__(spec)
        self._process: subprocess.Popen[str] | None = None
        self._lock = threading.Lock()
        self._loaded = False

    def _start(self) -> float:
        if self._process and self._process.poll() is None:
            return 0.0
        started = time.perf_counter()
        self._process = subprocess.Popen(
            self.spec.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env={**os.environ, **self.spec.environment},
        )
        ready = self._exchange(
            {
                "type": "load",
                "backend_id": self.spec.id,
                "model": self.spec.model,
                "model_path": self.spec.model_path,
                "options": self.spec.options,
            },
            timeout=float(self.spec.options.get("load_timeout_seconds", 600)),
        )
        if ready.get("error"):
            raise RuntimeError(str(ready["error"]))
        self._loaded = True
        return (time.perf_counter() - started) * 1000.0

    def _exchange(self, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
        if not self._process or not self._process.stdin or not self._process.stdout:
            raise RuntimeError("Worker is not running")
        self._process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self._process.stdin.flush()
        ready, _, _ = select.select([self._process.stdout], [], [], timeout)
        if not ready:
            raise TimeoutError(f"{self.spec.name} did not respond within {timeout:g}s")
        line = self._process.stdout.readline()
        if not line:
            stderr = self._process.stderr.read() if self._process.stderr else ""
            raise RuntimeError(f"{self.spec.name} exited unexpectedly: {stderr.strip()}")
        return json.loads(line)

    def transcribe(self, request: TranscriptRequest) -> TranscriptResult:
        with self._lock:
            was_warm = self._loaded
            started = time.perf_counter()
            try:
                load_ms = self._start()
                payload = self._exchange(
                    {"type": "transcribe", **request.as_dict()},
                    timeout=float(self.spec.options.get("timeout_seconds", 600)),
                )
                wall_ms = (time.perf_counter() - started) * 1000.0
                return TranscriptResult(
                    backend_id=self.spec.id,
                    text=payload.get("text", ""),
                    wall_ms=wall_ms,
                    audio_seconds=audio_duration(request.audio_path),
                    backend_ms=payload.get("backend_ms"),
                    load_ms=payload.get("load_ms", load_ms or None),
                    preprocess_ms=payload.get("preprocess_ms"),
                    decode_ms=payload.get("decode_ms"),
                    warm=was_warm,
                    segments=payload.get("segments", []),
                    words=payload.get("words", []),
                    metadata=payload.get("metadata", {}),
                    error=payload.get("error"),
                )
            except Exception as error:
                wall_ms = (time.perf_counter() - started) * 1000.0
                self.close()
                return TranscriptResult(
                    backend_id=self.spec.id,
                    text="",
                    wall_ms=wall_ms,
                    audio_seconds=audio_duration(request.audio_path),
                    warm=was_warm,
                    error=str(error),
                )

    def close(self) -> None:
        if not self._process:
            self._loaded = False
            return
        try:
            if self._process.poll() is None:
                self._exchange({"type": "shutdown"}, timeout=2)
        except Exception:
            self._process.terminate()
        finally:
            self._process = None
            self._loaded = False
