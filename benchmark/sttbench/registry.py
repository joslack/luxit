from __future__ import annotations

import importlib.util
import json
import os
import shutil
from dataclasses import replace
from pathlib import Path
from typing import Any

from .adapters import BackendAdapter, CommandAdapter, JsonlWorkerAdapter
from .types import BackendSpec


class BackendRegistry:
    def __init__(self, benchmark_root: Path):
        self.root = benchmark_root.resolve()
        self.workspace = self.root.parent
        self.manifest_dir = self.root / "backends"
        self.model_dir = Path(
            os.environ.get("STTBENCH_MODEL_DIR", str(self.root / "models"))
        ).expanduser()
        configured_search = os.environ.get("STTBENCH_MODEL_SEARCH_PATHS", "")
        self.model_search_paths = [
            Path(item).expanduser()
            for item in configured_search.split(os.pathsep)
            if item
        ]
        self.model_search_paths.extend(
            [
                Path.home() / "Library/Application Support/EdgeWhisper/Models",
                Path.home() / "Library/Application Support/Luxit/Models",
                self.model_dir,
            ]
        )
        self.specs: dict[str, BackendSpec] = {}
        self._load()

    def _expand(self, value: str) -> str:
        replacements = {
            "${BENCHMARK_ROOT}": str(self.root),
            "${WORKSPACE_ROOT}": str(self.workspace),
            "${MODEL_DIR}": str(self.model_dir),
        }
        for source, target in replacements.items():
            value = value.replace(source, target)
        return os.path.expandvars(os.path.expanduser(value))

    def _expand_tree(self, value: Any) -> Any:
        if isinstance(value, str):
            return self._expand(value)
        if isinstance(value, list):
            return [self._expand_tree(item) for item in value]
        if isinstance(value, dict):
            return {key: self._expand_tree(item) for key, item in value.items()}
        return value

    def _load(self) -> None:
        self.specs.clear()
        for path in sorted(self.manifest_dir.glob("*.json")):
            with path.open() as source:
                raw = self._expand_tree(json.load(source))
            raw = self._resolve_local_artifacts(raw)
            spec = BackendSpec.from_dict(raw, path)
            if spec.id in self.specs:
                raise ValueError(f"Duplicate backend id: {spec.id}")
            self.specs[spec.id] = spec

    def _resolve_local_artifacts(self, raw: dict[str, Any]) -> dict[str, Any]:
        """Reuse an existing model with the same filename instead of duplicating it."""
        candidates = []
        model_path = raw.get("model_path")
        if isinstance(model_path, str):
            candidates.append(model_path)
        candidates.extend(
            item for item in raw.get("required_paths", []) if isinstance(item, str)
        )
        replacements: dict[str, str] = {}
        for original in candidates:
            if "$" in original or Path(original).exists():
                continue
            basename = Path(original).name
            for directory in self.model_search_paths:
                candidate = directory / basename
                if candidate.exists():
                    replacements[original] = str(candidate)
                    break
                if directory.exists():
                    nested = next(directory.rglob(basename), None)
                    if nested is not None:
                        replacements[original] = str(nested)
                        break
        if not replacements:
            return raw

        def replace_paths(value: Any) -> Any:
            if isinstance(value, str):
                for original, replacement in replacements.items():
                    value = value.replace(original, replacement)
                return value
            if isinstance(value, list):
                return [replace_paths(item) for item in value]
            if isinstance(value, dict):
                return {key: replace_paths(item) for key, item in value.items()}
            return value

        return replace_paths(raw)

    def availability(self, spec: BackendSpec) -> tuple[bool, list[str]]:
        reasons: list[str] = []
        for command in spec.required_commands:
            if not shutil.which(command):
                reasons.append(f"Missing command: {command}")
        for path in spec.required_paths:
            if "${" in path:
                variable = path.split("${", 1)[1].split("}", 1)[0]
                reasons.append(f"Set environment variable: {variable}")
            elif not Path(path).exists():
                reasons.append(f"Missing path: {path}")
        for module in spec.required_python_modules:
            if importlib.util.find_spec(module) is None:
                reasons.append(f"Missing Python module: {module}")
        return not reasons, reasons

    def public_specs(self) -> list[dict[str, Any]]:
        result = []
        for spec in self.specs.values():
            available, reasons = self.availability(spec)
            item = spec.public_dict()
            item["available"] = available
            item["unavailable_reasons"] = reasons
            result.append(item)
        return result

    def create(self, backend_id: str) -> BackendAdapter:
        spec = self.specs[backend_id]
        available, reasons = self.availability(spec)
        if not available:
            raise RuntimeError("; ".join(reasons))
        if spec.protocol == "command":
            return CommandAdapter(spec)
        if spec.protocol == "jsonl-worker":
            return JsonlWorkerAdapter(spec)
        raise ValueError(f"Unsupported protocol for {backend_id}: {spec.protocol}")
