from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from typing import Any


def _as_bool(value: str | None) -> bool:
    if value is None:
        return False
    return str(value).lower() in {"1", "true", "yes", "y", "on"}


def _bool(val: bool | str | None, default: bool = False) -> bool:
    if val is None:
        return default
    if isinstance(val, bool):
        return val
    return str(val).lower() in {"1", "true", "yes", "y", "on"}


BACKENDS = {
    "qwen3_asr_pure_c": {
        "id": "frontier-qwen3-asr-pure-c",
        "name": "Qwen3-ASR pure-C/Accelerate",
        "runtime_command_env": "QWEN3_C_RUNTIME",
        "required_commands": ["qwen_asr"],
        "supports_prompt": True,
        "supports_streaming": True,
        "supports_word_timestamps": False,
        "supports_segment_timestamps": False,
        "supports_translation": False,
        "supports_diarization": False,
        "default_command": ["qwen_asr", "--help"],
    },
    "sensevoice_coreml": {
        "id": "frontier-sensevoice-coreml-int8",
        "name": "SenseVoice Small Core ML",
        "runtime_command_env": "SENSEVOICE_COREML_RUNTIME",
        "required_commands": [],
        "supports_prompt": False,
        "supports_streaming": False,
        "supports_word_timestamps": False,
        "supports_segment_timestamps": False,
        "supports_translation": False,
        "supports_diarization": False,
        "default_command": ["./sensevoice-coreml"],
    },
    "cohere_coreml": {
        "id": "frontier-cohere-coreml",
        "name": "Cohere Transcribe 03-2026 Core ML",
        "runtime_command_env": "COHERE_COREML_RUNTIME",
        "required_commands": [],
        "supports_prompt": False,
        "supports_streaming": False,
        "supports_word_timestamps": False,
        "supports_segment_timestamps": False,
        "supports_translation": False,
        "supports_diarization": False,
        "default_command": ["./cohere-coreml"],
    },
}


def _validate(profile: dict[str, Any], args: argparse.Namespace) -> list[str]:
    errors: list[str] = []
    if args.prompt and not profile["supports_prompt"]:
        errors.append("Prompt/hotword mode is not supported")
    if _bool(args.word_timestamps) and not profile["supports_word_timestamps"]:
        errors.append("Word timestamps are not supported")
    if _bool(args.timestamps) and not profile["supports_word_timestamps"]:
        errors.append("Timestamps are not supported")
    if _bool(args.streaming) and not profile["supports_streaming"]:
        errors.append("Streaming is not supported")
    if (_bool(args.translate) or args.target_language) and not profile["supports_translation"]:
        errors.append("Translation is not supported")
    if _bool(args.diarization) and not profile["supports_diarization"]:
        errors.append("Diarization is not supported")
    return errors


def _resolve_runtime_command(profile: dict[str, Any]) -> list[str] | None:
    env_value = os.getenv(profile["runtime_command_env"])
    if env_value:
        candidate = env_value.strip()
        if candidate:
            if os.path.isabs(candidate):
                return [candidate]
            runtime = shutil.which(candidate)
            return [runtime] if runtime else None
    default_command = profile.get("default_command", [])
    if not default_command:
        return None
    first = default_command[0]
    if os.path.isabs(first):
        return [first] + default_command[1:]
    runtime = shutil.which(first)
    return [runtime] + default_command[1:] if runtime else None


def _build_result(
    text: str,
    backend_ms: float,
    stdout: str,
    stderr: str,
    returncode: int,
) -> dict[str, Any]:
    return {
        "text": text,
        "backend_ms": backend_ms,
        "segments": [],
        "words": [],
        "metadata": {
            "stdout": stdout,
            "stderr": stderr,
            "returncode": returncode,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("backend", choices=BACKENDS.keys())
    parser.add_argument("--audio", required=True)
    parser.add_argument("--language", default="en")
    parser.add_argument("--prompt", default="")
    parser.add_argument("--word-timestamps", dest="word_timestamps", default="false")
    parser.add_argument("--timestamps", default="false")
    parser.add_argument("--streaming", default="false")
    parser.add_argument("--diarization", default="false")
    parser.add_argument("--translate", default="false")
    parser.add_argument("--translation", default="false")
    parser.add_argument("--source-language")
    parser.add_argument("--target-language")
    parser.add_argument("--model")
    parser.add_argument("--model-path")
    args = parser.parse_args()

    profile = BACKENDS[args.backend]
    errors = _validate(profile, args)
    if errors:
        print(json.dumps({"error": "; ".join(errors)}), flush=True)
        return 1

    command = _resolve_runtime_command(profile)
    if not command:
        print(
            json.dumps(
                {
                    "error": (
                        "Runtime command unavailable. Set "
                        f"${profile['runtime_command_env']} to the executable path."
                    )
                }
            ),
            flush=True,
        )
        return 1

    request_args = ["--audio", args.audio, "--language", args.language]
    if args.model:
        request_args += ["--model", args.model]
    if args.model_path:
        request_args += ["--model-path", args.model_path]
    if args.prompt:
        request_args += ["--prompt", args.prompt]
    if args.source_language:
        request_args += ["--source-language", args.source_language]
    if args.target_language:
        request_args += ["--target-language", args.target_language]

    if args.backend == "qwen3_asr_pure_c":
        request_args = [
            "-i",
            args.audio,
            "--language",
            args.language,
        ]
        if args.model_path:
            request_args = ["-d", args.model_path] + request_args
        else:
            request_args = ["-d", args.model] + request_args
        if args.prompt:
            request_args += ["--prompt", args.prompt]
    elif args.backend == "sensevoice_coreml":
        request_args = ["transcribe", "--audio", args.audio, "--language", args.language]
        if args.model_path:
            request_args += ["--model-path", args.model_path]
    elif args.backend == "cohere_coreml":
        request_args = ["transcribe", "--audio", args.audio, "--language", args.language]
        if args.model_path:
            request_args += ["--model-path", args.model_path]

    started = time.perf_counter()
    completed = subprocess.run(
        command + request_args,
        check=False,
        capture_output=True,
        text=True,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    if completed.returncode != 0:
        err = (completed.stderr or completed.stdout or "").strip() or (
            f"Runtime exited with code {completed.returncode}"
        )
        print(json.dumps({"error": err}), flush=True)
        return 1

    out = (completed.stdout or "").strip()
    try:
        parsed = json.loads(out)
        parsed["backend_ms"] = elapsed_ms
        print(json.dumps(parsed), flush=True)
        return 0
    except json.JSONDecodeError:
        print(json.dumps(_build_result(out, elapsed_ms, out, completed.stderr.strip(), 0)), flush=True)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
