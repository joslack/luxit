#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time


def _coerce_bool(value: str | bool | int | float | None) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _coerce_int(value: str | int | float | None, default: int) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _resolve_language(args: argparse.Namespace) -> tuple[str | None, list[str]]:
    requested = (args.language or "").strip() or None
    fixed = (args.fixed_language or "en").strip() or "en"
    if _coerce_bool(args.supports_language_override):
        return requested, []
    if requested is None:
        return fixed, []
    if requested.lower() in {"en", "en-us", "en-gb", "eng"}:
        return fixed, []
    return fixed, [
        f"Language override disabled; forcing fixed language {fixed} instead of {requested}"
    ]


def _run_cli(binary: str, model: str, model_path: str, audio: str, prompt: str | None, language: str | None, word_timestamps: bool, verbose: bool) -> tuple[int, str, str]:
    command = [
        binary,
        "transcribe",
        "--audio-path",
        audio,
        "--without-timestamps",
        "--concurrent-worker-count",
        "1",
        "--chunking-strategy",
        "none",
    ]
    if model_path:
        command.extend(["--model-path", model_path])
    else:
        command.extend(["--model", model])
    if verbose:
        command.append("--verbose")
    if language:
        command.extend(["--language", language])
    if prompt:
        command.extend(["--prompt", prompt])
    if word_timestamps:
        command.append("--word-timestamps")

    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.returncode, completed.stdout or "", completed.stderr or ""


def _parse_output(stdout: str) -> tuple[str, list]:
    text = ""
    segments: list = []
    stripped = stdout.strip()
    if not stripped:
        return text, segments
    try:
        payload = json.loads(stripped)
        if isinstance(payload, dict):
            text = str(payload.get("text", "")).strip()
            values = payload.get("segments")
            if isinstance(values, list):
                segments = values
            return text, segments
    except json.JSONDecodeError:
        pass

    lines = [line.strip() for line in stripped.splitlines() if line.strip()]
    if lines:
        text = lines[-1]
    return text, segments


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-id", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-path", default="")
    parser.add_argument("--language", default="")
    parser.add_argument("--prompt", default="")
    parser.add_argument("--fixed-language", default="en")
    parser.add_argument("--supports-prompt", default=True)
    parser.add_argument("--supports-language-override", default=False)
    parser.add_argument("--supports-word-timestamps", default=False)
    parser.add_argument("--word-timestamps", default=False)
    parser.add_argument("--beam-size", default=5)
    parser.add_argument("--best-of", default=1)
    parser.add_argument("--temperature", default=0.0)
    parser.add_argument("--whisperkit-binary", default="whisperkit-cli")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    language, warnings = _resolve_language(args)
    prompt = (args.prompt or "").strip() or None

    if not args.supports_prompt and prompt:
        _emit(
            {
                "backend_id": args.backend_id,
                "text": "",
                "segments": [],
                "warnings": warnings,
                "error": "prompt requested but unsupported",
                "metadata": {"audio": args.audio},
            }
        )
        return 1

    requested_word_timestamps = _coerce_bool(args.word_timestamps)
    supports_word_timestamps = _coerce_bool(args.supports_word_timestamps)
    if requested_word_timestamps and not supports_word_timestamps:
        _emit(
            {
                "backend_id": args.backend_id,
                "text": "",
                "segments": [],
                "warnings": warnings,
                "error": "word timestamps requested but unsupported",
                "metadata": {"audio": args.audio},
            }
        )
        return 1

    if not language:
        returncode = 1
        stderr = "Language unresolved; profile requires language"
        _emit(
            {
                "backend_id": args.backend_id,
                "error": stderr,
                "text": "",
                "warnings": warnings,
                "segments": [],
                "metadata": {"audio": args.audio, "model": args.model},
            }
        )
        return returncode

    if not args.dry_run:
        binary = str(args.whisperkit_binary)
        if binary == "whisperkit-cli":
            if not shutil.which("whisperkit-cli") and not shutil.which("argmax-cli"):
                _emit(
                    {
                        "backend_id": args.backend_id,
                        "text": "",
                        "warnings": warnings,
                        "error": "missing whisperkit executable",
                        "metadata": {"audio": args.audio, "model": args.model},
                    }
                )
                return 1
            if not shutil.which(binary):
                binary = "argmax-cli"

        start = time.perf_counter()
        returncode, stdout, stderr = _run_cli(
            binary=binary,
            model=args.model,
            model_path=args.model_path,
            audio=args.audio,
            prompt=prompt,
            language=language,
            word_timestamps=requested_word_timestamps,
            verbose=_coerce_bool(args.verbose),
        )
        wall_ms = (time.perf_counter() - start) * 1000.0
        if returncode != 0:
            _emit(
                {
                    "backend_id": args.backend_id,
                    "text": "",
                    "warnings": warnings,
                    "segments": [],
                    "error": (stderr or stdout or "whisperkit-cli returned non-zero exit code").strip(),
                    "metadata": {"audio": args.audio, "command": binary, "returncode": returncode},
                }
            )
            return 1
    else:
        wall_ms = 0.0
        stdout = ""

    text, segments = _parse_output(stdout)
    _emit(
        {
            "backend_id": args.backend_id,
            "text": text,
            "segments": segments,
            "words": [],
            "backend_ms": wall_ms,
            "warnings": warnings,
            "metadata": {
                "audio": args.audio,
                "model": args.model,
                "model_path": args.model_path,
            },
        }
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
