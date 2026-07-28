# Local voice benchmark

These are aggregate results from 20 private English utterances recorded once
and decoded four times by every backend on the same MacBook Pro (Apple M3 Pro,
18 GB unified memory). The 560 canonical measurements comprise 20 cold and 60
warm runs per backend.

The public data intentionally contains no audio, transcripts, references,
keywords, recording IDs, result IDs, timestamps, local paths, or service URLs.
The reproducible aggregate is in
[`m3-pro-local-voice-aggregate.json`](m3-pro-local-voice-aggregate.json), and
[`../scripts/export_public_summary.py`](../scripts/export_public_summary.py)
regenerates it from the ignored private result store.

## Results

| Backend | Warm p50 | Warm p90 | Cold p50 | WER | CER | Keyword recall |
|---|---:|---:|---:|---:|---:|---:|
| Parakeet TDT v3 Q8 Metal | **88.9 ms** | **110.9 ms** | **346.6 ms** | **6.09%** | **3.99%** | **91.5%** |
| Parakeet TDT v3 Q8 CPU | 145.7 ms | 206.1 ms | 530.5 ms | **6.09%** | **3.99%** | **91.5%** |
| MLX Whisper large-v3-turbo 4-bit | 659.2 ms | 737.5 ms | 2000.8 ms | 8.41% | 5.74% | 82.3% |
| whisper.cpp turbo Q5 greedy | 1548.9 ms | 1726.6 ms | 1843.6 ms | 9.14% | 7.24% | 85.2% |
| whisper.cpp turbo Q5 baseline | 1599.8 ms | 1789.7 ms | 1975.4 ms | 9.38% | 7.41% | 84.9% |
| WhisperKit distil-large-v3 | 1758.8 ms | 1788.3 ms | 1878.7 ms | 12.02% | 6.44% | 77.8% |
| WhisperKit large-v3-turbo | 2040.8 ms | 2080.3 ms | 2063.0 ms | 9.53% | 7.93% | 85.2% |

Lower latency, WER, and CER are better. Higher keyword recall is better.

## Product choice

Parakeet Metal is simultaneously the fastest, tied for most accurate, and the
only backend on the measured accuracy/latency Pareto frontier. Luxit therefore
offers three useful, fully wired choices instead of exposing every experiment:

1. **Parakeet Metal** — recommended; fastest and most accurate.
2. **Parakeet CPU** — same transcript quality without Metal.
3. **whisper.cpp greedy** — the strongest wired Whisper fallback.

The models use different architectures, runtimes, quantization, and decoding
strategies. This is deliberately a product-choice comparison on one person's
real dictation workload, not an architecture-controlled model study.
