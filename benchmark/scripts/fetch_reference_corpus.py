#!/usr/bin/env python3
"""Fetch five small, reference-transcribed LibriSpeech clips for smoke tests."""

from __future__ import annotations

import json
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path


SOURCE = (
    "https://s3.amazonaws.com/datasets.huggingface.co/"
    "librispeech_asr/2.1.0/dev_clean.tar.gz"
)
SELECTED = {
    "1272-128104-0000",
    "1272-128104-0001",
    "1272-128104-0002",
    "1272-141231-0003",
    "1272-141231-0005",
}


def main() -> None:
    benchmark_root = Path(__file__).resolve().parents[1]
    destination = benchmark_root / "data" / "reference"
    destination.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which("ffmpeg")
    afconvert = shutil.which("afconvert")
    if not ffmpeg and not afconvert:
        raise SystemExit("ffmpeg or macOS afconvert is required to normalize the clips")

    with tempfile.TemporaryDirectory(prefix="sttbench-reference-") as temporary:
        archive_path = Path(temporary) / "dev_clean.tar.gz"
        print(f"Downloading the 9.2 MB LibriSpeech dummy corpus from {SOURCE}")
        urllib.request.urlretrieve(SOURCE, archive_path)
        extracted = Path(temporary) / "extracted"
        extracted.mkdir()
        with tarfile.open(archive_path) as archive:
            safe_members = []
            for member in archive.getmembers():
                member_path = Path(member.name)
                if member_path.is_absolute() or ".." in member_path.parts:
                    raise RuntimeError(f"Unsafe archive member: {member.name}")
                if (
                    member.name.endswith(".txt")
                    or any(member.name.endswith(f"{sample}.flac") for sample in SELECTED)
                ):
                    safe_members.append(member)
            archive.extractall(extracted, members=safe_members, filter="data")

        transcripts: dict[str, str] = {}
        for transcript_path in extracted.rglob("*.txt"):
            for line in transcript_path.read_text().splitlines():
                sample_id, text = line.split(" ", 1)
                if sample_id in SELECTED:
                    transcripts[sample_id] = text

        cases = []
        for sample_id in sorted(SELECTED):
            source_audio = next(extracted.rglob(f"{sample_id}.flac"))
            output_audio = destination / f"{sample_id}.wav"
            if ffmpeg:
                command = [
                    ffmpeg,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-i",
                    str(source_audio),
                    "-ar",
                    "16000",
                    "-ac",
                    "1",
                    "-c:a",
                    "pcm_s16le",
                    str(output_audio),
                ]
            else:
                command = [
                    afconvert,
                    "-f",
                    "WAVE",
                    "-d",
                    "LEI16@16000",
                    "-c",
                    "1",
                    str(source_audio),
                    str(output_audio),
                ]
            subprocess.run(command, check=True)
            cases.append(
                {
                    "id": sample_id,
                    "audio_path": str(output_audio),
                    "text": transcripts[sample_id],
                }
            )

    corpus = {
        "name": "LibriSpeech dummy smoke set",
        "source": SOURCE,
        "source_dataset": "hf-internal-testing/librispeech_asr_dummy",
        "license": "CC BY 4.0",
        "cases": cases,
    }
    manifest = destination / "corpus.json"
    manifest.write_text(json.dumps(corpus, indent=2) + "\n")
    print(f"Prepared {len(cases)} clips at {destination}")


if __name__ == "__main__":
    main()
