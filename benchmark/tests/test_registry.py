import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from sttbench.registry import BackendRegistry


class RegistryTests(unittest.TestCase):
    def test_reuses_model_with_same_filename_from_search_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "benchmark"
            manifests = root / "backends"
            models = Path(directory) / "existing"
            manifests.mkdir(parents=True)
            models.mkdir()
            existing = models / "model.bin"
            existing.write_bytes(b"model")
            manifest = {
                "id": "test",
                "name": "Test",
                "family": "test",
                "protocol": "command",
                "command": ["runner", "-m", "${MODEL_DIR}/nested/model.bin"],
                "model_path": "${MODEL_DIR}/nested/model.bin",
                "required_paths": ["${MODEL_DIR}/nested/model.bin"],
            }
            (manifests / "test.json").write_text(json.dumps(manifest))
            with patch.dict(
                os.environ,
                {"STTBENCH_MODEL_SEARCH_PATHS": str(models)},
            ):
                registry = BackendRegistry(root)
            self.assertEqual(registry.specs["test"].model_path, str(existing))
            self.assertIn(str(existing), registry.specs["test"].command)

    def test_unset_environment_path_has_actionable_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "benchmark"
            manifests = root / "backends"
            manifests.mkdir(parents=True)
            manifest = {
                "id": "test",
                "name": "Test",
                "family": "test",
                "protocol": "command",
                "command": ["runner"],
                "required_paths": ["${MISSING_RUNTIME}"],
            }
            (manifests / "test.json").write_text(json.dumps(manifest))
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop("MISSING_RUNTIME", None)
                registry = BackendRegistry(root)
            available, reasons = registry.availability(registry.specs["test"])
            self.assertFalse(available)
            self.assertEqual(reasons, ["Set environment variable: MISSING_RUNTIME"])


if __name__ == "__main__":
    unittest.main()
