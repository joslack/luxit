from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Capabilities:
    languages: list[str] = field(default_factory=list)
    prompt: bool = False
    word_timestamps: bool = False
    segment_timestamps: bool = False
    streaming: bool = False
    persistent: bool = False


@dataclass(frozen=True)
class BackendSpec:
    id: str
    name: str
    family: str
    protocol: str
    command: list[str]
    description: str = ""
    model: str = ""
    model_path: str = ""
    license: str = ""
    source_url: str = ""
    required_commands: list[str] = field(default_factory=list)
    required_paths: list[str] = field(default_factory=list)
    required_python_modules: list[str] = field(default_factory=list)
    capabilities: Capabilities = field(default_factory=Capabilities)
    options: dict[str, Any] = field(default_factory=dict)
    environment: dict[str, str] = field(default_factory=dict)
    setup: str = ""
    manifest_path: str = ""

    @classmethod
    def from_dict(cls, value: dict[str, Any], manifest_path: Path) -> "BackendSpec":
        capabilities = Capabilities(**value.get("capabilities", {}))
        return cls(
            id=value["id"],
            name=value["name"],
            family=value["family"],
            protocol=value["protocol"],
            command=list(value["command"]),
            description=value.get("description", ""),
            model=value.get("model", ""),
            model_path=value.get("model_path", ""),
            license=value.get("license", ""),
            source_url=value.get("source_url", ""),
            required_commands=list(value.get("required_commands", [])),
            required_paths=list(value.get("required_paths", [])),
            required_python_modules=list(value.get("required_python_modules", [])),
            capabilities=capabilities,
            options=dict(value.get("options", {})),
            environment=dict(value.get("environment", {})),
            setup=value.get("setup", ""),
            manifest_path=str(manifest_path),
        )

    def public_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result.pop("environment", None)
        return result


@dataclass(frozen=True)
class TranscriptRequest:
    audio_path: str
    language: str | None = "en"
    prompt: str | None = None
    word_timestamps: bool = False
    options: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class TranscriptResult:
    backend_id: str
    text: str
    wall_ms: float
    audio_seconds: float
    backend_ms: float | None = None
    load_ms: float | None = None
    preprocess_ms: float | None = None
    decode_ms: float | None = None
    warm: bool = False
    segments: list[dict[str, Any]] = field(default_factory=list)
    words: list[dict[str, Any]] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    error: str | None = None

    @property
    def realtime_factor(self) -> float | None:
        if self.wall_ms <= 0:
            return None
        return self.audio_seconds / (self.wall_ms / 1000.0)

    def as_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["realtime_factor"] = self.realtime_factor
        return result
