# Local speaker-identification experiment

Speaker labeling is experimental and is not enabled in Luxit. The measurements
below evaluate a candidate for labeling people within a recording; they do not
demonstrate acoustic separation or cancellation of computer playback entering a
microphone. The public artifact contains aggregate measurements only, with no
audio, transcript text, private recording identifiers, or local paths.

## Natural meeting check

The probe uses [FluidAudio v0.15.7](https://github.com/FluidInference/FluidAudio/tree/v0.15.7)
and the [LS-EEND 500 ms Core ML models](https://huggingface.co/FluidInference/ls-eend-coreml/tree/28ce1b1f8ef186729df63b3886fbaae7bc10c4a1),
running on the CPU of an Apple M3 Pro. Each recording uses one persistent
diarizer across half-second input blocks. Inference reads explicitly supplied
local paths; it does not upload audio or download models.

The input is the 17.5-minute ES2004a headset mix from the
[AMI corpus mirror](https://huggingface.co/datasets/FluidInference/ami-corpus-mirror/tree/722d8891643e1e4dc62cfd0d198fa05a1646c3cc),
attributed to the AMI Meeting Corpus under CC BY 4.0. Reference labels come from
the [word-based AMI test annotations](https://github.com/pyannote/AMI-diarization-setup/tree/67c2d539286e89f68952d5dcf83912bd9f01dfae/only_words).
Although the mirror places this file in an `sdm` directory, the file is named
`Mix-Headset`; these results must not be presented as distant-microphone testing.

| Variant | Speakers found / reference | Diarization error | Missed speech | False alarm | Speaker confusion | CPU processing |
|---|---:|---:|---:|---:|---:|---:|
| DIHARD III | 3 / 4 | 40.86% | 30.92% | 3.37% | 6.58% | 7.36 s |
| AMI | 4 / 4 | 17.91% | 11.88% | 3.68% | 2.34% | 6.82 s |

These are a custom 10 ms approximation of diarization error rate, using an
optimal one-to-one speaker mapping, no boundary tolerance, and overlapping
speech included. Errors are normalized by reference speaker time, which counts
simultaneous speakers separately. They are not word error rates. This single
meeting was used to compare variants and is not an independent model-selection
holdout. Broader microphone, call, and room conditions remain untested.

The AMI variant used about 114 MB peak resident memory and took 3.76 ms at the
95th percentile per half-second block. Its first finalized output appeared at
16.5 seconds of input, after an initial short utterance was missed. Accelerated
processing speed does not establish real-time responsiveness or energy use
alongside Luxit's recording, transcription, and animation.

## Word-aligned prototype

A local preview covers three minutes of the same meeting containing substantial
speech from all four participants. Luxit's local Parakeet Q8 model generated
576 words. The prototype reads real backend token timestamps and aligns words
to the speaker intervals. All four identities appear; 72 words remain
unassigned because the model provides insufficient or overlapping activity.

For each decoded chunk, extracted token text was verified against the backend's
ordinary transcript, ignoring whitespace. Chunk-boundary overlap removal is a
separate operation. This check protects against losing text while extracting
timestamps; it does not measure recognition accuracy against a reference.
The preview currently fragments sentences around uncertain words and needs a
more readable presentation before integration.

## Earlier stress checks

A 45-minute input repeating two public speech fixtures retained the expected
dominant identity in all 281 complete turns and detected two identities
throughout. CPU processing took 18.79 seconds. After bounding each input buffer's
autorelease lifetime, peak memory was about 71 MB at five minutes and remained
about 71 MB at 45 minutes. Raw prediction history was bounded to 100 seconds;
speaker intervals still grow with the recording.

Synthetic alternating voices, quieter copies, added noise, and overlapping
speech exercised the pipeline. A 20-second noise-only control produced no
speaker segments. These checks establish neither natural-meeting accuracy nor
performance on genuinely whispered speech.

## Integration requirements

Keep text delivery independent of speaker analysis. Unknown labels must not
remove words or change the audio sent to transcription. Align labels to words
or short utterances; assigning an entire 25-second chunk to one person can
misrepresent conversations. Retain diarizer state for each recording and source
across chunk boundaries, pauses, retries, and asynchronous results.

Microphone and computer are capture sources, not people. Speaker identities
from separate source models cannot be merged by index. Playback echo needs
separate evaluation with both sources, simultaneous local speech, and headphones.
Transcript deduplication is only a presentation measure, not echo cancellation.

Before enabling labels, validate additional natural conversations, improve
uncertain-word presentation, and exercise the complete recorder under load.
Model provisioning must be explicit and locally cached; failure of speaker
analysis must leave ordinary dictation and recording usable.

Pinned inputs, timing measurements, and aggregate counts are in
[`speaker-identification-aggregate.json`](speaker-identification-aggregate.json).
Models, audio, raw intervals, and the working preview remain local and ignored.
