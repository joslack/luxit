# Luxit

<img src="Resources/AppIcon.png" width="128" alt="Luxit app icon">

Local voice-to-text for macOS.

Put your cursor in any text field, press **Caps Lock**, and speak. Press
**Caps Lock** again and Luxit inserts the transcription where your cursor is.

## Install

Luxit requires an Apple-silicon Mac running macOS 26 or later and
[Homebrew](https://brew.sh). The installer ensures Homebrew `whisper-cpp` is
version 1.9.1 or newer and includes its Parakeet runtime.

```sh
git clone https://github.com/joslack/luxit.git
cd luxit
./scripts/create-local-signing-identity.sh
./scripts/install.sh
```

The signing-identity step is needed only once. It lets macOS keep Luxit's
permissions when you update the app. Later updates only need:

```sh
git pull --ff-only
./scripts/install.sh
```

For a versioned download, open the [latest release](https://github.com/joslack/luxit/releases/latest)
and download **Source code (zip)**. Unzip it, open Terminal in that folder, and
run `./scripts/create-local-signing-identity.sh` followed by
`./scripts/install.sh`. Each Mac keeps its own signing identity,
permissions, models, and transcript history.

On first launch, approve **Microphone**, **Accessibility**, and
**Input Monitoring** access. Luxit then runs from the menu bar and starts
automatically when you log in. If Caps Lock does nothing, open
**Permissions** from the menu-bar menu and enable any missing access in System
Settings.

On first install, Luxit downloads the recommended Parakeet Metal, voice
activity, and speaker models. The speaker model adds about 44 MB to the app.
Other transcription model choices are not downloaded automatically.

## Use

1. Focus the text field where you want to type.
2. Press **Caps Lock** and speak.
3. Press **Caps Lock** again and keep the field focused until the text appears.

The white orb shows that Luxit is listening, then gently pulses while it
transcribes. All audio and transcription stay on your Mac.

Click Luxit's menu-bar icon to open the panel at the top center of your screen.
**History** keeps your dictations and recordings locally: search, open, copy,
or delete a transcript. History begins with this version; older dictations
cannot be recovered.

Choose **Record** to capture your microphone and computer audio together, such
as a call or video. The transcript grows in timestamped paragraphs at natural
pauses, with separate **Microphone** and **Computer** labels. Pause, resume,
and stop from the top bar. These recordings do not paste into another app.
The menu-bar icon shows a steady red dot while recording, with no floating cloud
or recording label. Pausing changes the icon to a pause symbol.
macOS may ask for **Screen & System Audio Recording** access. Luxit receives
only audio; it does not save screen images or video. macOS shows **Currently
Sharing** while this capture session is open, including while paused. **Stop**
ends the capture session. Ordinary Caps Lock dictation uses only the microphone.
Headphones help keep computer playback from also entering your microphone.

Recordings made with Parakeet also estimate **Speaker 1**, **Speaker 2**, and so
on within each audio source. Labels appear as analysis catches up; a dotted
underline marks words with no assigned speaker, not a change of speaker.
Detection supports up to ten voices per source and can make
mistakes, especially with quiet or overlapping speech. These numbers reset for
each recording and do not identify people by name. Whisper recordings retain
source labels without individual speaker labels.

Recording audio stays locally in small chunks until the transcript and speaker
analysis are safely saved, then is removed. Interrupted recordings recover when
Luxit reopens; failed chunks have a **Retry** button. Speaker-analysis failure
keeps the transcript usable. Transcript history stays in
`~/Library/Application Support/EdgeWhisper/History/` until you delete it.
Use the gear button or right-click the menu-bar icon for models, permissions,
and other controls. Click outside, press **Escape**, or use the up arrow to dismiss the panel;
recording and transcription continue while it is hidden. Keep Luxit running
and your Mac awake until you stop recording.

## Benchmarks

These results use 20 private English dictation samples, decoded four times by
each backend on the same M3 Pro MacBook Pro with 18 GB of unified memory.
Lower latency and word error rate are better.

| Backend | Warm p50 | Word error rate | Keyword recall |
|---|---:|---:|---:|
| **Parakeet TDT v3 Q8 Metal** | **88.9 ms** | **6.09%** | **91.5%** |
| Parakeet TDT v3 Q8 CPU | 145.7 ms | **6.09%** | **91.5%** |
| MLX Whisper large-v3-turbo 4-bit | 659.2 ms | 8.41% | 82.3% |
| whisper.cpp turbo Q5 greedy | 1548.9 ms | 9.14% | 85.2% |
| whisper.cpp turbo Q5 baseline | 1599.8 ms | 9.38% | 84.9% |
| WhisperKit distil-large-v3 | 1758.8 ms | 12.02% | 77.8% |
| WhisperKit large-v3-turbo | 2040.8 ms | 9.53% | 85.2% |

Parakeet Metal was both the fastest and tied for the most accurate backend, so
it is Luxit's default. See the
[full methodology and privacy-safe aggregate data](benchmark/results/README.md)
for cold-start latency, p90 latency, character error rate, and reproducibility
details. No recordings or private transcripts are committed to this repository.

## Development

```sh
./scripts/test.sh
./scripts/build.sh
```

## License

Luxit is open source under the [MIT License](LICENSE).
