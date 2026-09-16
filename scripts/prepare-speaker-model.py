#!/usr/bin/env python3
"""Provision the pinned model during a build, never during recording."""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'scripts/dependencies/speaker-model.json').read_text())
target = root / '.build/speaker-model/ls_eend_ami_500ms.mlmodelc'
for relative, expected in manifest['files'].items():
    dest = target / relative
    if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == expected:
        continue
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f'Downloading local speaker model: {relative}', file=sys.stderr)
    url = f"https://huggingface.co/FluidInference/ls-eend-coreml/resolve/{manifest['revision']}/{manifest['path']}/{relative}"
    temporary = dest.with_name(dest.name + '.download')
    try:
        urllib.request.urlretrieve(url, temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Speaker model checksum mismatch: {relative}')
        temporary.replace(dest)
    finally:
        temporary.unlink(missing_ok=True)
print(target)
