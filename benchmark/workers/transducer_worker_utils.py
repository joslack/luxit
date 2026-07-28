from __future__ import annotations

import json
import subprocess
import time
import wave
from array import array
import math
import struct
from pathlib import Path


def parse_transcript_output(stdout: str) -> dict:
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    result = {
        "text": "",
        "segments": [],
        "words": [],
        "metadata": {"raw_line_count": len(lines)},
        "backend_ms": None,
    }

    for line in reversed(lines):
        if line.startswith("{") and line.endswith("}"):
            try:
                payload = json.loads(line)
            except Exception:
                continue
            if isinstance(payload, dict):
                result["metadata"].update({k: v for k, v in payload.items() if k not in {"text", "segments", "words"}})
                text = payload.get("text", "")
                if isinstance(text, str) and text.strip():
                    result["text"] = text.strip()
                result["segments"] = payload.get("segments", result["segments"]) or []
                result["words"] = payload.get("words", result["words"]) or []
                backend_ms = payload.get("backend_ms")
                if isinstance(backend_ms, (int, float)):
                    result["backend_ms"] = float(backend_ms)
                elapsed_ms = payload.get("elapsed_ms")
                if isinstance(elapsed_ms, (int, float)):
                    result["backend_ms"] = float(elapsed_ms)
                if result["text"] or result["segments"] or result["words"]:
                    return result
        if not result["text"]:
            for prefix in ("text:", "transcript:", "result:"):
                if line.lower().startswith(prefix):
                    result["text"] = line.split(":", 1)[1].strip()
                    return result

    if lines and not result["text"]:
        result["text"] = lines[-1]
    return result


def run_command(command: list[str], timeout_seconds: float) -> tuple[int, str, str]:
    started = time.perf_counter()
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout_seconds,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    parsed = parse_transcript_output(completed.stdout)
    parsed["metadata"]["returncode"] = completed.returncode
    parsed["metadata"]["duration_ms"] = elapsed_ms
    parsed["metadata"]["command"] = command
    parsed["metadata"]["stderr"] = (completed.stderr or "").strip()
    return completed.returncode, parsed.get("text", ""), json.dumps(parsed, separators=(",", ":"))


def read_wav_float32(audio_path: str) -> tuple[list[float], int]:
    with wave.open(audio_path, "rb") as handle:
        sample_rate = int(handle.getframerate())
        width = handle.getsampwidth()
        channels = handle.getnchannels()
        data = handle.readframes(handle.getnframes())
        comptype = handle.getcomptype()

    if width == 0 or not data:
        return [], sample_rate

    if width == 4:
        if comptype == "FLOAT":
            count = len(data) // width
            values = list(struct.iter_unpack("<f", data[: count * width]))
            samples = [max(-1.0, min(1.0, value[0])) for value in values]
        else:
            values = array("i")
            values.frombytes(data)
            samples = [max(-1.0, min(1.0, value / 2147483648.0)) for value in values]
    elif width == 3:
        raw_samples = []
        for offset in range(0, len(data), 3):
            chunk = data[offset : offset + 3]
            if len(chunk) != 3:
                continue
            value = chunk[0] | (chunk[1] << 8) | (chunk[2] << 16)
            if value & 0x800000:
                value -= 1 << 24
            raw_samples.append(max(-1.0, min(1.0, value / 8388608.0)))
        samples = raw_samples
    elif width == 2:
        values = array("h")
        values.frombytes(data)
        samples = [max(-1.0, min(1.0, value / 32768.0)) for value in values]
    elif width == 1:
        samples = [((byte - 128) / 128.0) for byte in data]
    else:
        return [], sample_rate

    if channels > 1 and samples:
        mono = []
        for index in range(0, len(samples) - channels + 1, channels):
            frame = samples[index : index + channels]
            mono.append(sum(frame) / float(len(frame)))
        samples = mono

    if not samples:
        return [], sample_rate

    energy = sum(sample * sample for sample in samples)
    if energy == 0.0:
        return [max(-1.0, min(1.0, sample)) for sample in samples], sample_rate
    norm = math.sqrt(energy / len(samples))
    if norm > 1.0:
        return [sample / norm for sample in samples], sample_rate
    return samples, sample_rate


def write_json(stdout_obj: dict) -> str:
    return json.dumps(stdout_obj, separators=(",", ":"))


def error_payload(message: str, **extra: object) -> dict:
    payload = {"error": message}
    if extra:
        payload["metadata"] = extra
    return payload
