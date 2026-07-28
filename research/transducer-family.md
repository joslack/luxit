# Efficient transducer, CTC, and streaming ASR on Apple Silicon

Research date: 2026-07-28  
Target machine: Apple M3 Pro, 11 CPU cores (5 performance + 6 efficiency), 18 GB unified memory  
Scope: Parakeet, Nemotron, Moonshine, sherpa-onnx/Zipformer, and adjacent small CTC/Conformer models. This document deliberately does not cover Whisper-family runtimes.

## Bottom line

The first useful benchmark set should be:

1. **Parakeet TDT 0.6B v3 through FluidAudio/Core ML** — likely the best multilingual, high-throughput batch path on this Mac.
2. **Parakeet TDT 0.6B v3 through the already-installed `libparakeet`/ggml** — the easiest zero-new-runtime comparison, with useful quantization and CPU/GPU controls.
3. **Parakeet Unified EN 0.6B through FluidAudio** — a newer English model with both high-quality batch and true buffered-streaming modes.
4. **Moonshine Voice Small and Medium Streaming through ONNX Runtime** — very responsive English streaming models, with CPU and Core ML execution-provider variants worth measuring separately.
5. **sherpa-onnx English streaming Zipformer 20M** — a tiny, low-memory streaming baseline. Add the larger 2023-06-26 English Zipformer if the 20M model is not accurate enough.
6. **Parakeet TDT-CTC 110M through FluidAudio** — a compact English batch model and a useful test of CTC vocabulary/keyword biasing.

Add **Nemotron Streaming EN**, **Nemotron 3.5 multilingual**, and **SenseVoice Small** in a second wave. They provide interesting streaming/multilingual coverage but require large extra artifacts and have more API/version drift today.

Do not combine these behind a single lowest-common-denominator `transcribe(path) -> string` API. Normalize audio and results, but make capabilities explicit. In particular, a Whisper-style prompt is not equivalent to sherpa hotwords, CTC keyword boosting, a fixed model language, or a transducer decoder's retained state.

## Recommended adapter boundary

### Stable host-facing protocol

All backends should accept in-memory interleaved-mono `Float32` samples. The harness should perform one canonical conversion to 16 kHz mono for correctness comparisons and keep the original file only as provenance. A backend may resample internally for an additional native-path experiment, but that run must have a different configuration ID.

```text
Backend
  descriptor() -> BackendDescriptor
  prepare(ModelSpec, PrepareOptions) -> PreparedBackend

PreparedBackend
  capabilities() -> Capabilities
  transcribe(AudioBuffer, RequestOptions) -> Transcript
  startStream(StreamOptions) -> StreamSession       // optional capability
  reset()
  close()

StreamSession
  push(AudioChunk) -> [StreamEvent]
  finish() -> Transcript
  reset()
  close()
```

Suggested normalized data:

```json
{
  "backendId": "fluid.parakeet-v3",
  "modelId": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
  "artifactRevision": "pinned commit or release",
  "audio": {
    "sampleRate": 16000,
    "channels": 1,
    "sampleCount": 123456,
    "durationMs": 7716
  },
  "request": {
    "language": "auto",
    "timestamps": "word",
    "hotwords": [],
    "prompt": null,
    "backendOptions": {
      "fluid": {"modelVersion": "v3"}
    }
  },
  "result": {
    "text": "...",
    "language": "en",
    "segments": [],
    "words": [],
    "warnings": [],
    "native": {}
  },
  "timing": {
    "processSpawnMs": 0,
    "modelLoadMs": 0,
    "firstInferenceMs": 0,
    "inferenceMs": 0,
    "wallMs": 0,
    "audioDurationMs": 0,
    "realTimeFactor": 0,
    "timesRealTime": 0,
    "firstPartialMs": null,
    "stablePartialMs": null,
    "finalizationMs": null
  },
  "resources": {
    "peakResidentBytes": null,
    "energyImpact": null
  }
}
```

`Capabilities` should independently declare:

- batch transcription
- streaming partials
- endpoint/end-of-utterance detection
- fixed, selected, or automatically detected language
- segment, token, and word timestamps
- confidence/probability
- text prompt
- hotword/context biasing
- punctuation and capitalization
- supported input sample rates
- supported execution devices and precisions

If a feature is unsupported, reject it before inference. Never silently map a text prompt to hotwords or ignore it.

### Runtime isolation

Use in-process Swift/C adapters where the ABI is stable:

- FluidAudio via Swift Package Manager
- `libparakeet.dylib` via the installed C header
- sherpa-onnx via its C API, once one pinned release is bundled

Use a small JSON-lines worker process for Python- or ORT-heavy alternatives:

- Parakeet MLX
- Moonshine Python, unless the Swift package is chosen
- Transformers/NeMo reference checks

One worker owns one loaded model. Serialize inference on a given model context unless its API explicitly promises concurrency. This keeps model loading out of warm latency, avoids Python/Swift dependency collisions, and makes killing a leaked or wedged runtime safe.

### Benchmark lifecycle

Record four distinct costs:

1. **Install/download/compile** — artifact acquisition and Core ML compilation. Report separately and never fold it into ordinary latency.
2. **Cold process + model load** — new process, caches already present.
3. **First inference** — loaded model, first utterance; this can trigger graph specialization or lazy allocations.
4. **Steady-state inference** — randomized repeated utterances through the same loaded instance.

For live UX, additionally record time to first partial, partial revision count, time from speech end to stable text, and time to final endpoint. A model that is 100x real time in batch may still feel worse than a slower streaming model.

For pre-cut benchmark utterances, disable backend VAD and diarization where possible. Test native VAD/end-pointing in a separate live-stream suite.

## Backend matrix

| Adapter | Best initial model | Mode | Language | Prompt/bias | Timestamp support | Mac execution | License note |
|---|---|---|---|---|---|---|---|
| FluidAudio | Parakeet TDT 0.6B v3 | Batch | 25 European languages, auto | No prompt | Token/word/segment exposed by model/runtime | Core ML, mixed ANE/CPU | Base weights CC-BY-4.0 |
| libparakeet | Parakeet TDT 0.6B v3 Q8_0 and Q4_K | Batch/chunk callback | Model-defined; v3 multilingual | No exposed prompt; retained state is not prompting | Segment plus token timing/probability | ggml Metal or CPU | Conversion repo says MIT; base weights remain CC-BY-4.0 |
| FluidAudio | Parakeet Unified EN 0.6B | Batch + buffered stream | English | No prompt | Streaming events/results; verify word timing per pinned API | Core ML, INT8 or FP16 encoder | Base model uses NVIDIA Open Model License; conversion metadata must be audited |
| FluidAudio | Parakeet TDT-CTC 110M | Batch/fixed windows | English | CTC keyword/custom vocabulary path; not a prompt | TDT/CTC-dependent | Core ML | CC-BY-4.0 |
| Moonshine Voice | Small/Medium Streaming | Streaming + batch-like finish | English; separate models for several languages | No prompt/hotword today | Line and optional word timing | ONNX Runtime CPU or Core ML EP | English weights MIT; non-English weights use Moonshine Community License |
| sherpa-onnx | Streaming Zipformer EN 20M | True streaming | English model | Hotwords/context score on compatible transducers | Token timestamps and partial results | ONNX Runtime CPU by default | Runtime Apache-2.0; each model has its own license |
| FluidAudio/sherpa | Nemotron Streaming EN 0.6B | True streaming | English | No prompt | No word timestamps promised by base card | Core ML or ONNX Runtime CPU | NVIDIA Open Model License |
| FluidAudio/sherpa | Nemotron 3.5 0.6B | True streaming | 35 languages on base card; locale/prompt selection in deployments | Language prompt ID, not free-form text | Runtime-dependent | Core ML or ONNX Runtime CPU | OpenMDW-1.1 on base model |
| FluidAudio | SenseVoice Small | Non-autoregressive batch | Mandarin, Cantonese, English, Japanese, Korean in released checkpoint | No prompt | Runtime-dependent | Core ML | FunASR model license |
| Parakeet MLX | Parakeet v2/v3/110M variants | Batch plus experimental stream | Model-defined | No prompt; beam parameters | Word/token alignments | MLX GPU | Code license and weight license are separate |

## 1. Installed ggml `libparakeet`

The Homebrew `whisper-cpp` 1.9.1 installation already includes:

```text
/opt/homebrew/opt/whisper-cpp/bin/parakeet-cli
/opt/homebrew/opt/whisper-cpp/bin/parakeet-quantize
/opt/homebrew/opt/whisper-cpp/include/parakeet.h
/opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib
/opt/homebrew/opt/whisper-cpp/lib/pkgconfig/parakeet.pc
```

This is a strong first adapter because it needs no new runtime. Link through `pkg-config parakeet` or the explicit Homebrew prefix; do not shell out to the CLI for normal benchmarking.

The installed C ABI is:

```c
struct parakeet_context_params cp = parakeet_context_default_params();
cp.use_gpu = true;
cp.gpu_device = 0;

struct parakeet_context *ctx =
    parakeet_init_from_file_with_params(model_path, cp);

struct parakeet_state *state = parakeet_init_state(ctx);
struct parakeet_full_params p =
    parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
p.n_threads = 4;
p.no_context = true;

int rc = parakeet_full_with_state(ctx, state, p, samples, n_samples);
// For short clips that fit the model context:
// int rc = parakeet_chunk(ctx, state, p, samples, n_samples);

int nseg = parakeet_full_n_segments_from_state(state);
const char *text =
    parakeet_full_get_segment_text_from_state(state, segment_index);
parakeet_token_data td =
    parakeet_full_get_token_data_from_state(state, segment_index, token_index);

struct parakeet_timings *timings = parakeet_get_timings(ctx);
// timings: sample_ms, encode_ms, decode_ms

parakeet_free_state(state);
parakeet_free(ctx);
```

Important ABI facts from the installed header:

- Input is 16 kHz mono float PCM; `PARAKEET_SAMPLE_RATE` is 16000.
- The only exposed sampling strategy is greedy.
- There is no initial prompt, language, beam, or hotword field.
- Token data includes ID, duration index/value, frame index, probability/log probability, `t0`, `t1`, and `is_word_start`.
- Segment callbacks, per-token callbacks, progress callbacks, and cancellation callbacks are available.
- `parakeet_full` is explicitly not thread-safe on the same context. Allocate separate state only for API hygiene, not as proof that parallel inference is safe.
- `parakeet_chunk` is documented as more efficient for short clips that fit the model context. Benchmark it against `full_with_state`; do not assume it implements a semantically correct live stream across arbitrary chunks.

The CLI is useful as a smoke test:

```bash
parakeet-cli \
  --model models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
  --threads 4 \
  --print-segments \
  input.wav
```

Its relevant flags are `--threads`, `--model`, `--no-gpu`, `--device`, `--print-segments`, `--output-txt`, `--output-file`, and `--no-prints`.

Official converted artifacts are in [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF). At the time of research it offered v3 `f32`, `f16`, `q8_0`, `q4_0`, and `q4_k` files:

```bash
hf download ggml-org/parakeet-GGUF \
  ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
  --local-dir models
```

Initial sweep on this M3 Pro:

- Q8_0 + Metal, threads 4
- Q4_K + Metal, threads 4
- Q8_0 + CPU, threads 1, 2, 4, and 6
- Q4_K + CPU, threads 1, 2, 4, and 6

More threads are not automatically faster on asymmetric Apple CPUs. Avoid 11-thread defaults until measured. Record libparakeet's sample/encode/decode timings in addition to wall time.

License warning: the conversion repository's metadata/code may say MIT, but the originating [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) weights are CC-BY-4.0. The benchmark registry should preserve both conversion provenance and the base-weight license/attribution.

## 2. FluidAudio/Core ML

[FluidAudio](https://github.com/FluidInference/FluidAudio) is the most native way to exercise the Apple Neural Engine and is the likely performance leader. It requires macOS 14+ and is Apache-2.0 as a runtime. Model licenses remain independent.

Pin an exact tag or commit. The public API and even enum names have changed quickly. The current README showed:

```swift
.package(
    url: "https://github.com/FluidInference/FluidAudio.git",
    from: "0.12.4"
)
```

### Parakeet TDT v2/v3

Representative current API:

```swift
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .v3)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)

let result = try await manager.transcribe(
    samples,
    source: .microphone
)
print(result.text)
```

Some documentation revisions use `loadModels` rather than `initialize`; the adapter must be compiled against the pinned package tag, not copied from a floating README.

For managed download/cache behavior, use `AsrModels.downloadAndLoad(version:)`. For offline and reproducible runs use `ModelHub.offlineMode = true` and `AsrModels.load(from:configuration:)` against a registry-selected local directory. Do not hardcode individual `.mlmodelc` component names when `AsrModels` or the model manifest can resolve them.

Input is 16 kHz mono `Float32`. FluidAudio also exposes `AudioConverter.resampleAudioFile(path:)` and `resampleBuffer`, but canonical harness resampling should be the default.

Capabilities:

- v2 is English-only.
- v3 supports automatic recognition across 25 European languages: Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian, and Ukrainian.
- The base v3 model exposes word/segment timestamps and automatic language detection.
- There is no free-form initial prompt.
- Punctuation/capitalization claims differ between the NVIDIA and conversion cards. Treat them as an observed artifact property and score both normalized and raw text.

[FluidAudio's v2 Core ML card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) reports roughly 800 MB peak memory and a large real-time factor on an M4 Pro. [The v3 card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) describes mixed-precision ANE/CPU execution. Those numbers are expectations, not substitutes for the user's benchmark.

Core ML compilation can dominate first use. Download/compile once, persist the cache, then measure cold process load, first inference, and warm inference separately.

### Parakeet TDT-CTC 110M

[The 110M Core ML artifact](https://huggingface.co/FluidInference/parakeet-tdt-ctc-110m-coreml) is a compelling compact English model. It has a fused mel/FastConformer encoder, TDT decoder, and auxiliary CTC head, using a fixed 15-second/240,000-sample input window.

Documented CLI discovery and smoke tests:

```bash
fluidaudiocli download --model-version tdt-ctc-110m
fluidaudiocli transcribe audio.wav --model-version tdt-ctc-110m
fluidaudiocli asr-benchmark \
  --subset test-clean \
  --model-version tdt-ctc-110m
```

The model card lists approximately 207 MB for the fused preprocessor/encoder, 7.5 MB for the decoder, and 2.7 MB for joint decision, with about 0.3 GB reported peak memory. Verify real RSS on this machine.

Use the TDT head for ordinary transcript comparison. Treat CTC custom vocabulary/keyword spotting as a separate configuration because keyword recall is not equivalent to end-to-end transcript fidelity. This path is useful for the user's technical vocabulary: derive a small hotword list from each prompt, run both unbiased and CTC-biased configurations, and report them as different systems.

### Parakeet Unified EN 0.6B

This is the most important newer candidate. [NVIDIA Parakeet Unified EN 0.6B](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) is one English FastConformer-RNNT model supporting both fixed-window batch and buffered streaming with punctuation/capitalization. [FluidAudio's Core ML conversion](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml) exposes both modes:

```swift
let batch = try await UnifiedAsrManager.fromHub()
let result = try await batch.transcribe(samples)

let live = try await StreamingUnifiedAsrManager.fromHub(
    variant: .parakeetUnified2080ms
)
```

Available streaming tiers in the current artifact/docs include roughly 320, 640, 1120, and 2080 ms lookahead/chunk variants, plus a 15-second offline path. Start with 1120 and 2080 ms for accuracy, and add 320 ms as the latency extreme. The model uses a 1024-token vocabulary and approximately 80 ms encoder frames.

The conversion exposes FP16 and INT8 encoder variants. Benchmark both only if the pinned package makes the selection explicit; otherwise record the manifest-selected precision in `native`.

Licensing needs an explicit audit before redistribution. The NVIDIA base card uses the NVIDIA Open Model License, while some conversion metadata has reported CC-BY-4.0. Retain the stricter/original license until provenance is resolved.

### Nemotron and end-of-utterance models

[NVIDIA Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) is a 600M Cache-Aware FastConformer RNNT with punctuation/capitalization and 80/160/560/1120 ms streaming configurations. It is English-only and uses the NVIDIA Open Model License.

[FluidAudio's Core ML conversion](https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml) has a `StreamingNemotronAsrManager`. Representative API is:

```swift
let manager = try await StreamingNemotronAsrManager(
    chunkSize: selectedChunk,
    configuration: config
)
try await manager.loadModels(modelDir: modelDirectory)
let text = try await manager.transcribe(samples)
await manager.reset()
```

Chunk enums in the package documentation and model directories have drifted. Some docs show 160/320/1600 while model bundles show 80/160/560/1120. The adapter must discover available variants from a pinned manifest and translate its own stable IDs rather than assume an enum/string.

[Parakeet Realtime EOU 120M Core ML](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml) is an English RNNT that emits an end-of-utterance token. It is more interesting for push-to-talk UX than raw batch WER:

```swift
let manager = StreamingEouAsrManager(
    chunkSize: .ms160,
    eouDebounceMs: 1280
)
try await manager.loadModels(modelDir: modelsURL)

_ = try await manager.process(audioBuffer: buffer)
let transcript = try await manager.finish()
await manager.reset()
```

Again, older docs use `initialize`, `startStreaming`, and `feedAudio`, and current artifact directories have not always matched enum names. Pin and compile-test.

[Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) is the stronger future multilingual-streaming option. Its base card currently lists 35 languages and OpenMDW-1.1. Sherpa deployments expose per-stream locale selection; Fluid's conversion organizes Latin/multilingual artifacts by latency tier. Because it is a large extra download with recent API churn, add it only after the first benchmark loop works.

### FluidAudio version strategy

The model catalog, Swift enum names, and Hugging Face repositories have moved faster than ordinary application code. Store:

```json
{
  "runtime": "FluidAudio",
  "runtimeRevision": "exact tag or commit",
  "modelRepo": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
  "modelRevision": "exact commit",
  "modelVersion": "v3",
  "variant": null,
  "precision": "manifest-selected",
  "license": "CC-BY-4.0",
  "baseModel": "nvidia/parakeet-tdt-0.6b-v3"
}
```

Have one adapter source file per manager family rather than a reflection-heavy universal Fluid adapter. All of them can implement the same host protocol.

## 3. Moonshine Voice

The active project is [moonshine-ai/moonshine](https://github.com/moonshine-ai/moonshine), not just the older UsefulSensors Keras demo. It provides an ONNX Runtime implementation and a [Swift package](https://github.com/moonshine-ai/moonshine-swift).

Current model families include:

- English Tiny 26M and Base 58M
- English Tiny Streaming 34M
- English Small Streaming 123M
- English Medium Streaming 245M
- separate Arabic, Japanese, Mandarin, Spanish, Ukrainian, Vietnamese, and Korean artifacts

English weights are MIT. Non-English weights use the Moonshine Community License, which is not equivalent to MIT and restricts commercial use. Record license per artifact.

The recommended Swift acquisition path is catalog-driven:

```swift
let downloader = AssetDownloader(...)
try await downloader.ensureModelPresent(
    root: modelDirectory,
    spec: .stt(language: "en")
) { progress in
    // report progress
}

let transcriber = try Transcriber(
    modelPath: modelDirectory.path,
    modelArch: .smallStreaming
)
```

The Python package offers a convenient reference and worker implementation:

```bash
pip install moonshine-voice
moonshine-voice download --stt --language en
```

```python
from moonshine_voice import Transcriber

t = Transcriber(
    model_path=model_path,
    model_arch=model_arch,
    options={
        "ort_providers": "CoreML,CPU",
        "coreml_cache_dir": cache_dir,
        "vad_threshold": 0,
        "return_audio_data": False,
    },
)

batch_result = t.transcribe_without_streaming(
    audio_float32,
    sample_rate,
    flags=0,
)

t.add_listener(listener)
t.start()
t.add_audio(chunk, sample_rate)
t.stop()
```

Results/events expose line text, start time, duration, completion, and optional word timing. Input can use arbitrary mono sample rates because Moonshine resamples internally, but feed canonical 16 kHz in the comparison suite.

Performance controls worth exposing only in `backendOptions.moonshine`:

- `ort_providers`: benchmark `"CPU"` and `"CoreML,CPU"` as separate systems
- persistent `coreml_cache_dir`
- model architecture
- VAD threshold and maximum segment duration
- transcription and update intervals
- maximum tokens per second
- optional ORT timing logs

For cut utterances, set VAD off. For live UX, restore the model's intended VAD behavior. The Core ML execution provider can have a significant first-run compilation cost, and unsupported ONNX operations may fall back to CPU. Persistent compilation cache and provider diagnostics are mandatory.

Start with Small Streaming and Medium Streaming. Tiny Streaming is useful as a speed floor but is likely to lose technical terms. The old `moonshine/tiny` and `moonshine/base` Keras/Hugging Face checkpoints are useful for historical comparison, not the preferred shipping backend.

## 4. sherpa-onnx and Zipformer

[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) is Apache-2.0 and supplies a stable C API, Swift bindings/examples, downloadable macOS arm64 binaries, and many ONNX models. Runtime license does not override model license.

On macOS, the ordinary binary/Python wheel uses ONNX Runtime CPU. A custom Core ML execution-provider build may be possible, but graph fallbacks and build complexity make CPU the honest default. Benchmark `num_threads` 1, 2, 4, and 6, and benchmark INT8 and FP32 artifacts as different systems.

### Offline C API

The public [sherpa-onnx C API](https://k2-fsa.github.io/sherpa/onnx/c-api/html/index.html) follows this shape:

```c
SherpaOnnxOfflineRecognizerConfig config = {0};
config.feat_config.sample_rate = 16000;
config.feat_config.feature_dim = 80;
config.model_config.transducer.encoder = encoder_path;
config.model_config.transducer.decoder = decoder_path;
config.model_config.transducer.joiner = joiner_path;
config.model_config.tokens = tokens_path;
config.model_config.provider = "cpu";
config.model_config.num_threads = 4;
config.decoding_method = "greedy_search";

const SherpaOnnxOfflineRecognizer *recognizer =
    SherpaOnnxCreateOfflineRecognizer(&config);
const SherpaOnnxOfflineStream *stream =
    SherpaOnnxCreateOfflineStream(recognizer);

SherpaOnnxAcceptWaveformOffline(
    stream, 16000, samples, n_samples
);
SherpaOnnxDecodeOfflineStream(recognizer, stream);

const SherpaOnnxOfflineRecognizerResult *result =
    SherpaOnnxGetOfflineStreamResult(stream);
// copy result->text, tokens, and timestamps before destroying it
```

Destroy result, stream, and recognizer through the matching API functions. Use the exact struct layout from the pinned header.

### Online C API

```c
SherpaOnnxOnlineRecognizerConfig config = {0};
config.feat_config.sample_rate = 16000;
config.feat_config.feature_dim = 80;
config.model_config.transducer.encoder = encoder_path;
config.model_config.transducer.decoder = decoder_path;
config.model_config.transducer.joiner = joiner_path;
config.model_config.tokens = tokens_path;
config.model_config.provider = "cpu";
config.model_config.num_threads = 4;
config.decoding_method = "greedy_search";

const SherpaOnnxOnlineRecognizer *recognizer =
    SherpaOnnxCreateOnlineRecognizer(&config);
const SherpaOnnxOnlineStream *stream =
    SherpaOnnxCreateOnlineStream(recognizer);

SherpaOnnxOnlineStreamAcceptWaveform(
    stream, 16000, chunk, chunk_samples
);
while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) {
    SherpaOnnxDecodeOnlineStream(recognizer, stream);
}

const SherpaOnnxOnlineRecognizerResult *partial =
    SherpaOnnxGetOnlineStreamResult(recognizer, stream);
```

Compatible transducer models can create streams with hotwords/context scores. This is a real differentiator for personal technical language, but it must be reported as a biased configuration rather than a prompt-equivalent setting.

The [official model index](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html) links release tarballs and Hugging Face repositories. Store artifact URLs, checksums, and required filenames in a manifest; do not infer encoder/decoder/joiner names.

Recommended first models:

- `csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17` — tiny English streaming baseline.
- `csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26` — larger English streaming comparison, FP32 and INT8 when available.
- A Parakeet or Nemotron sherpa conversion only when comparing runtime effects on the same architecture.

Zipformer typically emits partial text and token timestamps but no polished punctuation/capitalization. Score normalized correctness and raw formatting separately.

### Nemotron through sherpa-onnx

Sherpa provides [Nemotron Streaming documentation](https://k2-fsa.github.io/sherpa/onnx/nemo/nemotron-streaming.html) and ONNX packages. An English INT8 560 ms package is roughly 623 MB encoder plus small decoder/joiner files. This is the most practical non-Core-ML Nemotron path.

Newer sherpa releases also support Nemotron 3.5 and buffered RNNT streaming for Parakeet Unified. These are valuable same-model/different-runtime comparisons once the baseline adapters are reliable, but each adds hundreds of megabytes.

## 5. Parakeet through MLX

[parakeet-mlx](https://github.com/senstella/parakeet-mlx) is a useful Apple-GPU validation runtime, distributed independently of NVIDIA. It supports TDT, RNNT, CTC, and hybrid TDT-CTC conversions in the [MLX Community Parakeet collection](https://huggingface.co/collections/mlx-community/parakeet).

```python
from parakeet_mlx import from_pretrained

model = from_pretrained(
    "mlx-community/parakeet-tdt-0.6b-v3",
    cache_dir=cache_dir,
)
result = model.transcribe(
    "audio.wav",
    chunk_duration=120.0,
    overlap_duration=15.0,
)

print(result.text)
for sentence in result.sentences:
    print(sentence.text, sentence.start, sentence.end)
```

Current controls include greedy or TDT beam decoding, beam size, length penalty, patience, duration reward, FP32/BF16, full/local attention, local attention context, chunk duration, overlap, and sentence splitting. It also has a `transcribe_stream` context, but benchmark its semantics carefully: streamed chunking of an offline-trained encoder is not necessarily equivalent to a native cache-aware streaming model.

Use MLX as an optional worker-process backend, not the initial application dependency:

- It gives a useful GPU-runtime comparison against Core ML and ggml.
- It adds Python/MLX/Hugging Face dependencies.
- It shares unified memory with the rest of the app and can distort simultaneous measurements.
- Model cache defaults to the Hugging Face cache; override and record it.

The repository code license and each NVIDIA-derived weight license must both be retained.

## 6. SenseVoice and other small CTC/Conformer options

[SenseVoice](https://github.com/FunAudioLLM/SenseVoice) is a non-autoregressive SANM/CTC family. The released [SenseVoiceSmall checkpoint](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) is about 234M parameters and practically covers Mandarin, Cantonese, English, Japanese, and Korean while also producing speech-event/emotion tags.

FluidAudio's [SenseVoice Small Core ML conversion](https://huggingface.co/FluidInference/sensevoice-small-coreml) uses a CPU preprocessor, ANE-oriented encoder/CTC graph, and host greedy decoding, with FP16/INT8 variants and sliding-window support.

It is a good second-wave multilingual/non-autoregressive model, but not a priority for an English personal-dictation benchmark. It has no free-form prompt. Its weight license is the FunASR Model License, so do not infer permissive terms from the FluidAudio runtime.

Other sherpa-onnx CTC/Paraformer models are most valuable when a user's language requires them. Model-specific language coverage and weight licenses should be registry facts, not backend assumptions.

## Model registry and downloads

Use a checked-in declarative registry, but keep downloaded artifacts outside Git:

```json
{
  "id": "parakeet-v3-libparakeet-q8",
  "family": "parakeet-tdt",
  "adapter": "libparakeet",
  "displayName": "Parakeet TDT 0.6B v3 · ggml Q8_0",
  "source": {
    "repo": "ggml-org/parakeet-GGUF",
    "revision": "PIN_ME",
    "files": [{
      "name": "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
      "sha256": "PIN_ME"
    }],
    "baseModel": "nvidia/parakeet-tdt-0.6b-v3"
  },
  "license": {
    "runtime": "MIT",
    "weights": "CC-BY-4.0",
    "attribution": ["NVIDIA", "base model URL", "conversion URL"]
  },
  "capabilities": {
    "batch": true,
    "streaming": false,
    "languages": ["bg", "hr", "cs", "da", "nl", "en", "et", "fi",
      "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt",
      "ro", "sk", "sl", "es", "sv", "ru", "uk"],
    "languageMode": "automatic",
    "prompt": false,
    "hotwords": false,
    "wordTimestamps": true
  },
  "defaults": {
    "device": "metal",
    "threads": 4,
    "backendOptions": {"quantization": "q8_0"}
  }
}
```

Downloader requirements:

- exact revision and SHA-256
- resumable download
- bytes required and bytes free before starting
- license/attribution displayed before acquisition
- atomic move from temporary file after checksum verification
- no automatic multi-gigabyte download merely because the UI enumerated a model
- explicit states: unavailable, downloadable, downloading, compiling, ready, failed
- artifact-size and expected peak-memory metadata
- runtime version/ABI compatibility checks

For FluidAudio and Moonshine, prefer their own manifest/catalog resolver, then record the resolved files and revisions. For ggml and sherpa, the benchmark's registry owns exact URLs/checksums.

On an 18 GB Mac, keep only one large runtime/model active during authoritative latency/RSS measurements. Concurrently loaded models are useful for interactive A/B UX but invalidate clean resource comparisons.

## Implementation order

### P0: fastest path to useful data

1. Generic audio/result/timing schema and model registry.
2. In-process `libparakeet` adapter using the already-installed ABI.
3. FluidAudio Parakeet v3 adapter.
4. FluidAudio Parakeet Unified batch/stream adapter.
5. Benchmark lifecycle that distinguishes compile, load, first, and warm runs.

### P1: meaningful architecture diversity

6. Moonshine Swift or JSON-lines worker adapter; test CPU and Core ML EP separately.
7. sherpa-onnx online/offline C adapter with English Zipformer 20M and hotword-capable configuration.
8. FluidAudio 110M TDT-CTC adapter, including an explicitly labeled keyword-biased run.

### P2: useful breadth after the harness is stable

9. Nemotron English streaming via FluidAudio or sherpa.
10. Nemotron 3.5 multilingual.
11. Parakeet MLX runtime comparison.
12. SenseVoice Small.

The first UI should show models that are not downloaded, but only download on explicit action. Each result card should identify model, runtime, device, precision/quantization, language mode, prompt/bias status, cold/warm state, WER/CER, wall latency, real-time factor, peak RSS, and streaming UX timings. This prevents a fast quantized hotword-biased run from being mistaken for the same system as an unbiased full-precision run.

## Primary sources

- FluidAudio repository: <https://github.com/FluidInference/FluidAudio>
- FluidAudio API guide: <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md>
- FluidAudio model catalog: <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md>
- FluidAudio benchmarks: <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md>
- NVIDIA Parakeet TDT 0.6B v3: <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
- Fluid Parakeet TDT v2 Core ML: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml>
- Fluid Parakeet TDT v3 Core ML: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- Fluid Parakeet TDT-CTC 110M Core ML: <https://huggingface.co/FluidInference/parakeet-tdt-ctc-110m-coreml>
- NVIDIA Parakeet Unified EN 0.6B: <https://huggingface.co/nvidia/parakeet-unified-en-0.6b>
- Fluid Parakeet Unified EN Core ML: <https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml>
- ggml Parakeet conversions: <https://huggingface.co/ggml-org/parakeet-GGUF>
- parakeet-mlx: <https://github.com/senstella/parakeet-mlx>
- MLX Parakeet collection: <https://huggingface.co/collections/mlx-community/parakeet>
- NVIDIA Nemotron Streaming EN: <https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b>
- Fluid Nemotron Streaming EN Core ML: <https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml>
- NVIDIA Nemotron 3.5 ASR Streaming: <https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b>
- Fluid Parakeet Realtime EOU Core ML: <https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml>
- Moonshine repository: <https://github.com/moonshine-ai/moonshine>
- Moonshine Swift: <https://github.com/moonshine-ai/moonshine-swift>
- sherpa-onnx repository: <https://github.com/k2-fsa/sherpa-onnx>
- sherpa-onnx C API: <https://k2-fsa.github.io/sherpa/onnx/c-api/html/index.html>
- sherpa-onnx pretrained model index: <https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html>
- sherpa-onnx online transducer models: <https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/index.html>
- sherpa-onnx Nemotron streaming: <https://k2-fsa.github.io/sherpa/onnx/nemo/nemotron-streaming.html>
- SenseVoice repository: <https://github.com/FunAudioLLM/SenseVoice>
- SenseVoice Small: <https://huggingface.co/FunAudioLLM/SenseVoiceSmall>
- Fluid SenseVoice Core ML: <https://huggingface.co/FluidInference/sensevoice-small-coreml>
