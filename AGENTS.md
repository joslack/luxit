# Luxit contribution guide

## Product contract

Luxit is a small, fully local macOS dictation utility. The primary workflow is:
focus a text field, press Caps Lock, speak, press Caps Lock again, and receive
text at the focused cursor. Prefer removing options and code paths over adding
configuration.

Audio, transcripts, vocabulary, and private benchmark inputs must remain on the
Mac. Never add telemetry or a network transcription path.

## Architecture boundaries

- `Sources/Luxit/main.swift` owns the AppKit lifecycle, recording state, global
  shortcut, insertion, queueing, and indicator orchestration.
- `VoiceOrbGeometry.swift` must remain deterministic for identical inputs.
- `MetalOrbRenderer.swift` is the primary orb renderer. Keep the AppKit fallback
  in `main.swift` visually and behaviorally equivalent.
- `VoiceAnimationFilter.swift` may condition visualization input only. Never
  alter the audio written for transcription from this filter.
- `ModelCatalog.swift` exposes only fully wired, locally selectable backends.
  Selecting a model must not silently download it.
- Preserve the bundle identifier and persistent signing requirement so macOS
  privacy permissions survive upgrades.

## Verification

Run `./scripts/test.sh` for every code change. Orb work must cover pure geometry
or motion behavior in the corresponding test file. Model changes must cover
catalog availability and the real backend boundary.

Before handing off an installable change, run `./scripts/build.sh`. Normal
builds require the persistent Luxit signing identity. Ad-hoc signing is for
explicit local experiments only and must not be presented as a release build.

Do not commit `dist/`, `.build/`, downloaded models, recordings, private
transcripts, or `benchmark/data/`. Public benchmark changes may include only
privacy-safe aggregate results.

## Versioning and releases

`VERSION` is the sole version source of truth and uses `semver+build` form, such
as `0.11.0+26`. Every source checkout produces that exact version and build;
release tooling increments the build number once for each release.

Use:

```sh
./scripts/bump-version.sh auto --dry-run
./scripts/release.sh auto
```

The release command requires a clean `main`, bumps the version and monotonically
increasing build number, runs tests, creates a signed build, commits the version,
and creates an annotated tag. Add `--push` only when the release should be
published immediately. Pushing a semantic version tag creates the corresponding
GitHub Release automatically.

Use squash merges and conventional PR titles. `feat:` implies a minor release,
`fix:` and `perf:` imply a patch release, and `!` or a `BREAKING CHANGE:` footer
implies a major release. Documentation, tests, chores, and refactors alone do
not force a release. After a release-worthy PR is squash-merged, update local
`main` with a fast-forward pull, then run `./scripts/release.sh auto`. The
release script refuses to run unless local `main` exactly matches its fetched
`origin/main` tracking ref.

Repository merge settings must allow squash merges only, use the PR title as
the squash commit subject, require the conventional-title check, and block
direct pushes to `main`. These settings keep the commit history consumed by
`release-bump.sh` aligned with reviewed PR metadata.

Keep release commits limited to `VERSION`. Never move or replace an existing
public version tag.

The release workflow intentionally checks out no code, executes no repository
scripts, uses no marketplace actions, and grants `contents: write` only to its
single tag-triggered job. Keep it that way. Configure a GitHub tag ruleset for
`refs/tags/v*` that restricts creation to maintainers and blocks updates and
deletions. Configure the `github-release` environment for required maintainer
approval and semantic-version tags only. In Actions Policies, restrict `push`
workflow execution to trusted maintainers. Enable immutable releases in
repository settings when available. Do not introduce `pull_request_target`,
dynamic action references, or execution of untrusted pull-request code in a
privileged workflow.

## Change discipline

Preserve unrelated user changes. Keep the README centered on installation,
Caps Lock dictation, privacy, and benchmark outcomes; implementation detail
belongs here or in focused code comments. Prefer shared motion/layout constants
over divergent Metal and AppKit values.
