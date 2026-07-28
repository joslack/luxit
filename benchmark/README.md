# Voiceprint local STT benchmark

Voiceprint records each phrase once and sends the exact same 16 kHz mono PCM
WAV to every selected speech-to-text backend. It keeps model-specific
performance paths behind one manifest-driven boundary without pretending that
all engines have the same capabilities.

## Start the lab

From the repository root:

```sh
./scripts/start-benchmark-lab.sh
```

Then open <http://localhost:3000>. The API binds only to
`127.0.0.1:8765`; audio, transcripts, corrections, and ratings stay under
`benchmark/data`.

The page contains:

- a 20-phrase personal corpus with technical names, commands, numbers,
  disfluency, and ordinary work language;
- record-once / decode-many controls;
- only-ready and model-family filters;
- explicit cold and warm measurements;
- WER, normalized CER, keyword recall, end-to-end latency, and real-time speed;
- manual **Useful**, **Needs edit**, and **Wrong** ratings with correction text;
- a whole-corpus leaderboard and JSON/CSV export;
- a corpus importer accepting exactly 20 JSON cases or 20 non-empty lines.

Corpus replacement writes a timestamped backup and does not remove recordings.

## What is runnable on this Mac

The registry contains profiles for 26+ public model/runtime combinations. A
profile is shown as ready only when its executable, Python module, and exact
model artifact are present. The current prepared set includes:

- persistent whisper.cpp, using the existing Luxit
  `large-v3-turbo-q5_0` artifact, in exact beam-5 and greedy-1 profiles;
- WhisperKit/Core ML turbo and compressed Distil-Whisper;
- persistent MLX-Audio Whisper large-v3-turbo 4-bit;
- persistent libparakeet TDT v3 Q8 on CPU/BLAS and Metal.

Additional manifests cover FluidAudio Parakeet and Nemotron, Moonshine,
sherpa-onnx Zipformer, Qwen3-ASR MLX and pure C, Canary, Granite, Voxtral,
SenseVoice, and Cohere Core ML. Their cards say exactly which runtime or model
is missing instead of failing during a benchmark.

Model files are ignored by Git. Existing Luxit models are discovered under:

```text
~/Library/Application Support/EdgeWhisper/Models
~/Library/Application Support/Luxit/Models
benchmark/models
```

Add more locations with the colon-separated
`STTBENCH_MODEL_SEARCH_PATHS` environment variable.

## Benchmark semantics

For each backend and recording, the runner:

1. creates a fresh adapter;
2. records one cold result, including model/runtime startup;
3. performs the configured unrecorded warmups;
4. records the requested warm repetitions;
5. closes the adapter before loading the next backend.

Inference is sequential. This avoids comparing one model while another occupies
unified memory or competes for GPU/ANE bandwidth. Persistent backends keep their
model loaded within steps 2–4. Command backends still benefit from system/Core
ML caches, but each invocation is process-cold; the backend card exposes that
lifecycle.

The default accuracy lane fixes English, disables timestamps, avoids batching,
uses no cross-utterance context, and sends a vocabulary prompt only to backends
that advertise prompt support. Streaming, VAD, diarization, word timestamps,
and hotword-biased decoding are separate capabilities and should not be mixed
into the baseline.

## Prepared ground-truth smoke set

Five small CC BY 4.0 LibriSpeech clips are prepared by:

```sh
python3 benchmark/scripts/fetch_reference_corpus.py
```

Run selected profiles:

```sh
PYTHONPATH=benchmark benchmark/.venv/bin/python \
  benchmark/scripts/run_reference_suite.py \
  --backend transducer-libparakeet-cli-v3-q8-0 \
  --backend mlx-whisper-turbo-4bit
```

With no `--backend` arguments, the script runs every ready profile.

## Generic backend contract

Each `benchmark/backends/*.json` manifest declares identity, model artifact,
runtime command, setup requirements, options, and capabilities. There are two
adapter protocols:

- `command`: render one command for one transcription;
- `jsonl-worker`: keep a process/model resident and exchange one JSON object per
  line.

The worker protocol is:

```json
{"type":"load","backend_id":"example","model":"model-id","model_path":"/absolute/path","options":{}}
{"type":"transcribe","audio_path":"/absolute/input.wav","language":"en","prompt":null,"word_timestamps":false,"options":{}}
{"type":"shutdown"}
```

A transcription response may include:

```json
{
  "text": "recognized speech",
  "backend_ms": 182.4,
  "load_ms": 310.0,
  "preprocess_ms": 2.0,
  "decode_ms": 160.0,
  "segments": [],
  "words": [],
  "metadata": {}
}
```

The harness owns wall-clock timing, WAV duration, scoring, lifecycle labels,
result persistence, and manual ratings. A backend owns model loading and
inference-specific timing. Unsupported features must be declared and rejected,
not silently approximated.

To add a backend:

1. copy the closest manifest;
2. implement either a clean command or the JSONL protocol;
3. list every required command, path, and Python module;
4. declare prompt, language, timestamp, streaming, and persistence capabilities
   honestly;
5. add a contract test and run the same reference WAV through it.

## Files and API

```text
benchmark/backends/          declarative profiles
benchmark/workers/           runtime-specific adapters
benchmark/corpus/            neutral public 20-case smoke-test set
benchmark/data/personal-20.json local personalized corpus, created on first edit
benchmark/data/recordings/   local WAV takes and metadata
benchmark/data/results.jsonl append-only measured results
benchmark/data/ratings.jsonl append-only manual judgments
benchmark/sttbench/          generic registry, adapters, runner, API, metrics
benchmark-ui/                local Next.js interface
research/                    per-family implementation and model-space reports
benchmark/results/           privacy-safe aggregate benchmark report
```

Primary API routes:

```text
GET  /api/backends
GET  /api/corpus
POST /api/corpus
POST /api/recordings?case_id=...
POST /api/jobs
GET  /api/jobs/:id
GET  /api/results?recording_id=...&backend_id=...
GET  /api/ratings
POST /api/ratings
GET  /api/summary
GET  /api/export?format=json|csv
```

Run validation:

```sh
PYTHONPATH=benchmark benchmark/.venv/bin/python -m unittest discover -s benchmark/tests -v
npm --prefix benchmark-ui run build
```
