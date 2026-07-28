#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


def _coerce_bool(value: str | bool | int | float | None) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if value is None:
        return False
    normalized = str(value).strip().lower()
    return normalized in {"1", "true", "yes", "on"}


def _coerce_int(value: str | int | float | None, default: int) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _coerce_float(value: str | int | float | None, default: float) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def _emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _resolve_language(args: argparse.Namespace) -> tuple[str | None, list[str]]:
    warning: list[str] = []
    requested = (args.language or "").strip() if args.language is not None else None
    fixed_language = (args.fixed_language or "").strip() or "en"

    if _coerce_bool(args.supports_language_override):
        if requested:
            return requested, warning
        return None, warning

    if not requested:
        return fixed_language, warning
    normalized = requested.lower()
    if normalized in {"en", "en-us", "en-gb", "eng"}:
        return fixed_language, warning
    warning.append(
        f"Language override disabled; forcing fixed language {fixed_language} instead of {requested}"
    )
    return fixed_language, warning


def _parse_stdout(stdout: str) -> tuple[str, list[dict]]:
    raw = stdout.strip()
    if not raw:
        return "", []

    try:
        payload = json.loads(raw)
        if isinstance(payload, dict):
            text = str(payload.get("text", "")).strip()
            segments = payload.get("segments")
            return text, segments if isinstance(segments, list) else []
    except json.JSONDecodeError:
        pass

    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    if not lines:
        return "", []
    return lines[-1], []


@dataclass(frozen=True)
class BridgeConfig:
    backend_id: str
    audio: Path
    model_path: Path
    language: str | None
    prompt: str | None
    fixed_language: str
    threads: int
    beam_size: int
    best_of: int
    temperature: float
    temperature_fallback: bool
    no_context: bool
    no_timestamps: bool
    strategy: str
    supports_prompt: bool
    supports_language_override: bool
    supports_word_timestamps: bool
    requested_word_timestamps: bool
    flash_attention: bool
    dry_run: bool
    whisper_binary: str


def _build_command(config: BridgeConfig) -> list[str]:
    command = [
        config.whisper_binary,
        "--model",
        str(config.model_path),
        "--file",
        str(config.audio),
        "--threads",
        str(config.threads),
        "--beam-size",
        str(config.beam_size),
        "--best-of",
        str(config.best_of),
        "--temperature",
        f"{config.temperature:g}",
    ]

    if config.language:
        command.extend(["--language", config.language])
    if config.prompt:
        command.extend(["--prompt", config.prompt])
    if config.no_context:
        command.append("--no-context")
    if config.no_timestamps:
        command.append("--no-timestamps")
    if config.flash_attention:
        command.append("--flash-attn")
    if config.strategy == "greedy":
        if not config.temperature_fallback:
            command.extend(["--temperature-inc", "0"])
    else:
        command.extend(["--patience", "1"])
    if not config.temperature_fallback:
        command.append("--no-fallback")
    command.append("--no-prints")
    return command


def _run_whisper_cli(config: BridgeConfig, command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
    )


def _build_config(args: argparse.Namespace) -> tuple[BridgeConfig, list[str], str | None]:
    language, warnings = _resolve_language(args)
    config = BridgeConfig(
        backend_id=str(args.backend_id),
        audio=Path(args.audio),
        model_path=Path(args.model_path),
        language=language,
        prompt=(args.prompt or "").strip() or None,
        fixed_language=(args.fixed_language or "en").strip() or "en",
        threads=_coerce_int(args.threads, 6),
        beam_size=_coerce_int(args.beam_size, 5),
        best_of=_coerce_int(args.best_of, 1),
        temperature=_coerce_float(args.temperature, 0.0),
        temperature_fallback=_coerce_bool(args.temperature_fallback),
        no_context=_coerce_bool(args.no_context),
        no_timestamps=_coerce_bool(args.no_timestamps),
        strategy=str(args.strategy or "beam"),
        supports_prompt=_coerce_bool(args.supports_prompt),
        supports_language_override=_coerce_bool(args.supports_language_override),
        supports_word_timestamps=_coerce_bool(args.supports_word_timestamps),
        requested_word_timestamps=_coerce_bool(args.word_timestamps),
        flash_attention=_coerce_bool(args.flash_attention),
        dry_run=_coerce_bool(args.dry_run),
        whisper_binary=str(args.whisper_binary),
    )

    if config.language is None:
        return config, warnings, "language resolved to null"
    if not config.supports_prompt and config.prompt:
        warnings.append("Prompt requested, but backend does not advertise prompt support.")
    if config.requested_word_timestamps and not config.supports_word_timestamps:
        warnings.append(
            "Word timestamps requested, but backend does not advertise word timestamp support."
        )

    if not config.audio.is_file():
        return config, warnings, "audio file not found"
    if not config.model_path.exists():
        return config, warnings, "model file not found"

    if not shutil.which(config.whisper_binary) and not Path(config.whisper_binary).exists():
        return config, warnings, f"whisper binary not found: {config.whisper_binary}"

    if not config.supports_language_override and not warnings:
        if args.language and args.language.lower() not in {"", "en", "en-us", "en-gb", "eng"}:
            warnings.append(
                "Non-English request was denied by fixed-language profile."
            )
            return config, warnings, warnings[0]

    return config, warnings, None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-id", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--language", default="")
    parser.add_argument("--prompt", default="")
    parser.add_argument("--fixed-language", default="en")
    parser.add_argument("--threads", default=6)
    parser.add_argument("--beam-size", default=5)
    parser.add_argument("--best-of", default=1)
    parser.add_argument("--temperature", default=0.0)
    parser.add_argument("--temperature-fallback", default=False)
    parser.add_argument("--no-context", default=True)
    parser.add_argument("--no-timestamps", default=True)
    parser.add_argument("--strategy", choices=("beam", "greedy"), default="beam")
    parser.add_argument("--supports-prompt", default=True)
    parser.add_argument("--supports-language-override", default=False)
    parser.add_argument("--supports-word-timestamps", default=False)
    parser.add_argument("--word-timestamps", default=False)
    parser.add_argument("--flash-attention", default=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--whisper-binary", default="whisper-cli")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config, warnings, error = _build_config(args)
    if error:
        _emit(
            {
                "backend_id": config.backend_id,
                "text": "",
                "segments": [],
                "words": [],
                "warnings": warnings,
                "error": error,
                "metadata": {"audio": str(config.audio), "model_path": str(config.model_path)},
            }
        )
        return 1

    if not config.supports_prompt and config.prompt:
        _emit(
            {
                "backend_id": config.backend_id,
                "text": "",
                "segments": [],
                "words": [],
                "warnings": warnings,
                "error": "prompt requested but unsupported",
                "metadata": {"audio": str(config.audio), "model_path": str(config.model_path)},
            }
        )
        return 1

    if config.requested_word_timestamps and not config.supports_word_timestamps:
        _emit(
            {
                "backend_id": config.backend_id,
                "text": "",
                "segments": [],
                "words": [],
                "warnings": warnings,
                "error": "word timestamps requested but unsupported",
                "metadata": {"audio": str(config.audio), "model_path": str(config.model_path)},
            }
        )
        return 1

    if config.dry_run:
        _emit(
            {
                "backend_id": config.backend_id,
                "text": "",
                "segments": [],
                "words": [],
                "warnings": warnings,
                "metadata": {
                    "audio": str(config.audio),
                    "model_path": str(config.model_path),
                    "dry_run": True,
                },
            }
        )
        return 0

    start = time.perf_counter()
    command = _build_command(config)
    completed = _run_whisper_cli(config, command)
    wall_ms = (time.perf_counter() - start) * 1000.0

    if completed.returncode != 0:
        _emit(
            {
                "backend_id": config.backend_id,
                "text": "",
                "segments": [],
                "words": [],
                "warnings": warnings,
                "error": (completed.stderr or completed.stdout or "whisper-cli failure").strip(),
                "metadata": {
                    "audio": str(config.audio),
                    "model_path": str(config.model_path),
                    "returncode": completed.returncode,
                    "command": command,
                },
            }
        )
        return 1

    text, segments = _parse_stdout(completed.stdout or "")
    _emit(
        {
            "backend_id": config.backend_id,
            "text": text,
            "segments": segments,
            "words": [],
            "backend_ms": wall_ms,
            "warnings": warnings,
            "metadata": {
                "audio": str(config.audio),
                "model_path": str(config.model_path),
                "command": command,
            },
        }
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
