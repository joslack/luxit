from dataclasses import replace
from pathlib import Path
from unittest import TestCase, mock

from benchmark.sttbench.registry import BackendRegistry


class TransducerManifestTests(TestCase):
    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[1]
        self.registry = BackendRegistry(self.root)

    def test_transducer_manifests_are_present(self) -> None:
        ids = set(self.registry.specs.keys())
        expected = {
            "transducer-libparakeet-cli-v3-q8-0",
            "transducer-fluidaudio-parakeet-v2-coreml",
            "transducer-fluidaudio-parakeet-v3-coreml",
            "transducer-fluidaudio-parakeet-tdt-ctc-110m-coreml",
            "transducer-fluidaudio-parakeet-unified-en-coreml",
            "transducer-fluidaudio-nemotron-streaming-en-coreml",
            "transducer-moonshine-smallstream-en-cpu",
            "transducer-moonshine-smallstream-en-coreml",
            "transducer-sherpa-onnx-zipformer-en-20m-2023-02-17",
            "transducer-sherpa-onnx-zipformer-en-2023-06-26",
        }
        self.assertTrue(expected.issubset(ids))

    def test_manifest_protocols_and_required_checks(self) -> None:
        specs = self.registry.specs
        self.assertEqual(specs["transducer-libparakeet-cli-v3-q8-0"].protocol, "jsonl-worker")

        jsonl_ids = {
            "transducer-fluidaudio-parakeet-v2-coreml",
            "transducer-fluidaudio-parakeet-v3-coreml",
            "transducer-fluidaudio-parakeet-tdt-ctc-110m-coreml",
            "transducer-fluidaudio-parakeet-unified-en-coreml",
            "transducer-fluidaudio-nemotron-streaming-en-coreml",
            "transducer-moonshine-smallstream-en-cpu",
            "transducer-moonshine-smallstream-en-coreml",
            "transducer-sherpa-onnx-zipformer-en-20m-2023-02-17",
            "transducer-sherpa-onnx-zipformer-en-2023-06-26",
        }
        for backend_id in jsonl_ids:
            spec = specs[backend_id]
            self.assertEqual(spec.protocol, "jsonl-worker")
            script = Path(spec.command[-1])
            self.assertTrue(script.exists(), f"Missing worker script {script}")

        libparakeet = specs["transducer-libparakeet-cli-v3-q8-0"]
        self.assertFalse(libparakeet.capabilities.prompt)
        self.assertFalse(libparakeet.capabilities.streaming)
        self.assertTrue(libparakeet.capabilities.persistent is True)

        unified = specs["transducer-fluidaudio-parakeet-unified-en-coreml"]
        self.assertEqual(unified.capabilities.languages, ["en"])
        self.assertTrue(unified.capabilities.streaming)

        moon = specs["transducer-moonshine-smallstream-en-coreml"]
        self.assertEqual(moon.capabilities.languages, ["en"])
        self.assertFalse(moon.capabilities.prompt)
        self.assertTrue(moon.capabilities.streaming)

    def test_unavailable_reasons_expose_missing_items(self) -> None:
        libparakeet = self.registry.specs["transducer-libparakeet-cli-v3-q8-0"]
        moonshine = self.registry.specs["transducer-moonshine-smallstream-en-coreml"]
        sherpa = self.registry.specs["transducer-sherpa-onnx-zipformer-en-20m-2023-02-17"]

        unavailable_lib = replace(
            libparakeet,
            required_paths=[
                "/totally/missing/libparakeet.dylib",
                "${MODEL_DIR}/ggml/ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
            ],
        )
        available, reasons = self.registry.availability(unavailable_lib)
        self.assertFalse(available)
        self.assertIn("Missing path: /totally/missing/libparakeet.dylib", reasons)

        fake_missing_module = replace(moonshine, required_python_modules=["moonshine_voice_missing"])
        with mock.patch("benchmark.sttbench.registry.importlib.util.find_spec", return_value=None):
            available, reasons = self.registry.availability(fake_missing_module)
            self.assertFalse(available)
            self.assertIn("Missing Python module: moonshine_voice_missing", reasons)

        fake_path = replace(
            sherpa,
            required_paths=["/totally/missing/path.enc", "/totally/missing/path.dec"],
        )
        available, reasons = self.registry.availability(fake_path)
        self.assertFalse(available)
        self.assertIn("Missing path: /totally/missing/path.enc", reasons)

        public = self.registry.public_specs()
        self.assertEqual(len(public), len(self.registry.specs))
        for item in public:
            if not item["available"]:
                self.assertGreater(len(item["unavailable_reasons"]), 0)
