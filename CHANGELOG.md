# Changelog

## 0.13.1 — 2026-09-17

- Provide a portable, checksum-verified speaker dependency package for Macs
  unable to download the speaker model or runtime during installation.
- Document offline speaker setup. The package also works with v0.13.0;
  recording, transcription, and correction behavior is unchanged.

## 0.13.0 — 2026-09-17

- Estimate individual speakers in Parakeet recordings with a local, CPU-only
  model. Preserve speaker state across chunks and recover pending analysis
  after a restart. Labels are estimates within each recording and audio source.
- Keep long, growing transcripts responsive, preserve words when speaker
  attribution is uncertain, and reduce repeated playback text in the display.
- Show conversation recording with a static menu-bar indicator. Keep the
  listening cloud for Caps Lock dictation and dismiss the panel on outside clicks.
- Support selecting and copying transcript text with keyboard shortcuts, and
  clear the Copy button's confirmation after a short delay.
- Add local post-transcription corrections for dictation and recordings, with
  an editable Settings list, grouped regex patterns, captured replacements,
  and a reloadable JSON file. See the [corrections guide](docs/corrections.md).

## 0.12.0 — 2026-09-16

- Add a compact top-center panel with searchable local dictation and recording
  history, copy and delete controls, and matching settings.
- Record microphone and computer audio locally, with a growing timestamped
  transcript, pause/resume, and continued recording while the panel is hidden.
- Use the same preferred microphone for Record and Caps Lock, including the
  built-in microphone when a Bluetooth input would otherwise be selected.
- Follow new transcript paragraphs automatically, with a Latest button after
  scrolling back. Collapse matching simultaneous source paragraphs while
  preserving the original captures, and drain audio already captured at Stop.
- Transcribe long recordings in bounded chunks and recover unfinished work after
  a restart. Microphone and Computer labels identify sources, not speakers.
- Make the listening cloud respond more clearly to quiet speech, dissolve around
  the pointer, and return reliably after idle periods.
- Keep GPU frame waits off the interface thread and make tab hit areas cover the
  full control.

## 0.10.0 — 2026-07-28

- Make Parakeet Metal the default, benchmark-backed transcription path.
- Reduce the model menu to three fully wired choices: Parakeet Metal,
  Parakeet CPU, and whisper.cpp greedy.
- Publish a privacy-safe seven-backend aggregate from 560 measurements without
  audio, transcripts, references, local paths, or recording identifiers.
- Increase the resting Voice Orb to 768 particles with a stronger visual floor.
- Preserve particle flow across recording completion and ease organically into
  the processing pulse.
- Delay and soften the processing color transition so short Parakeet jobs stay
  white and longer jobs develop only a restrained warm tint.
- Use a stable `com.joslack.luxit` application and LaunchAgent identity.

## 0.9.0 — 2026-07-28

- Make the white Voice Orb the only recording indicator.
- Make attractor motion and bottom-right placement permanent.
- Remove Ember, Equalizer, alternate colors, alternate placements, dynamics
  presets, their saved preferences, and all related menu controls.
- Render recording, processing, completion, and error feedback through the orb.
- Add fixed orb motion/layout tests and a source guard against restoring legacy
  indicator configuration paths.

## 0.8.4 — 2026-07-28

- Preserve the complete pre-simplification Luxit application and benchmark lab
  as the initial public Git baseline.
