# Frontier and non-Whisper ASR families on Apple Silicon

Research date: 2026-07-28  
Target machine: Apple Silicon MacBook Pro, M3 Pro, 18 GB unified memory  
Scope: public/open-weight ASR that can plausibly participate in a local, repeatable benchmark harness. Public cloud APIs are out of scope.

## Executive recommendation

The clean boundary should be a **capability-aware, long-lived transcription session**, not a single lowest-common-denominator command line. Model loading, warmup, transcription, and unloading must be separate operations. Options unsupported by a backend should produce explicit capability errors rather than being silently ignored.

For this Mac, the first implementation wave should be:

1. **Qwen3-ASR 0.6B and 1.7B, MLX quantized**, using `mlx-qwen3-asr`. This is the strongest general-purpose Apple-Silicon candidate in this group and supports vocabulary context, streaming, and optional alignment.
2. **SenseVoice Small, Core ML int8**, using FluidAudio. It is a useful non-autoregressive speed extreme and is tiny enough to keep benchmark iteration pleasant.
3. **IBM Granite 4.0 1B Speech, MLX 8-bit**, using MLX-Audio. It adds a modern multilingual quality comparator without a large memory burden.
4. **Voxtral Mini 4B Realtime, MLX 4-bit**, using MLX-Audio. Benchmark both final transcript and live UX, especially time-to-first-text and rewrite behavior.
5. **Cohere Transcribe 03-2026**, initially through either MLXAudio Swift or FluidAudio Core ML. It is a quality-oriented 2B model, but gated downloads and limited features make it less convenient.
6. **Canary 1B v2, MLX q8**, using MLX-Audio. This is useful for multilingual ASR and translation, though its best timestamp implementation remains tied to NVIDIA NeMo.

Second-wave comparators should include the pure-C Qwen implementation, GLM-ASR Nano 4-bit, MOSS Transcribe-Diarize 0.9B MLX int8, and a common sherpa-onnx adapter. The pure-C Voxtral implementation is interesting but consumes roughly 10 GB at runtime and is not the default I would choose on an 18 GB machine.

Two projects are especially useful as broad integration layers:

- [MLXAudio Swift](https://github.com/Blaizzy/mlx-audio-swift) is a native Swift package covering Qwen3-ASR, Voxtral Realtime, Cohere Transcribe, Canary, Granite, GLM-ASR, SenseVoice, MOSS, Nemotron, Parakeet, Whisper, and others. It is an unusually promising route to a native UI and shared model cache, although the project is fast-moving and model-specific APIs are not yet perfectly uniform.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) provides a stable C/C++ offline recognizer boundary and prebuilt macOS support for SenseVoice, Cohere, Qwen3-ASR, smaller Canary conversions, FunASR Nano, Omnilingual ASR, and other families. It is ideal as a coverage/fallback adapter, but its mostly CPU ONNX path can hide the performance advantage of a model's best native Apple backend.

## Proposed adapter contract

The public harness should normalize requests and results while leaving backend-specific performance controls available under a typed extension block.

```text
TranscriptionRequest
  audio: canonical mono Float32 PCM plus sampleRate
  languageHint?: BCP-47-ish string
  vocabularyHints: [String]
  mode: offline | streaming
  timestamps: none | segment | word
  punctuation?: Bool
  inverseTextNormalization?: Bool
  decoding:
    temperature?: Float
    maxTokens?: Int
    beamSize?: Int
    chunkMs?: Int
    delayMs?: Int
  backendOptions: typed per-adapter options

TranscriptionResult
  text: String
  detectedLanguage?: String
  segments?: [{start, end, text, words?, speaker?, events?}]
  partialEvents?: [{atMs, text, isStable}]
  timings:
    loadMs
    warmupMs
    preprocessingMs
    encodeMs?
    decodeMs?
    totalMs
    timeToFirstPartialMs?
    finalizationMs?
  realTimeFactor
  peakResidentBytes?
  modelMetadata
  warnings
```

Each adapter should also implement:

```text
descriptor() -> model, runtime, precision, license, approximate disk/RAM
capabilities() -> language detection, language hints, prompts/hotwords,
                  timestamps, streaming, translation, diarization, events
prepare() -> resolve local files, construct runtime, compile/load model
warmup() -> perform one unscored representative inference
transcribe(request) -> result
resetStream()
unload()
```

A backend must reject, for example, `word timestamps` on Cohere or `vocabularyHints` on Voxtral. This makes feature comparisons honest and avoids the confusing situation where the UI appears to enable a feature that a model ignores.

For Python/MLX backends, use a persistent JSONL worker process rather than one subprocess per utterance. For Swift/Core ML and Swift/MLX backends, keep the model manager alive in the application process. A generic one-shot executable is acceptable only as a diagnostic path.

## Capability overview

| Family / preferred Mac runtime | Mac feasibility | Language handling | Context / hotwords | Timestamps | Streaming | Notable outputs |
|---|---:|---|---|---|---|---|
| Qwen3-ASR 0.6B/1.7B, MLX | Excellent | 30 languages, 22 Chinese dialects; auto detection or hint | Yes, context vocabulary | Yes, with separate 0.6B aligner | Yes | Text, language, optional aligned chunks |
| SenseVoice Small, Core ML int8 | Excellent | Released checkpoint: zh/en/yue/ja/ko; auto detection | No | No | Not natively; external chunk/VAD | Language, emotion, acoustic-event tags, ITN |
| Granite 4.0 1B Speech, MLX 8-bit | Very good | EN/FR/DE/ES/PT/JA ASR; translation modes | Task instruction, not a verified hotword mechanism | No verified MLX support | Token streaming, not purpose-built causal ASR | Text and translation |
| Voxtral Mini 4B Realtime, MLX 4-bit | Good | 13 languages; no explicit hint in documented realtime API | No documented hotwords | No canonical word timestamps | Native causal streaming | Low-latency partial text |
| Cohere Transcribe 03-2026, MLX/Core ML | Good | 14 languages; explicit one-language selection | No | No | No native streaming | Optional punctuation and ITN |
| Canary 1B v2, MLX q8 | Good | 25 European languages; explicit source/target | Constrained task tokens only | Official NeMo supports word timestamps; MLX port not verified | No verified native MLX streaming | ASR, punctuation, translation |
| GLM-ASR Nano, MLX 4-bit | Very good | Mandarin, English, Cantonese and Chinese dialect focus | Chat-template task prompt; vocabulary bias unverified | No | No | Text |
| MOSS Transcribe-Diarize 0.9B, MLX int8 | Promising, very new | 50+ languages claimed | Yes, instructions and hotwords | Yes | Long-form rather than low-latency streaming | Speakers, timestamps, acoustic events |
| Qwen3-ASR, pure C/Accelerate | Good | Same base model; language flag | Yes, soft prompt | No integrated aligner | Chunked live mode | Plain text |
| Voxtral Realtime, pure C/MPS | Feasible but memory-heavy | Same 13 languages | No documented hotwords | No | Yes | Plain/partial text |
| sherpa-onnx family adapters | Excellent compatibility | Model-dependent | Model-dependent | Model-dependent | Separate online API; models here mostly offline | Stable C structs/results |

## Family details

### 1. Qwen3-ASR

Primary sources:

- [Official Qwen3-ASR repository](https://github.com/QwenLM/Qwen3-ASR)
- [Qwen3-ASR 0.6B model](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)
- [Qwen3-ASR 1.7B model](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)
- [Qwen3 Forced Aligner 0.6B](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B)
- [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr)
- [Pure-C qwen-asr](https://github.com/antirez/qwen-asr)
- [Fluid Core ML conversion](https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml)

The official models are Apache-2.0 and cover 30 languages plus 22 Chinese dialects. The same architecture supports language identification, offline transcription, and streaming. The official Python package accepts a path, URL, base64 audio, or `(numpyArray, sampleRate)`. It can infer the language or receive an explicit language:

```python
from qwen_asr import Qwen3ASRModel

model = Qwen3ASRModel.from_pretrained(
    "Qwen/Qwen3-ASR-0.6B",
    dtype=torch.bfloat16,
    device_map="cuda:0",
    max_inference_batch_size=32,
    max_new_tokens=256,
)
results = model.transcribe(audio="sample.wav", language="English")
```

Official timestamps require loading the separate forced-aligner model and requesting timestamps. The aligner currently covers 11 languages and audio up to five minutes. The official streaming server uses vLLM and is CUDA-oriented, so neither official execution path is the performance path for this Mac.

#### Preferred adapter: `mlx-qwen3-asr`

The dedicated MLX implementation has the best documented Apple-Silicon feature coverage:

```python
from mlx_qwen3_asr import Session

session = Session(model="Qwen/Qwen3-ASR-0.6B")
result = session.transcribe(
    "sample.wav",
    language="English",
    context="EBITDA non-GAAP FX hedging",
)
```

It exposes explicit model/session loading, transcription, an OpenAI-compatible local server, quantized models, an MLX forced aligner, and stateful streaming with `init_streaming`, `feed_audio`, and `finish_streaming`. Default streaming chunks are two seconds, with bounded context/KV reuse and optional energy-based endpointing. This is a good match for measuring partial stability and finalization delay as well as WER.

The project's published approximate fp16 weight sizes are 1.2 GB for 0.6B and 3.4 GB for 1.7B. Its published 8-bit and 4-bit results show large speed gains with small-to-moderate WER changes, but these must be remeasured on the target M3 Pro and the user's voice. Start with 8-bit for both sizes; add 4-bit for the 0.6B only if the speed difference is material.

Important benchmark profiles:

- 0.6B 8-bit, no context
- 0.6B 8-bit, per-utterance vocabulary context
- 1.7B 8-bit, no context
- 1.7B 8-bit, per-utterance vocabulary context
- streaming at 500 ms, 1 s, and 2 s feed intervals, while keeping the model's internal settings constant

Do not mix prompted and unprompted accuracy in one leaderboard. Context vocabulary is a product feature and deserves a separate condition.

#### Runtime comparator: pure C/Accelerate

Antirez's [qwen-asr](https://github.com/antirez/qwen-asr) uses C plus Accelerate BLAS, memory-maps BF16 safetensors, and deliberately does not use MPS. It supports `--language`, `--prompt`, `--stdin`, `--stream`, silence skipping, fixed-size segmentation, and carrying past text between segments. That makes it a valuable “simple CPU implementation” comparator:

```sh
make blas
./qwen_asr -d qwen3-asr-0.6b -i sample.wav
```

Its M3 Max results are not predictions for an M3 Pro, but they demonstrate feasibility: approximately 1.83 seconds for an 11-second clip with 0.6B and 3.17 seconds with 1.7B. Reported peak RSS is roughly 2.7–3.25 GiB and 6.57–7.29 GiB respectively. The adapter will need to parse stdout/stderr or add a small structured-output wrapper. It lacks the integrated timestamp aligner.

#### Low-priority path: Core ML

Fluid's Core ML 0.6B conversion offers f32 and int8 variants and a Swift manager:

```swift
let manager = Qwen3AsrManager()
try await manager.loadModels()
let transcript = try await manager.transcribe(
    audioSamples: samples,
    language: "en",
    maxNewTokens: 512
)
```

The published M4 Pro result is only about 2.8x realtime and its reported LibriSpeech test-clean WER is materially worse than the source model. It is useful for investigating ANE behavior, but should not displace MLX in the first benchmark.

### 2. Cohere Transcribe 03-2026

Primary sources:

- [Official Cohere Transcribe 03-2026 model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)
- [Fluid Core ML conversion](https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml)
- [FluidAudio model documentation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)
- [sherpa-onnx Cohere documentation](https://k2-fsa.github.io/sherpa/onnx/cohere_transcribe/pretrained.html)

This is an Apache-2.0, gated Hugging Face download. The user must accept Cohere's access form and share contact details before the official weights can be resolved. Architecturally it is a 2B Conformer encoder with a lightweight eight-layer decoder.

It supports 14 languages: English, French, German, Italian, Spanish, Portuguese, Greek, Dutch, Polish, Arabic, Vietnamese, Chinese, Japanese, and Korean. Language selection is explicit; there is no language autodetection, and the card warns that code-switching can be inconsistent. It has punctuation and inverse-text-normalization controls, but no timestamps, diarization, prompt/hotword interface, or native streaming. It is eager on silence/noise, so use VAD outside the model.

Official Transformers usage is:

```python
processor = AutoProcessor.from_pretrained(model_id)
model = CohereAsrForConditionalGeneration.from_pretrained(
    model_id, device_map="auto"
)
inputs = processor(
    audio,
    sampling_rate=16000,
    language="en",
    punctuation=True,
)
outputs = model.generate(**inputs, max_new_tokens=256)
```

The processor divides audio longer than 35 seconds into clips and reassembles by `audio_chunk_index`. The official vLLM OpenAI-compatible endpoint is CUDA-oriented and should not be the Mac adapter.

#### Mac paths

Fluid's Core ML hybrid q8 package is roughly 2.1 GB of active models: an int8 encoder around 1.8 GB and an fp16 decoder around 291 MB. It requires macOS 14 or later, uses an external KV cache, and keeps the 35-second per-call limit. Its Swift pipeline is approximately:

```swift
let loaded = try CohereFixedPipeline.loadModels(
    encoderURL: encoderURL,
    decoderURL: decoderURL,
    vocabDir: vocabDir
)
let pipeline = try CohereFixedPipeline(models: loaded)
let result = try pipeline.transcribe(audio: samples, models: loaded)
```

Keep `loaded` and `pipeline` alive. Also preserve the conversion's EOS-token handling; this model uses token 3.

MLXAudio Swift supports `beshkenadze/cohere-transcribe-03-2026-mlx-fp16`, making it attractive if the harness already embeds the Swift package for other families. It is newer and less independently documented than the Fluid path, so the first adapter should allow swapping between these two runtimes behind the same Cohere capability descriptor.

sherpa-onnx provides an int8 package and explicit `language`, `use_punct`, and `use_itn` fields through its common offline recognizer. This is the easiest fallback if native integration is blocked, but not the presumed performance winner.

### 3. Voxtral

Primary sources:

- [Voxtral Mini 4B Realtime 2602](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)
- [MLX-Audio](https://github.com/Blaizzy/mlx-audio)
- [MLX 4-bit conversion](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit)
- [voxmlx](https://github.com/awni/voxmlx)
- [voxtral.c](https://github.com/antirez/voxtral.c)
- [Experimental ExecuTorch conversion](https://huggingface.co/mistral-experimental/Voxtral-Mini-4B-Realtime-2602-ExecuTorch)

The Apache-2.0 realtime model supports English, Spanish, French, Portuguese, Hindi, German, Dutch, Italian, Arabic, Russian, Chinese, Japanese, and Korean. It is a native causal stream with a sliding window rather than an offline model repeatedly invoked on overlapping chunks. The transcription delay is configurable in 80 ms multiples; Mistral recommends 480 ms. Temperature should remain zero.

The official vLLM realtime API expects CUDA with roughly 16 GB GPU memory. Transformers can perform one-shot generation, but MPS is not the optimized path. The experimental ExecuTorch/Metal conversion is explicitly marked sharp-edged and requires a source build, so it is not an initial harness dependency.

#### Preferred adapter: MLX-Audio 4-bit

The MLX model is about 3.13 GB:

```python
from mlx_audio.stt.utils import load

model = load("mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit")
result = model.generate(
    "sample.wav",
    transcription_delay_ms=480,
)

for partial in model.generate(
    "sample.wav",
    transcription_delay_ms=480,
    stream=True,
):
    ...
```

Expose delay profiles of 240, 480, and 960 ms. Score final correctness separately from time-to-first-text, partial rewrite rate, and finalization time. Do not advertise language hints, vocabulary hints, diarization, or word timestamps for this adapter unless a later runtime version documents them.

`voxmlx` is a compact dedicated implementation whose default is a 6-bit MLX conversion, but it has a very small commit history. Prefer the broader MLX-Audio runtime initially.

#### Optional pure-C/MPS comparator

`voxtral.c` provides both a one-shot C API and a `vox_stream_t` streaming API:

```c
char *text = vox_transcribe(ctx, "sample.wav");
```

It memory-maps BF16 weights and uses MPS for the neural network. The CLI supports file, stdin, microphone, and configurable processing intervals; one to two seconds is the documented practical interval. Its reported M3 Max working set is roughly 8.4 GB of cached MPS weights plus up to 1.8 GB KV cache and other allocations, approximately 10.4 GB total. This fits in 18 GB but leaves little headroom and can create memory-pressure artifacts. Run it only in an otherwise quiet, isolated benchmark process and unload it before another large model.

The older [Voxtral Mini 3B 2507](https://huggingface.co/mistralai/Voxtral-Mini-3B-2507) is an offline/audio-understanding model whose BF16 conversion is around 9.4 GB. It is heavier, older, and less appropriate for a dictation-latency sweep, so omit it from the initial matrix.

### 4. SenseVoice / FunASR

Primary sources:

- [Official SenseVoice repository](https://github.com/QwenAudio/SenseVoice)
- [SenseVoice Small model card](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)
- [Fluid SenseVoice Core ML conversion](https://huggingface.co/FluidInference/sensevoice-small-coreml)
- [sherpa-onnx SenseVoice documentation](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html)

SenseVoice Small is a roughly 234M-parameter, non-autoregressive SANM/CTC model. In addition to transcription it returns language, emotion, and acoustic-event tags. It has inverse-text-normalization control but no native timestamp or vocabulary-prompt mechanism.

The released checkpoint supports Chinese, English, Cantonese, Japanese, and Korean plus no-speech. The paper/repository has historically discussed 50+ languages, but the repository now clarifies that the public checkpoint itself is five-language. The harness should display the checkpoint capability, not the broader research claim.

Official FunASR usage is:

```python
model = AutoModel(
    model="FunAudioLLM/SenseVoiceSmall",
    vad_model="fsmn-vad",
    vad_kwargs={"max_single_segment_time": 30000},
    device=device,
)
result = model.generate(
    input="sample.wav",
    language="auto",
    use_itn=True,
    batch_size_s=60,
    merge_vad=True,
    merge_length_s=15,
)
```

Direct chunks are limited to roughly 30 seconds; the recommended long-form path wraps them with FSMN VAD.

#### Preferred adapter: Fluid Core ML int8

Fluid's int8 model is roughly 225 MB, with a reported peak working set around 0.32 GB. It is a single CTC forward pass and is exceptionally fast in Fluid's published M-series tests. Use those numbers only to justify inclusion, not as target-machine results.

Use the CPU-and-Neural-Engine compute policy. The fp16 conversion can produce NaNs when Core ML selects CPU/GPU execution; Fluid recommends `.cpuAndNeuralEngine`, with fp32 as fallback. The adapter should expose:

- language: `auto`, `zh`, `en`, `yue`, `ja`, `ko`
- `useITN`
- decoded language/emotion/event metadata

The external harness should own VAD/chunking for long audio.

Fallbacks include the sherpa-onnx int8 recognizer and the official repository's llama.cpp/GGUF runtime with FSMN VAD. sherpa is the cleaner common C boundary; the GGUF executable is attractive for an all-in-one, dependency-light diagnostic.

The official code repository is MIT, while the Hugging Face weight card uses a custom model-license label. Review the upstream weight terms before redistributing model files in a packaged application.

### 5. Canary

Primary sources:

- [NVIDIA Canary 1B v2](https://huggingface.co/nvidia/canary-1b-v2)
- [NVIDIA Canary 1B Flash](https://huggingface.co/nvidia/canary-1b-flash)
- [NVIDIA NeMo Canary streaming/chunked decoding documentation](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/streaming_decoding/canary_chunked_and_streaming_decoding.html)
- [MLX-Audio Canary documentation](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/canary/README.md)

Canary 1B v2 supports 25 European languages, punctuation/capitalization, ASR, and speech translation. The official NeMo implementation also exposes improved word timestamps:

```python
model = ASRModel.from_pretrained("nvidia/canary-1b-v2")
output = model.transcribe(["sample.wav"])
words = output[0].timestamp["word"]
```

Its prompt fields are constrained task tokens—source language, target language, ASR versus translation, punctuation, and timestamps—not arbitrary text vocabulary hints. NeMo remains CUDA-first and is a poor performance dependency for this Mac.

The practical Mac path is the q8 MLX conversion:

```python
from mlx_audio.stt.utils import load

model = load("Mediform/canary-1b-v2-mlx-q8")
result = model.generate(
    "sample.wav",
    source_lang="en",
    target_lang="en",
)
```

The MLX port handles both NeMo and MLX model layouts and supports source/target language tasks. Its timestamp and true streaming support are not documented, so advertise neither until verified with the exact installed release.

sherpa-onnx's Canary conversion is a smaller 180M Flash model covering English, Spanish, German, and French. It is useful as a lightweight separate model, but must not be labeled as Canary 1B v2.

Canary weights use CC-BY-4.0; attribution must be retained.

## Other models worth including

### IBM Granite 4.0 1B Speech

Sources:

- [Official model](https://huggingface.co/ibm-granite/granite-4.0-1b-speech)
- [MLX 8-bit conversion](https://huggingface.co/mlx-community/granite-4.0-1b-speech-8bit)

Apache-2.0. It supports English, French, German, Spanish, Portuguese, and Japanese ASR plus several translation directions. MLX-Audio supports its 8-bit conversion and a task prompt:

```python
model = load("mlx-community/granite-4.0-1b-speech-8bit")
result = model.generate(
    "sample.wav",
    prompt="Transcribe the speech to text.",
)
```

Its prompt is a task instruction, not a verified vocabulary-bias mechanism. No word timestamps are documented in the MLX result. This is a high-priority quality comparator because 1B at 8-bit is a comfortable size for an 18 GB Mac.

### GLM-ASR Nano 2512

Sources:

- [Transformers GLM-ASR documentation](https://huggingface.co/docs/transformers/model_doc/glmasr)
- [MLX 4-bit conversion](https://huggingface.co/mlx-community/GLM-ASR-Nano-2512-4bit)

MIT-licensed. The model is oriented toward Mandarin, English, Cantonese, and Chinese dialects, with particular claims around low-volume speech. The MLX 4-bit package is about 1.28 GB and is supported by MLX-Audio and MLXAudio Swift. It is an inexpensive second-wave test for quiet speech, accents, and technical dictation. Do not claim timestamps, streaming, or hotword bias without runtime-specific verification.

### MOSS Transcribe-Diarize 0.9B

Sources:

- [Official model](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize)
- [MLX int8 conversion and validation bundle](https://huggingface.co/aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8)
- [OpenASR runtime](https://github.com/QuintinShaw/openasr)

This Apache-2.0 model was released in July 2026 and is unusually feature-rich: claimed 50+ languages, long-form audio up to 90 minutes, timestamps, speakers, acoustic events, and instruction/hotword input in one pass. MLX-Audio and MLXAudio Swift added support in late July.

The third-party MLX validation bundle reports approximately 1.2–1.4 GB RSS for int5/int8, but validation is still limited and the model/runtime combination is very new. Include it in a distinct “enriched transcript” benchmark rather than ranking its additional diarization work directly against plain-text-only models. It may ultimately be the most useful meeting-transcription backend in this set.

OpenASR and CrispASR/GGUF provide alternative native runtimes, but current published Apple results are far behind the MLX conversion for short-form latency.

### Nemotron 3.5 ASR Streaming 0.6B

[The MLX conversion](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b) supports approximately 40 locales and configurable attention context. MLX-Audio exposes `language` and `att_context_size`, making this a strong live-UX candidate if it is not already covered by a separate NVIDIA/streaming-model adapter. FluidAudio also has a Core ML implementation. It belongs in the first or second wave for streaming, but should not be duplicated under both the frontier and NVIDIA adapter families.

### Coverage-only models

- Meta Omnilingual ASR is compelling for rare-language coverage, and sherpa-onnx has a relatively small int8 CTC conversion. It is not an initial English technical-dictation speed/quality candidate.
- FunASR Nano is Qwen3-ASR-derived and useful for Chinese/hotword use cases, but is redundant with Qwen3-ASR and SenseVoice for the initial personal English benchmark.
- VibeVoice ASR 9B and older Voxtral/audio-language models are too memory-heavy or task-misaligned for the first pass on an 18 GB laptop.

## Lifecycle and benchmark methodology

### Cold and warm are different products

Measure the following independently:

1. **Availability time**: model download and conversion. Record it operationally, but exclude it from transcription latency.
2. **Cold load**: process start through a ready model/session.
3. **Warmup**: one representative inference, not scored.
4. **Warm inference**: three to five repetitions per utterance, randomized across utterances and model profiles.
5. **Unload**: release the backend process/session and observe resident memory recovery.

Core ML may compile/load a model on first use and cache the compiled artifact later. MLX uses lazy execution and compiles Metal kernels on first evaluation. Memory-mapped C implementations can report an impressively short “load” while paying page faults during first inference; Voxtral's MPS path also has a substantial first-use weight cache. Report all three separately: context construction, first inference, and steady-state inference.

Do not keep every model resident simultaneously on 18 GB. Run adapters sequentially, and give the app an explicit active-backend policy. In particular, the BF16 pure-C/MPS Voxtral path can occupy roughly 10 GB, while Qwen 1.7B and Cohere also need multiple gigabytes.

### Audio and timing

Capture each test utterance once as lossless audio and retain the original. Produce a canonical mono Float32 16 kHz PCM buffer outside the backend where supported. Time resampling separately so a model does not win merely because its adapter omits input conversion. If a model's official preprocessor requires original-rate audio, feed the original but record preprocessing cost.

At minimum record:

- model/session load time
- first inference latency
- steady-state end-to-end latency
- preprocessing, encoder, and decoder time where available
- real-time factor
- peak RSS or process physical footprint
- for streaming: time to first partial, finalization delay, partial rewrite count, and stable-prefix growth

Use a quiet machine, disconnect large models between runs, randomize model order, and record macOS version, chip, power mode, thermal state, runtime commit/version, model revision, precision, and every decoding parameter.

### Accuracy

Maintain two accuracy views:

- normalized WER/CER for ordinary comparability
- strict, case/punctuation-aware correctness for technical terms, proper names, acronyms, numbers, file paths, shell syntax, and the user's idiosyncratic phrases

Also record exact-hit rates for the intentionally difficult terms in each prompt. Prompted/hotword-enabled and unprompted results are separate benchmark conditions. Models with diarization/events should receive an enrichment score, not an unfair text-latency penalty in the main leaderboard.

## Adapter implementation order

### P0: core useful matrix

1. Define the capability-aware request/result/session protocol and benchmark lifecycle.
2. Implement `QwenMLXAdapter` around a persistent `mlx-qwen3-asr` worker. Discover 0.6B/1.7B and quantization as profiles, not separate code.
3. Implement `SenseVoiceCoreMLAdapter` with FluidAudio int8 and expose language/emotion/event metadata.
4. Implement `MLXAudioAdapter` with model-family strategy objects, beginning with Granite 4.0 1B 8-bit.

### P1: quality and live UX

5. Add Voxtral Realtime 4-bit to `MLXAudioAdapter`, with partial-event telemetry and several delay profiles.
6. Add Canary 1B v2 q8 to `MLXAudioAdapter`.
7. Implement `CohereAdapter`, preferring MLXAudio Swift if the native package is already linked; otherwise use Fluid Core ML q8. Treat the gated-model agreement as a resolvable availability state.
8. Add the Qwen forced aligner as a separately loaded optional capability so users who only need text do not pay its load/memory cost.

### P2: architecture/runtime comparisons

9. Implement a generic executable/JSONL wrapper for pure-C Qwen and compare 0.6B/1.7B BF16 Accelerate with MLX.
10. Add GLM-ASR Nano 4-bit and MOSS 0.9B int8 strategies to `MLXAudioAdapter`.
11. Implement `SherpaOfflineAdapter` once, then expose exact converted checkpoints as profiles: SenseVoice int8, Cohere int8, Qwen3 0.6B int8, and Canary 180M Flash. Never imply these are identical to larger source checkpoints.
12. Add `VoxtralCAdapter` only when pure-C/MPS comparison is specifically desired and memory pressure can be isolated.

### Do not prioritize

- official CUDA/vLLM or NeMo runtimes on macOS
- PyTorch MPS merely because it can execute
- Qwen Core ML before the MLX implementation
- experimental ExecuTorch Voxtral
- older 9+ GB Voxtral/audio-understanding checkpoints
- one-process-per-utterance CLI wrappers as the main benchmark path

## Dependency and licensing summary

| Component | Main dependency | Model/license note |
|---|---|---|
| Qwen3-ASR MLX | Python, MLX, NumPy, Hugging Face Hub; ffmpeg for non-WAV | Qwen weights Apache-2.0; check runtime package license at pin |
| Qwen pure C | C compiler, Accelerate | Runtime MIT; weights Apache-2.0 |
| SenseVoice Core ML | Swift, FluidAudio/Core ML, macOS 14+ | Code MIT; weight card uses custom upstream model license |
| Granite MLX | Python or Swift MLX-Audio | Apache-2.0 |
| Voxtral MLX | Python or Swift MLX-Audio | Weights Apache-2.0 |
| voxtral.c | C compiler, MPS/Metal | Runtime MIT; weights Apache-2.0 |
| Cohere | MLXAudio Swift, FluidAudio, or sherpa-onnx | Apache-2.0 but gated access/contact agreement |
| Canary | MLX-Audio | CC-BY-4.0 attribution |
| GLM-ASR | MLX-Audio | MIT |
| MOSS | MLX-Audio, newly added support | Apache-2.0 |
| sherpa-onnx | C/C++ library or prebuilt package | Apache-2.0 runtime; each model retains its own license |

Pin both runtime commit/version and Hugging Face model revision in every benchmark record. “Same model name” is insufficient when conversions and generation code are changing rapidly.

## Bottom line

There are credible non-Whisper options that should be much more interesting than simply running another Whisper wrapper. Qwen3-ASR MLX is the most complete general-purpose candidate; SenseVoice Core ML is the speed-oriented architectural contrast; Granite and Cohere are quality comparators; Voxtral and Nemotron are the live-streaming UX candidates; Canary adds multilingual translation; and MOSS adds a new enriched-transcript category.

The reusable engineering investment is not a universal inference engine. It is a small, explicit session protocol plus a few high-quality runtime adapters that preserve each family's real performance path on Apple Silicon.
