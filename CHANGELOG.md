# Changelog

Notable changes to Data Debris. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each version is a tag on this
repository and a GitHub release.

## [0.9.0-beta.1] - 2026-11-03

First public beta: scan and review only. Cleaning unlocks in 1.0.

### Added

- Scanning of the home folder, and of the `~/Library` caches macOS protects once Full Disk
  Access is granted, against the built-in catalogue. Every finding is shown with its size,
  the rule that claimed it and the consequence of removing it. Unknown files are untouched.
- Six categories:
  - **App caches** — per-app `~/Library/Caches`, browser caches (Safari, Chrome, Edge,
    Brave, Arc, Firefox; never cookies, logins or profile databases), media app caches
    (Spotify, Slack, Discord, Teams, Zoom).
  - **Logs & crash reports** — `~/Library/Logs` and DiagnosticReports older than 7 days.
  - **Developer junk** — Xcode DerivedData, device support and archives, simulator
    runtimes, package caches (npm, yarn, pip, Gradle, Cargo, CocoaPods, SwiftPM, Homebrew),
    gitignored build folders inside projects, Docker build cache.
  - **Duplicates** — byte-identical files from 1 MB, hash-verified, one kept copy always.
  - **Large & old** — files of 500 MB or more not opened for 180 days, for your judgement.
  - **Trash** — what Empty Trash would free, done by Finder itself.
- Exclusions, History viewer, the hard-coded Built-in protections list in Settings.
- Settings › About: version with a Beta label for 0.x builds, the exact two network hosts
  the app can talk to, Report a problem (sent through your mail app, after you read it).
- App icon. Universal build (Apple Silicon and Intel), macOS 13 Ventura or later.
- Packaging: `make dist` (universal Release archive, ad-hoc signature with Hardened Runtime,
  DMG with an Applications link, `.sha256`) and the Release workflow that publishes it.

### Safety invariants

Each one has a test in `DebrisCoreTests` / `DebrisAppTests`; full text in `CLAUDE.md` and
§4 of the product spec.

- **S1 Allowlist only.** A file is removable only if a catalogue rule claims it.
  Unknown = untouched.
- **S2 One gate.** Every manual removal passes through Review. Auto Clean removes only
  rules ticked on its own screen and marked `autoCleanEligible`.
- **S3 Trash by default** via `FileManager.trashItem`. Permanent delete is per-run,
  double-confirmed, never in Auto Clean.
- **S4 Journal before move.** The item row is written and `fsync`'d before the move.
- **S5 Undo** while items remain in Trash; restore to the original path or a
  " (restored)" suffix.
- **S6 Re-verify at clean time.** Re-stat; skip if size, mtime or inode changed or the
  file is open.
- **S7** A duplicate group never ends with zero kept copies.
- **S8 User authority only.** No root, no privileged helper, no `sudo`, ever.
- **S9 No silent scope creep.** External volumes are opt-in by UUID; new rules ship
  unticked for Auto Clean.
- **S10 Honest numbers.** Allocated blocks; clones and hard links excluded; "moved to
  Trash" is not "freed".

### Known limitations

- **Unsigned.** The build is ad-hoc signed, with no Developer ID and no notarization.
  The first launch is blocked by macOS until you choose Open Anyway in System Settings ›
  Privacy & Security; the README's Install section walks through it.
- **Manual updates.** Sparkle is built in but switched off (no update signing key yet).
  Settings › About says "Updates are not configured in this build". To update, download
  the next DMG and replace the app in Applications.
- **Free tier only.** Clean, Undo, Duplicates review and Auto Clean are locked, and
  checkout is not configured: the Choose a plan sheet shows the plans without buttons and
  says that cleaning unlocks in version 1.0. The license service is not deployed, so
  "Already have a license?" cannot activate a key yet.

[0.9.0-beta.1]: https://github.com/tarun6k/data-debris/releases/tag/v0.9.0-beta.1
