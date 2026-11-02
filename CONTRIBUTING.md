# Contributing

This is a closed commercial project; it is not accepting outside pull requests. These are
the working rules for anyone (or anything) with commit access.

[`CLAUDE.md`](CLAUDE.md) is the short version that agents read. Where this file and the
[product spec](docs/product-spec.md) disagree, **the spec wins** — say so rather than
quietly coding around it.

## The gate

```sh
make test
```

116 engine tests + 45 app tests. Run it before calling any change done — not "it compiles",
not "it looks right in the UI". If you touched `services/license-worker`, also run
`npm test` and `npm run typecheck` there (24 tests).

## Safety invariants come first

S1–S10 in [`CLAUDE.md`](CLAUDE.md) and §4 of the spec are not guidelines. **Every invariant
gets a test**, and a change that weakens one is wrong even if it makes something faster or
simpler. In particular:

- **S1** Allowlist only. If you are unsure whether a path is safe to delete, **it is not** —
  report it as `unknown` rather than claiming it with a rule.
- **S2** Every manual removal goes through Review. No second path to deletion.
- **S8** User authority only. No root, no privileged helper, no `sudo` — not behind a flag,
  not "temporarily".
- **S9** A new catalogue rule ships **unticked** for Auto Clean.

Adding a catalogue rule means adding the tests that prove what it claims and, just as
importantly, what it does not.

## Order of work

Engine before UI, and **tests before UI**. `Sources/DebrisCore` holds no UI code; if a type
needs `SwiftUI`, it belongs in `Sources/DebrisApp`.

## The Xcode project is generated

`DataDebris.xcodeproj` is produced by XcodeGen from [`project.yml`](project.yml) and is
gitignored. Edit `project.yml` and run `make gen`. Never commit the `.xcodeproj`, and never
hand-edit it expecting the change to survive.

## Dependencies

The dependency list is **GRDB, Sparkle and XcodeGen**. Ask before adding anything else,
including a "tiny" utility package. Most additions are cheaper written inline.

## Commits

Small commits, conventional messages:

```
feat(purchase): ChoosePlanSheet with computed savings
fix(executor): re-stat before move when mtime is unchanged
test(duplicates): group never ends with zero kept copies
chore(worker): local checkout simulator
```

Keep one logical change per commit. Do not mix a refactor into a behaviour change.

## Copy rules

UI text is part of the product, and these are enforced in review:

- Buttons name the amount: `Clean 9.7 GB`, `Restore 1,318 items`.
- **No exclamation marks. No emoji.**
- Never "boost", "optimize", or "junk is slowing down your Mac".
- Sizes like Finder (GB/MB), tabular figures. Paths in monospace, middle-truncated.

## Secrets

`.env`, `.dev.vars` and anything with a real key stay out of the repo — and out of prompts,
issues and commit messages. [`.env.example`](.env.example) carries the variable names with
empty values. If you believe a secret has been committed, rotate it first and clean history
second; rotation is what actually protects you.

## Running the app from a terminal

Executing the built binary directly makes it inherit the terminal's TCC permissions, which
makes Trash restore fail in confusing ways. Use `make run` (which uses `open`) so the app
gets its own permission context.

## Release

A release is a tag; the Release workflow ([`.github/workflows/release.yml`](.github/workflows/release.yml))
does the rest. Nothing is built or uploaded by hand.

1. Bump `MARKETING_VERSION` in [`project.yml`](project.yml) (and `CURRENT_PROJECT_VERSION`,
   which Sparkle compares) and add the entry to [`CHANGELOG.md`](CHANGELOG.md).
2. Commit:

   ```sh
   git commit -am "chore(release): 0.9.0-beta.1"
   ```

3. Tag. The part before the first hyphen must equal `MARKETING_VERSION`, or the workflow
   fails before building anything; a hyphen (`-beta.1`, `-rc.1`) marks a pre-release.

   ```sh
   git tag v0.9.0-beta.1
   ```

4. Push the tag:

   ```sh
   git push origin v0.9.0-beta.1
   ```

The workflow runs `make test` first, checks the tag, runs `make dist` (universal Release
archive, ad-hoc signed with Hardened Runtime, DMG and `.sha256`), launches the app once to
prove the signature loads its frameworks, and attaches `DataDebris-0.9.0-beta.1.dmg` and
`DataDebris-0.9.0-beta.1.dmg.sha256` to a GitHub release. Run `make dist` locally to get the
same DMG in `build/release/`. `make release` is the Developer ID chain (notarization,
signed appcast) for 1.0; it needs the identities in `scripts/release-env.sh`.

A dry run of the packaging on any branch: Actions → Release → Run workflow. It builds,
tests and uploads the DMG as a run artifact without creating a release.
