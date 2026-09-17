# Offline speaker setup

If installing Luxit fails while downloading the speaker model or FluidAudio
runtime, download the [offline speaker package](https://github.com/joslack/luxit/releases/download/v0.13.1/Luxit-speaker-support.zip)
from GitHub. It contains the same pinned model and runtime source archive used
by Luxit, with licenses and SHA-256 checksums. It works with v0.13.0–v0.13.2.

The package is about 45 MB. It contains no recordings, transcripts, personal
correction rules, or signing identity. It is a dependency cache, not a prebuilt
app or a complete offline installer.

## Install

1. Save `Luxit-speaker-support.zip` in Downloads on the Mac where you are
   installing Luxit. You can also transfer it from another Mac.
2. Open Terminal in your Luxit source folder: the folder containing `VERSION`
   and `scripts/`. Finish any active Luxit recording before installation.
3. Run:

   ```sh
   ditto -x -k "$HOME/Downloads/Luxit-speaker-support.zip" .
   ./scripts/install.sh
   ```

For a first installation, run `./scripts/create-local-signing-identity.sh`
before `./scripts/install.sh`. Existing installations should keep that Mac's
current Luxit signing identity so privacy permissions survive the update.

The archive populates the hidden `.build` directory. The existing installer
verifies the cached files against its pinned checksums and uses them without
downloading the speaker dependencies from Hugging Face or GitHub. Do not put
these files directly inside an installed `.app`, which would change its signed
contents.

The main speech-recognition and voice-activity models, Homebrew dependencies,
and Xcode command-line tools must already be available, or their usual setup
will still need network access. See [installation requirements](../README.md#install).

## Verify or troubleshoot

The GitHub asset's SHA-256 digest can be compared with:

```sh
shasum -a 256 "$HOME/Downloads/Luxit-speaker-support.zip"
```

The archive also contains `speaker-support-notices/SHA256.json`, listing each
dependency's checksum, and `SPEAKER-SUPPORT-README.txt` with setup instructions.
The model is the pinned LS-EEND DIHARD III 500 ms Core ML model; the runtime
archive is FluidAudio 0.15.7. Licenses are included.

If installation still attempts a speaker download, check that you extracted
the archive into the same source folder you are building. A missing or corrupt
model file is downloaded again; a runtime checksum mismatch stops the build.
If the error concerns a different dependency, this package will not replace it.
Keep the last few error lines to distinguish connection, certificate, checksum,
and local-file errors. Certificate verification remains enabled.
