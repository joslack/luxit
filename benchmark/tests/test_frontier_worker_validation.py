from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


def _load_worker():
    path = Path(__file__).resolve().parents[1] / "workers/frontier_asr_jsonl_worker.py"
    spec = importlib.util.spec_from_file_location("frontier_asr_jsonl_worker", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Failed to load frontier_asr_jsonl_worker module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


frontier_worker = _load_worker()


class FrontierWorkerValidationTests(unittest.TestCase):
    def test_unsupported_prompt_is_rejected(self):
        profile = {"supports_prompt": False}
        request = {"prompt": "do not ignore this", "language": "en"}
        errors = frontier_worker.validate_request(profile, request)
        self.assertEqual(len(errors), 1)
        self.assertIn("Prompt", errors[0])

    def test_translation_request_is_rejected_when_not_supported(self):
        profile = {
            "supported_languages": ["en", "es"],
            "supports_translation": False,
            "supports_prompt": False,
        }
        request = {
            "language": "en",
            "translate": True,
            "target_language": "es",
        }
        errors = frontier_worker.validate_request(profile, request)
        self.assertIn("Translation is not supported by this backend", errors)

    def test_language_is_checked_if_profile_declares_languages(self):
        profile = {"supported_languages": ["en", "fr"], "supports_prompt": False}
        request = {"language": "ja"}
        errors = frontier_worker.validate_request(profile, request)
        self.assertIn("Unsupported language", errors[0])

    def test_streaming_rejection_honors_profile(self):
        profile = {"supports_streaming": False, "supports_prompt": False}
        request = {"streaming": True}
        errors = frontier_worker.validate_request(profile, request)
        self.assertIn("Streaming is not supported by this backend", errors)
