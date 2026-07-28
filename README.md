# Luxit

<img src="Resources/AppIcon.png" width="128" alt="Luxit app icon">

For the local multi-engine speech-to-text comparison lab, see
[Voiceprint benchmark](benchmark/README.md).

A tiny, fully local macOS dictation utility:

- A persistent microphone icon lives in the macOS menu bar.
- Click it for cumulative dictated hours, words, dictation count, average
  processing latency, and effective real-time transcription speed.
- The dashboard also provides a curated Whisper model picker, Permissions,
  Vocabulary, Show App, Restart, and Quit controls. It is built entirely from
  standard AppKit menu items, section headers, subtitles, separators, and
  submenus, so macOS owns its appearance, accessibility, and dismissal.
- Press **Caps Lock** once to start recording. Luxit maps Caps Lock to
  an ordinary F19 HID event while it runs, bypassing macOS's built-in Caps
  Lock activation delay. The model loads from disk in
  parallel while you speak, so recording itself starts immediately.
- An audio-reactive indicator appears at the right edge of the display
  containing the active text cursor. Luxit locates the insertion caret through
  macOS Accessibility, then falls back to the focused element, focused window,
  or mouse display when an app does not publish caret bounds. Choose the
  localized **Ember**, larger **Equalizer**, or amorphous **Voice Orb** style
  and one of three curated colors: Coral, Cyan, or Violet.
- The Equalizer reflects 23 logarithmically spaced frequency bands from roughly
  90 Hz to 8 kHz, measured with a Hann-windowed vDSP FFT. Silence stays flat;
  recording does not mix in a decorative oscillator.
- The Voice Orb maps that same spectrum into a deterministic 512-particle
  cloud: every frequency owns a stable constellation distributed across all
  quadrants, rather than one contiguous wedge. Live voice energy adds
  smoothly randomized movement whose wide permanent velocity range,
  independent horizontal and vertical phases, and per-particle drift scales
  produce liquid motion. Voice energy and spectral change accelerate the
  global turn and strengthen the currents. A long, particle-irregular density
  falloff creates a larger wispy perimeter without a hard circular boundary or
  isolated protruding points. Particle radii vary independently within a
  deliberately narrow range, with a deterministic 12% long tail of larger
  grains for visible hierarchy. Particle size also responds subtly to overall
  voice energy and its assigned frequency band. The field maintains a large resting volume even
  when voice conditioning gates background noise; speech deforms and energizes
  that volume rather than determining whether it collapses. A transparent MetalKit
  point-sprite pipeline performs particle physics and rasterization on the
  Apple GPU at the active display's refresh cadence, without a background
  halo. White is the default indicator color. Particles around the pointer
  dissipate and reform, while the overlay always passes clicks through to the
  app beneath it. AppKit remains as a renderer fallback when Metal is
  unavailable.
- The orb fades in over 380 milliseconds using a frame-clamped smoothstep, so
  cold model loading cannot turn a missed frame into an opacity jump.
- Visualization input is voice-conditioned without altering transcription
  audio. Logarithmic speech-band weighting suppresses much of HVAC rumble and
  high-frequency hiss, while a persistent per-band noise estimate subtracts
  stationary background energy.
- A native **Orb Dynamics** submenu provides the two retained exploration
  presets: Turbulent and Attractor. These vary temporal speed, current
  strength, independent jitter, spatial correlation, and bounded
  strange-field forcing. Attractor has stronger voice-force and voice-speed
  coupling; Turbulent is the default.
- Indicator position is configurable from the menu bar: Right Edge,
  Bottom Right, Bottom Center, Bottom Left, Top Right, or Top Left. The chosen
  position is applied to the display containing the active text cursor.
- Press **Caps Lock** again to stop.
- When recording stops, the Equalizer contracts into an amber traveling pulse
  using the same bars while Whisper transcribes. After insertion, its bars
  retract toward the screen edge in a short top-to-bottom fade.
- When the Voice Orb is processing, it preserves the exact rotation, current,
  particle phases, and motion speed from the recording. A separate coherent
  inhale–exhale modulation is layered over that continuing flow until
  transcription completes, then the still-moving field contracts and fades.
- Press **Caps Lock** again during transcription to begin the next recording
  immediately. Up to three completed recordings are transcribed in order while
  one additional recording is in progress.
- Very short or quiet captures are discarded before Whisper runs. A local
  Silero voice-activity model then rejects non-speech audio before decoding,
  preventing Whisper from inventing text from steady room noise.
- Silero receives a fresh, explicitly reset recurrent context for every
  recording. A second lower-threshold pass protects quiet speech without
  carrying detector state between utterances.
- The final text is pasted wherever the cursor is with one trailing space, so
  consecutive dictation segments remain separated.

The model picker now shows seven benchmark-ranked profiles. In-app, whisper.cpp
greedy, whisper.cpp baseline, Parakeet Metal, and Parakeet CPU are active. Other
entries are shown for benchmark parity, ranked independently of their installed/
available state. Selecting an entry never starts a download: unavailable engines
remain disabled with an explicit reason.
The selected model is loaded lazily on the first Caps Lock press and stays warm for
consecutive dictations. After ten idle minutes it becomes eligible for unloading, but
is released only if macOS reports memory pressure. Audio never leaves the Mac, and the
clipboard is restored after insertion.

Caps Lock is temporarily remapped at macOS's HID layer to F19 and read through
a Quartz event tap. The app restores the prior HID mapping when it quits. The
event tap consumes F19, with the original Caps Lock event retained as a
fallback if remapping fails, so Caps Lock does not capitalize typed text. The
physical Caps Lock LED is intentionally unused; the screen-edge indicator is
the authoritative recording signal.

The audio engine is prepared before the hotkey listener becomes active. On a
Caps Lock press, the recording indicator is ordered onscreen before microphone
startup, and Whisper loading begins only after audio capture is ready.

After system or display wake, Luxit recreates the keyboard event tap and
retries the Caps Lock-to-F19 mapping with bounded backoff until `hidutil`
confirms that the mapping is active. It also rebuilds the display indicator
surfaces after display topology and wake changes. Restart
and Quit restore the original HID
mapping before exiting; they bypass ggml's unsafe process-exit Metal destructor
after all user-visible state has been cleaned up.

Queued results are inserted in recording order at whichever cursor is active
when each transcription finishes. If three transcriptions are already pending,
the menu-bar status reports that the queue is full and the app sounds a beep
instead of silently dropping the Caps Lock action.

## Install

Luxit currently requires an Apple-silicon Mac running macOS 26 or later,
plus [Homebrew](https://brew.sh). The installer builds from source; no audio,
models, certificates, or private keys are stored in this repository.

```sh
./scripts/install.sh
```

The installer builds the native app, installs it as
`/Applications/Luxit.app`, downloads the 574 MB q5 model and verified
885 KB Silero VAD model if necessary, and creates a per-user LaunchAgent so
Luxit is warm after login.

For a private local build, run `scripts/create-local-signing-identity.sh` once
before installing. It creates an app-specific self-signed identity in the login
keychain. Subsequent builds use the same designated requirement, so macOS keeps
Microphone, Accessibility, and Input Monitoring permissions across updates.
The certificate is trusted only for code signing and the private key grants
access to `/usr/bin/codesign`; remove the identity and certificate in Keychain
Access if this local trust is no longer wanted. Public distribution should use
an Apple Developer ID identity instead. If no persistent identity is available,
normal builds now fail with remediation guidance unless `LUXIT_ALLOW_ADHOC_SIGNING=1`
is set explicitly for testing.

To run a non-persistent local build intentionally:

```sh
LUXIT_ALLOW_ADHOC_SIGNING=1 ./scripts/build.sh
```

On first launch, approve:

1. **Microphone** access.
2. **Accessibility** access (needed to capture Caps Lock and paste text).
3. **Input Monitoring** access (needed to receive Caps Lock globally).

If Caps Lock does not respond immediately after approval, click the microphone
menu-bar icon, choose **Permissions**, and confirm all three entries show a
checkmark.

If you quit Luxit, reopen it from Applications or Spotlight. It also
starts automatically the next time you log in.

## Accuracy and vocabulary

Choose **Open vocabulary prompt…** from the menu-bar icon and add names,
acronyms, product names, or technical terms that Whisper should favor.

## Build only

```sh
./scripts/test.sh
./scripts/sign-app-shell-test.sh
./scripts/build.sh
ditto -x -k dist/Luxit.zip /private/tmp/luxit-preview
open /private/tmp/luxit-preview/Luxit.app
```

After validating an existing signed ZIP, install that exact artifact without a
second build or signing prompt:

```sh
./scripts/install.sh --use-existing-build
```

## Why final text instead of live text?

Whisper revises earlier words as later context arrives. Committing once after the
second Caps Lock press produces materially better punctuation and word choice.
The recording begins immediately; only the final insertion waits for inference.

## License

Luxit is open source under the [MIT License](LICENSE).
