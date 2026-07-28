"""Local, runtime-agnostic speech-to-text benchmarking."""

from .types import BackendSpec, TranscriptRequest, TranscriptResult

__all__ = ["BackendSpec", "TranscriptRequest", "TranscriptResult"]
