# Whisper-family backend research for the local STT benchmark

Research date: 2026-07-28  
Target machine: Apple M3 Pro, 18 GB unified memory, macOS 26.5.1  
Scope: Whisper-derived models and Mac-capable inference engines. This document does
not modify the existing Luxit implementation.

## Recommendation in one page

The harness should not make `model` synonymous with `backend`. The same model
architecture can run through several materially different engines:

- `large-v3-turbo` is a 4-decoder-layer multilingual Whisper model. It is a model,
  not an inference engine.
- `distil-large-v3` is a 2-decoder-layer English-only Whisper model. It can run in
  whisper.cpp, WhisperKit/Core ML, and MLX.
- whisper.cpp, WhisperKit, and MLX differ in kernels, model packaging, lifecycle,
  cancellation, prompt support, timestamp behavior, and cold-start behavior.

Implement these first:

1. **whisper.cpp native adapter** — preserve today's Luxit configuration as a
   baseline, then expose honest fast/balanced/reference decode profiles.
2. **WhisperKit native Swift/Core ML adapter** — the most important alternative
   for this Apple Silicon machine; benchmark turbo and Distil-Whisper.
3. **MLX worker adapter** — use one persistent Python worker and initially target
   either current `mlx-audio` or legacy `mlx-whisper`. They are separate runtime
   implementations of the same architecture, so keeping both forever is unlikely
   to add much value.
4. **faster-whisper CPU control** — optional. CTranslate2 has no Metal/MPS backend,
   so it is useful to answer “does an optimized CPU implementation win?” rather
   than as the expected Mac winner.

Do not initially implement `lightning-whisper-mlx`, PyTorch/OpenAI Whisper, or
speculative decoding. The first is an old, thin fork optimized for batching
30-second windows, has no clear repository/package license, and offers little for
short dictation latency. The latter two add large dependency or memory costs
without a credible Mac-specific advantage.

The highest-value initial benchmark matrix is:

| Engine | Model/artifact | Decode profile |
|---|---|---|
| whisper.cpp | current `large-v3-turbo-q5_0` | exact current Luxit beam-5 baseline |
| whisper.cpp | `large-v3-turbo-q5_0` | greedy-1, fixed English, no fallback, no timestamps |
| whisper.cpp | `distil-large-v3` | greedy-1, fixed English, no fallback, no timestamps |
| WhisperKit | compressed turbo | default compute units; greedy-1 and beam-5 |
| WhisperKit | compressed Distil large-v3 | default compute units; greedy-1 and beam-5 |
| MLX | turbo | greedy-1, fixed English, no timestamps |
| MLX | Distil large-v3 | greedy-1, fixed English, no timestamps |
| faster-whisper | turbo, CPU int8 | greedy-1 control |

Run the same randomized utterance order in two accuracy lanes:

- no prompt, for cross-engine fairness;
- the same short personal vocabulary/context prompt, for the actual dictation UX.

Primary latency results should disable timestamps, language detection, batching,
concurrency, and context carry-over. Measure word timestamps separately because
engines incur non-equivalent timestamp overhead.

## Existing Luxit baseline

Local inspection found Homebrew whisper.cpp 1.9.1 and these current artifacts:

- `small-q5_1`, approximately 181 MiB;
- `large-v3-turbo-q5_0`, approximately 547 MiB, the default;
- `large-v3-q5_0`, approximately 1.1 GiB.

The native bridge keeps the Whisper context warm for 60 seconds and calls
`whisper_full` on a serial queue with:

- Metal/GPU enabled;
- flash attention enabled;
- beam search, beam size 5, patience 1;
- six CPU threads;
- fixed English, no language detection;
- `no_context = true`;
- timestamps disabled;
- temperature 0 with fallback increment 0.2;
- optional initial prompt.

There is a separate Silero VAD pass at threshold 0.60 and, on rejection, another
pass at 0.35. It only rejects the whole utterance; it does not remove silence
before Whisper. Its context is loaded afresh on each pass. That means it can add
startup cost without reducing Whisper's input. Keep this exact path as the
regression baseline, but do not mistake it for whisper.cpp's built-in VAD
filtering.

Two current performance concerns are worth making visible in benchmark metadata:

1. Beam size 5 creates multiple decoder candidates. For short technical dictation,
   greedy decoding often produces a much better latency/quality point.
2. The 60-second model eviction policy creates an unlabelled mixture of warm and
   model-cold measurements. The benchmark needs an explicit lifecycle.

The Homebrew bottle is Metal-capable but is not built with
`WHISPER_COREML=1`; whisper.cpp's optional ANE encoder therefore requires a
separate source build and adjacent Core ML encoder artifact.

## Canonical adapter boundary

### Identity

Keep these axes independent:

```text
engine: whisper_cpp | whisperkit | mlx_whisper | mlx_audio | faster_whisper
model: tiny | small | large-v3 | large-v3-turbo | distil-large-v3
artifact/precision: q5_0 | q5_1 | q8_0 | f16 | coreml-compressed | mlx-fp16 | mlx-4bit
profile: exact-baseline | fast | balanced | reference | experimental
```

An engine-specific model ID and immutable revision/commit belong in the resolved
configuration. User-facing aliases must resolve before the timed run and the
resolved artifact should be included in every result.

### Request

Use one normalized request for all workers:

```json
{
  "protocol_version": 1,
  "request_id": "uuid",
  "audio": {
    "path": "/absolute/path/to/canonical.wav",
    "sample_rate_hz": 16000,
    "channels": 1,
    "format": "pcm_s16le"
  },
  "task": "transcribe",
  "language": "en",
  "prompt": "Luxit, PostgreSQL, MLX, Thunderbolt, ZFS",
  "timestamps": "none",
  "decoding": {
    "strategy": "greedy",
    "beam_size": 1,
    "best_of": 1,
    "temperature": 0,
    "temperature_fallback": false,
    "condition_on_previous_text": false,
    "vad": "off",
    "threads": 6
  }
}
```

`language: null` means detection. `prompt` is text at the public boundary even
where a backend internally needs token IDs. `timestamps` is exactly one of
`none`, `segment`, or `word`.

The adapter must reject unsupported options or return a warning. It must never
silently ignore them; otherwise model comparisons become invalid.

### Response

```json
{
  "protocol_version": 1,
  "request_id": "uuid",
  "backend_id": "whisperkit",
  "resolved_model": {
    "logical_name": "large-v3-turbo",
    "artifact": "openai_whisper-large-v3-v20240930_turbo_632MB",
    "revision": "pinned-sha"
  },
  "text": "normalized transcript text",
  "language": "en",
  "segments": [
    {
      "start_ms": 0,
      "end_ms": 2400,
      "text": "normalized transcript text",
      "words": null
    }
  ],
  "timing_ns": {
    "process_start": 0,
    "import": 0,
    "model_load": 0,
    "prewarm": 0,
    "audio_decode": 0,
    "inference": 0,
    "total": 0
  },
  "memory_bytes": {
    "rss_before": 0,
    "rss_after": 0,
    "peak_rss": 0
  },
  "warnings": [],
  "backend_metrics": {}
}
```

Only `total` should be used as the cross-engine UX latency. Engine-reported
inference time is diagnostic because engines draw their timing boundary
differently. Preserve raw text and structured segments; normalize punctuation or
case only in the scorer, never in the adapter.

### Lifecycle and transport

For Python backends, use one long-lived JSON-Lines worker per
engine/model/artifact. Standard output is protocol only and diagnostic logs go to
standard error. Required commands:

```text
list_models
initialize
transcribe
unload
shutdown
```

Native Swift adapters should implement the same lifecycle in-process. Serialize
requests per loaded model unless the engine explicitly guarantees concurrent use.
whisper.cpp documents that `whisper_full` on one context is not thread-safe; if
concurrency is later needed, allocate separate `whisper_state` objects and use
state-scoped APIs.

Model download/conversion is a `prepare` phase and never belongs inside a timed
transcription. Pin repository revisions and record artifact hashes.

### Cold, warm, cancellation, and benchmark semantics

Report these as separate conditions:

1. **process cold:** spawn/import plus model load plus inference;
2. **model cold:** already-running worker, model load plus inference;
3. **warm inference:** load once, run one unmeasured warm-up, then measure;
4. **Core ML specialization first use:** a special observed state, because ANE
   compilation is cached by the OS and cannot be reliably evicted.

Universal hard cancellation is terminating the worker process. Prefer native
cancellation when possible:

- whisper.cpp: `abort_callback` checked before GGML computation;
- WhisperKit: its transcription callback returns `Bool`; return `false` and also
  observe Swift `Task` cancellation;
- MLX: no dependable mid-kernel abort; terminate the worker for a hard deadline;
- faster-whisper: stop generator iteration between segments or terminate the
  worker.

For twenty short utterances, run sequentially and randomize engine order per
utterance. Do not batch or run competing engines concurrently: batching measures
throughput, and concurrency makes unified-memory pressure a confounder.

## Backend 1: whisper.cpp

### Why it remains necessary

whisper.cpp is the exact current baseline, has the smallest integration surface,
provides Metal on Apple Silicon, supports integer quantization, and exposes the
most complete low-level controls. It is MIT licensed. Stable at the research date
is v1.9.1.

Primary sources:

- [repository and build documentation](https://github.com/ggml-org/whisper.cpp)
- [C API](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h)
- [CLI implementation](https://github.com/ggml-org/whisper.cpp/blob/master/examples/cli/cli.cpp)
- [v1.9.1 release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.1)
- [official converted model repository](https://huggingface.co/ggerganov/whisper.cpp/tree/main)
- [model inventory and checksums](https://huggingface.co/ggerganov/whisper.cpp/blob/main/README.md)

### Install/build

The simple Metal baseline is:

```sh
brew install whisper-cpp
```

For a pinned native dependency in the application, build the repository at a tag
or commit and link the C API. A separate ANE encoder build is:

```sh
git clone https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp
git checkout v1.9.1
cmake -B build -DWHISPER_COREML=1 -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Official conversion instructions recommend Python 3.11 for Core ML generation:

```sh
python3.11 -m venv .venv-coreml
source .venv-coreml/bin/activate
pip install ane_transformers openai-whisper coremltools
./models/generate-coreml-model.sh large-v3-turbo
```

The compiled folder must be adjacent to the GGML file and named like
`ggml-large-v3-turbo-encoder.mlmodelc`. Pre-generated encoder archives also exist
in the official `ggerganov/whisper.cpp` Hugging Face repository. The first ANE
use performs device specialization and is much slower; later runs use the cached
specialization. The project's “more than 3x” statement is versus CPU-only encoder
execution, not necessarily versus the current Metal plus flash-attention path, so
the custom build is an experimental profile, not an assumed winner.

### In-process C contract

Initialize once:

```c
struct whisper_context_params cp = whisper_context_default_params();
cp.use_gpu = true;
cp.flash_attn = true;
cp.gpu_device = 0;
struct whisper_context *ctx =
    whisper_init_from_file_with_params(model_path, cp);
```

Build request-specific parameters:

```c
struct whisper_full_params p =
    whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
p.n_threads = threads;
p.language = language_or_null;
p.detect_language = language_or_null == NULL;
p.translate = false;
p.no_context = true;
p.no_timestamps = timestamps_mode == NONE;
p.token_timestamps = timestamps_mode == WORD;
p.initial_prompt = prompt_or_null;
p.temperature = 0.0f;
p.temperature_inc = temperature_fallback ? 0.2f : 0.0f;
p.greedy.best_of = 1;
p.abort_callback = abort_callback;
p.abort_callback_user_data = request;
int rc = whisper_full(ctx, p, pcm_f32, sample_count);
```

Use segment getters for text and timestamps and token getters for word-level
output. `whisper_full_lang_id` exposes the selected language. Use whisper.cpp's
timing APIs only as backend diagnostics; bracket the whole call independently.

For beam mode, use `WHISPER_SAMPLING_BEAM_SEARCH`, set `beam_search.beam_size`,
and set patience. The current code chooses the number of decoder candidates from
the configured best-of/beam values, so a true fast greedy profile must explicitly
set strategy to greedy and `best_of = 1`.

The CLI is useful as a conformance probe:

```sh
whisper-cli \
  --model /path/ggml-large-v3-turbo-q5_0.bin \
  --file /path/canonical.wav \
  --threads 6 \
  --language en \
  --beam-size 1 \
  --best-of 1 \
  --no-fallback \
  --no-timestamps \
  --no-prints
```

Do not use CLI full JSON for the primary latency lane: the CLI enables token
timestamps for that output mode. The app should call the C API, not spawn the CLI.

### Model discovery

Treat a local GGML file as a resolved artifact. Discovery should read a manifest
maintained by the harness rather than infer semantic identity from arbitrary
filenames. The official `ggerganov/whisper.cpp` Hugging Face repository provides
the initial URLs and checksums.

Useful official approximate disk sizes include:

| Artifact | Size |
|---|---:|
| small f16 / q5 | 466 MiB / 181 MiB |
| large-v3 f16 / q5 | 2.9 GiB / 1.1 GiB |
| large-v3-turbo f16 / q5 / q8 | 1.5 GiB / 547 MiB / 834 MiB |

Quantized model size is not proof of faster Metal inference. Benchmark q5, q8,
and f16 selectively; unified-memory traffic, dequantization, and kernel shape can
change the ordering.

### Exact knobs and what belongs in the harness

Expose in expert configuration:

- `threads` (`n_threads`);
- `use_gpu`, GPU device, and flash attention;
- greedy `best_of`, or beam size and patience;
- temperature and fallback increment;
- fixed language versus detection;
- prompt and context carry;
- none/segment/word timestamps;
- no-speech/log-probability/compression-ratio thresholds;
- suppress blank, non-speech tokens, or a token regex;
- built-in VAD threshold, minimum speech/silence, padding and overlap;
- experimental audio context;
- optional duration/offset and maximum text context.

Profiles should keep the common path understandable:

```text
exact-baseline:
  beam=5, threads=6, fallback=true, flash=true, English, no timestamps

fast:
  greedy best_of=1, threads=tuned, fallback=false, flash=true,
  fixed English, no context, no timestamps

balanced:
  greedy best_of=1, fallback=true, flash=true,
  fixed English, no context, no timestamps

reference:
  beam=5, fallback=true, fixed English, no context, no timestamps
```

Sweep threads `[4, 5, 6, 8, 11]` once on this 5-performance/6-efficiency-core
machine rather than assuming all cores or today's six is optimal. Save the chosen
value in the resolved profile.

Other optimizations:

- **Fixed language:** avoids language detection. Keep auto-detection as a
  separate capability test.
- **No fallback:** avoids re-decoding failed-temperature windows. Good for the
  primary short clean-utterance latency lane; keep fallback in balanced/reference.
- **No timestamps:** reduces extra decoding/alignment work. Benchmark word
  timestamps separately.
- **Built-in VAD filtering:** unlike the current reject-only Silero gate,
  whisper.cpp can remove silent audio before full inference. Keep the VAD model
  warm and test this only on padded/silent utterances; repeatedly loading it can
  erase the benefit.
- **`audio_ctx`:** may reduce work but the header calls out a significant quality
  risk. Experimental only.
- **`whisper_full_parallel`:** splits long recordings for throughput and may harm
  accuracy at chunk boundaries. It is irrelevant for these short dictation clips.
- **Flash attention:** default on in the installed CLI and current Luxit bridge.
  Test on/off once. DTW token timestamps conflict with flash attention, so never
  compare that mode to the normal latency lane.
- **Grammar-constrained decoding:** useful for command grammars, not comparable
  with open technical dictation. It belongs in a future command-mode benchmark.

### Current “random Whisper optimization” watchlist

As of the research date these are open pull requests, not stable dependencies:

- [#3905, optional ANEForge encoder backend](https://github.com/ggml-org/whisper.cpp/pull/3905)
- [#3848, Apple ANE decoder](https://github.com/ggml-org/whisper.cpp/pull/3848)
- [#3869, resumable/streaming transcription API](https://github.com/ggml-org/whisper.cpp/pull/3869)
- [#3941, flash-attention K/V padding mask](https://github.com/ggml-org/whisper.cpp/pull/3941)
- [#3939, CPU GELU SIMD work](https://github.com/ggml-org/whisper.cpp/pull/3939)

Do not build benchmark defaults from unmerged branches. Put them in a watchlist
with commit hashes if later tested. Stable v1.9.1 already has a C abort callback;
the separate open AbortSignal work is for another binding surface.

## Model variant: Distil-Whisper

`distil-large-v3` is an English-only Whisper-compatible model with the same
encoder family and two decoder layers. It has approximately 756 million
parameters. Its model card reports 6.3x speed versus large-v3 and performance
within about one WER point on its evaluation suite; those are useful hypotheses,
not substitutes for the user's recordings.

License: MIT.

Primary sources:

- [Distil large-v3 model card](https://huggingface.co/distil-whisper/distil-large-v3)
- [Distil-Whisper repository](https://github.com/huggingface/distil-whisper)
- [official GGML conversion](https://huggingface.co/distil-whisper/distil-large-v3-ggml/tree/main)

The official GGML repository provides:

```text
ggml-distil-large-v3.bin       ~1.52 GB (f16)
ggml-distil-large-v3-f32.bin   ~3.03 GB
```

Example preparation:

```python
from huggingface_hub import hf_hub_download

hf_hub_download(
    repo_id="distil-whisper/distil-large-v3-ggml",
    filename="ggml-distil-large-v3.bin",
    local_dir="./models",
)
```

It then uses the exact same whisper.cpp C contract. WhisperKit offers a compressed
Core ML variant named `distil-whisper_distil-large-v3_594MB`; legacy MLX has
`mlx-community/distil-whisper-large-v3`.

Prompt conditioning is supported. Because this variant is English-only, the
adapter should reject non-English requests and advertise no language-detection
benchmark lane rather than pretending it is multilingual.

Distil-Whisper can also be used as an assistant model for speculative decoding
with a full large-v3 teacher. Hugging Face reports that this reproduces the
teacher's output with roughly a 2x CUDA speedup. That path requires both models
in memory, is not implemented in whisper.cpp/WhisperKit/MLX, and has no established
Mac advantage. Defer it.

## Model variant: Whisper large-v3-turbo

`large-v3-turbo` is OpenAI's multilingual large-v3 derivative with the decoder
reduced from 32 layers to 4. It has approximately 809 million parameters and is
MIT licensed.

Primary model card:
[openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo).

Treat it as a logical model available through each compatible engine, not as one
backend. It is the best bridge from today's Luxit implementation to WhisperKit
and MLX because quality changes then mostly reflect runtime/artifact/precision
rather than a completely different model family.

## Backend 2: WhisperKit / Core ML

### Why implement it

WhisperKit is a native Swift/Core ML implementation designed for Apple Silicon
and can place stages on CPU, GPU, and Neural Engine. It is the most credible
Mac-specific alternative to whisper.cpp. The current upstream repository is
`argmaxinc/argmax-oss-swift`; older URLs and examples may still say WhisperKit.
License: MIT.

Primary sources:

- [Argmax OSS Swift / WhisperKit repository](https://github.com/argmaxinc/argmax-oss-swift)
- [releases](https://github.com/argmaxinc/argmax-oss-swift/releases)
- [configuration types](https://raw.githubusercontent.com/argmaxinc/argmax-oss-swift/main/Sources/WhisperKit/Core/Configurations.swift)
- [WhisperKit implementation](https://raw.githubusercontent.com/argmaxinc/argmax-oss-swift/main/Sources/WhisperKit/Core/WhisperKit.swift)
- [official Core ML model repository](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main)
- [device/model recommendations](https://huggingface.co/argmaxinc/whisperkit-coreml/raw/main/config.json)
- [Homebrew package](https://formulae.brew.sh/formula/whisperkit-cli)

### Install/integration

Use Swift Package Manager in the application:

```swift
.package(
    url: "https://github.com/argmaxinc/argmax-oss-swift.git",
    from: "1.0.0"
)
```

and link the `WhisperKit` product. Pin an exact version or revision for recorded
benchmark runs.

There is also a diagnostic CLI:

```sh
brew install whisperkit-cli
whisperkit-cli transcribe \
  --model tiny \
  --audio-path /path/canonical.wav \
  --verbose
```

Upstream source currently calls its executable `argmax-cli`, while Homebrew
retains the `whisperkit-cli` binary/package name. The application should not use
the CLI because process and model startup would dominate short utterances.

### Native contract and lifecycle

Construct and retain one instance:

```swift
let config = WhisperKitConfig(
    model: resolvedVariant,
    modelRepo: "argmaxinc/whisperkit-coreml",
    modelFolder: nil,
    computeOptions: computeOptions,
    prewarm: false,
    load: true,
    download: true
)
let pipe = try await WhisperKit(config)
```

The current 1.0 API transcribes arrays and returns one optional result per input:

```swift
let batches: [[TranscriptionResult]?] = try await pipe.transcribe(
    audioPaths: [canonicalPath],
    decodeOptions: options,
    callback: callback
)
```

It also accepts decoded `[[Float]]` audio. Older snippets returning one
`TranscriptionResult?` are stale. Flatten the returned results in order, preserve
segments/words, and concatenate text only at the canonical response boundary.

Relevant `DecodingOptions` include:

- task and language;
- temperature, fallback increment, and fallback count;
- top-K/sample length;
- language detection;
- skip special tokens;
- no timestamps and word timestamps;
- maximum initial timestamp and clip/window settings;
- prompt and prefix token IDs;
- token suppression and quality thresholds;
- concurrent worker count and chunking strategy.

The public harness accepts a text prompt. Convert it to `promptTokens` with the
loaded Whisper tokenizer, and record truncation/token count. Do not pass a text
prompt as though `DecodingOptions` accepted it directly.

WhisperKit exposes load, prewarm, and unload operations. Prewarm can force Core ML
specialization but is not free: the first device compilation may be large, while
normal cache-hit startup can become slower if unnecessary prewarming is included.
Report model load and prewarm separately.

Cancellation should use the transcription callback's Boolean continuation value,
combined with Swift `Task` cancellation. Keep process termination as the
cross-backend hard timeout.

### Model discovery

Use:

```swift
let models = try await WhisperKit.fetchAvailableModels(
    from: "argmaxinc/whisperkit-coreml",
    matching: ["*"]
)
```

Then resolve only allow-listed variants. The official repo's config recommends
models by device generation. For M2/M3/M4, the current default is an uncompressed
large-v3 variant, but a benchmark should make the choice explicit.

High-value variants include:

```text
openai_whisper-large-v3-v20240930_turbo_632MB
distil-whisper_distil-large-v3_594MB
openai_whisper-large-v3-v20240930
```

The downloaded folder contains compiled Core ML components such as mel
spectrogram, audio encoder, and text decoder. Model folder names and upstream
revision must be persisted with results.

### Performance profiles

WhisperKit can assign compute units separately to pipeline components through
`ModelComputeOptions`. Start with its supported/default configuration, then do
one controlled sweep of `.all`, `.cpuAndNeuralEngine`, and `.cpuAndGPU` where the
API/component supports them. Do not run a combinatorial sweep in every benchmark.

Other important controls:

- greedy versus beam decoding;
- prompt token prefill;
- language detection off for the English lane;
- timestamps off for primary latency;
- no previous-window conditioning for independent clips;
- no chunking or concurrency for short clips.

WhisperKit also provides an OpenAI-compatible local transcription server. It is
useful for an integration smoke test (`POST /v1/audio/transcriptions` with
file/model/language/prompt/response format), but it obscures lifecycle and timing
and should not sit between the benchmark UI and native adapter.

## Backend 3A: legacy `mlx-whisper`

### Role

This is the Whisper implementation in Apple's MLX examples. It is lightweight,
MIT licensed, and exposes nearly the same high-level options as OpenAI Whisper.
Its artifact format is the older MLX `weights.npz` plus `config.json`.

Primary sources:

- [MLX Whisper example](https://github.com/ml-explore/mlx-examples/tree/main/whisper)
- [transcribe implementation](https://raw.githubusercontent.com/ml-explore/mlx-examples/main/whisper/mlx_whisper/transcribe.py)
- [CLI implementation](https://raw.githubusercontent.com/ml-explore/mlx-examples/main/whisper/mlx_whisper/cli.py)

### Isolated install

Use Python 3.13 rather than this machine's newer default until package compatibility
is proven:

```sh
brew install ffmpeg
uv venv --python 3.13 .venv-mlx-whisper
source .venv-mlx-whisper/bin/activate
uv pip install mlx-whisper
```

FFmpeg is required for arbitrary encoded audio paths. The benchmark can avoid
some decode variance by providing canonical 16 kHz mono WAV, but keep decode time
inside UX `total`.

### Python contract

In a persistent worker:

```python
import mlx_whisper

result = mlx_whisper.transcribe(
    audio=canonical_path,
    path_or_hf_repo="mlx-community/whisper-turbo",
    verbose=None,
    language="en",
    task="transcribe",
    initial_prompt=prompt,
    condition_on_previous_text=False,
    temperature=0.0,
    beam_size=None,
    best_of=1,
    word_timestamps=False,
)
```

The result contains `text`, `segments`, and `language`. Passing `language=None`
requests detection. The implementation accepts a path or waveform array and
supports temperature fallback, beam/patience/best-of, thresholds, prompt,
segment/word timestamps, clip timestamps, and hallucination-silence handling.

The module uses a singleton `ModelHolder` which retains only the most recently
selected model. Repeated same-model calls are warm; switching model IDs reloads.
Therefore use one worker per resolved model rather than alternating models within
one process.

There is no dependable mid-kernel abort callback. A cooperative worker can check
between requests, but hard cancellation must terminate it.

The CLI:

```sh
mlx_whisper /path/canonical.wav \
  --model mlx-community/whisper-turbo \
  --output-dir /tmp/output \
  --output-name result \
  --format json
```

writes an output file rather than a clean protocol response. Use the Python API.

### Model discovery and conversion

Do not search all Hugging Face repositories at benchmark runtime. Keep an
allow-list and validate that a resolved legacy model has `config.json` and
`weights.npz`. Initial candidates:

```text
mlx-community/whisper-turbo
mlx-community/distil-whisper-large-v3
```

The example repository includes `convert.py` for converting a PyTorch Whisper
checkpoint, and its quantization option can generate a 4-bit artifact. Conversion
is preparation, not benchmarking. Record the source revision and artifact hash.

## Backend 3B: current `mlx-audio`

### Role

`mlx-audio` is a broader, actively maintained Apple MLX audio project with a
Whisper STT implementation and modern Hugging Face/Transformers-style
`safetensors` model packaging. License: MIT. It is credible as the primary MLX
adapter, but it overlaps heavily with legacy `mlx-whisper`.

Primary sources:

- [repository](https://github.com/Blaizzy/mlx-audio)
- [STT generation helper](https://raw.githubusercontent.com/Blaizzy/mlx-audio/main/mlx_audio/stt/generate.py)
- [Whisper implementation](https://raw.githubusercontent.com/Blaizzy/mlx-audio/main/mlx_audio/stt/models/whisper/whisper.py)
- [dependency metadata](https://raw.githubusercontent.com/Blaizzy/mlx-audio/main/pyproject.toml)

Install in a separate environment because its current Transformers dependency and
model format differ from legacy `mlx-whisper`:

```sh
uv venv --python 3.13 .venv-mlx-audio
source .venv-mlx-audio/bin/activate
uv pip install "mlx-audio[stt]"
```

Persistent-worker contract:

```python
from mlx_audio.stt.utils import load_model

model = load_model("mlx-community/whisper-large-v3-turbo-asr-fp16")
result = model.generate(
    canonical_path,
    language="en",
    task="transcribe",
    initial_prompt=prompt,
    return_timestamps=False,
    word_timestamps=False,
    temperature=0.0,
    condition_on_previous_text=False,
    beam_size=1,
)
```

The generic `generate_transcription` helper also accepts a loaded model. Pass the
loaded instance: passing a model string can fold model loading into each call.
The result is structured STT output. The implementation also has a streaming
generator; stopping iteration is cooperative cancellation between yielded work,
while worker termination remains the hard deadline.

The CLI (`python -m mlx_audio.stt.generate`) writes an output file and is again a
diagnostic surface, not the harness protocol.

Recommendation: implement one shared MLX-worker protocol and begin with
`mlx-audio` if its pinned release passes a two-model smoke test. Add
`mlx-whisper` only as an A/B runtime experiment. Once one is consistently
dominated on the personal short clips, remove it from the default matrix.

## Investigated but not initial backends

### `lightning-whisper-mlx`

Primary sources:

- [repository](https://github.com/mustafaaljadery/lightning-whisper-mlx)
- [wrapper](https://raw.githubusercontent.com/mustafaaljadery/lightning-whisper-mlx/main/lightning_whisper_mlx/lightning.py)
- [transcription implementation](https://raw.githubusercontent.com/mustafaaljadery/lightning-whisper-mlx/main/lightning_whisper_mlx/transcribe.py)
- [package setup](https://raw.githubusercontent.com/mustafaaljadery/lightning-whisper-mlx/main/setup.py)

Public contract:

```python
from lightning_whisper_mlx import LightningWhisperMLX

model = LightningWhisperMLX(
    model="distil-medium.en",
    batch_size=12,
    quant=None,  # or "4bit" / "8bit"
)
result = model.transcribe(audio_path, language="en")
```

Why defer:

- its main optimization batches independent 30-second windows; a 2–20 second
  utterance yields only one window, so batch size does not improve latency;
- the wrapper exposes few decode controls, no prompt/timestamp/cancellation
  contract, and downloads to a hard-coded local folder;
- its model map predates turbo and several entries share brittle nested paths;
- the source is a small fork of an older MLX Whisper implementation and contains
  brittle code paths;
- no explicit license was found in the repository or package metadata during
  this review. That is a redistribution blocker until clarified.

If curiosity warrants it later, pin the exact commit and isolate it in its own
worker. It should never be a required install.

### `faster-whisper` / CTranslate2

Primary source:
[SYSTRAN/faster-whisper](https://github.com/SYSTRAN/faster-whisper).
License: MIT.

Representative contract:

```python
from faster_whisper import WhisperModel

model = WhisperModel(
    "turbo",
    device="cpu",
    compute_type="int8",
    cpu_threads=6,
)
segments, info = model.transcribe(
    canonical_path,
    language="en",
    initial_prompt=prompt,
    beam_size=1,
    word_timestamps=False,
    vad_filter=False,
)
segments = list(segments)  # generation is lazy; materialize inside timed scope
```

CTranslate2 has no Metal/MPS device. CUDA claims and benchmarks do not apply on
this Mac. An ARM64 CPU/int8 run is a useful control and may be competitive for
small clips, but it should not expand the required matrix until the three native
Metal/Core ML/MLX paths work.

### PyTorch OpenAI Whisper, Transformers, and speculative decoding

They provide useful correctness references, but Python/PyTorch MPS startup and
memory are poor fits for a low-latency local app. Speculative decoding requires a
teacher plus assistant and currently has a documented CUDA-oriented path rather
than a native Mac engine. Keep these out of the first implementation.

CUDA-focused projects such as `insanely-fast-whisper` and FlashAttention 2 are
not Mac alternatives. Their public speed numbers should not enter this decision.

## Concrete implementation order

1. Freeze today's whisper.cpp path as `whisper_cpp/exact-baseline`.
2. Add canonical request/response, capability manifest, and explicit lifecycle.
3. Add whisper.cpp `fast`, `balanced`, and `reference` profiles; sweep threads
   once and test flash on/off.
4. Add GGML Distil large-v3. Do not yet multiply every model by every quantization.
5. Add WhisperKit using native Swift, turbo and compressed Distil variants.
6. Add the common persistent Python worker and one current MLX engine, preferably
   `mlx-audio`; add legacy `mlx-whisper` only if its install/model smoke test is
   stable.
7. Optionally add faster-whisper CPU/int8 as a control.
8. After the first twenty clips, promote only non-dominated configurations.
9. Separately test whisper.cpp's Core ML encoder build and built-in VAD trimming.
10. Keep open whisper.cpp ANE/streaming PRs and speculative decoding in an
    experimental watchlist, never in default reproducible runs.

This produces a simple UI—choose engine, model, and profile—while retaining every
backend-specific setting in an expandable expert panel and, crucially, in the
recorded resolved configuration.

## Benchmark cautions specific to personal dictation

- Preserve one canonical PCM WAV for each utterance and give it to every engine.
- Record microphone/input pipeline latency separately from inference when testing
  the full UX.
- Use the same punctuation/case normalization for WER/CER scoring, and separately
  report exact-text match and a technical-term list hit rate.
- Score raw profanity and filler words rather than censoring them; they are part
  of the requested voice/domain test.
- Prompts have different tokenizers and truncation limits. Record the actual
  encoded token count per engine.
- A short prompt can improve names and acronyms but can also induce hallucinated
  terms. Compare prompted and unprompted lanes.
- Model downloads, conversion, first Core ML specialization, and warm inference
  are distinct events. Never combine them into one headline latency.
- Peak memory matters on an 18 GB unified-memory machine. Avoid loading all
  engines simultaneously; retain only the engine under test.
- Report real-time factor alongside wall latency, but for interactive dictation
  the wall time after end-of-speech is the primary UX number.
