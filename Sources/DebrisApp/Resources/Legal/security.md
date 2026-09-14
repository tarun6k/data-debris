# Security

**Data Debris** — last updated 14 September 2026. The current version lives at datadebris.app/security.

## How deletion works

- **Allowlist only.** A file can be removed only when a built-in catalogue rule claims it. Anything the catalogue does not recognise is reported as unknown and left untouched.
- **Trash by default.** Removals go to the Trash via macOS's own mechanism. Permanent deletion is a separate, per-run, double-confirmed choice and is never available to Auto Clean.
- **Journal before move.** Every item is logged to a local journal and flushed to disk before it moves, so an interrupted run can always be recovered.
- **Re-verified at clean time.** Each file is re-checked immediately before removal; if it changed or is open, it is skipped.
- **Undo.** One click restores a run while its items remain in the Trash.

## What the app never touches

System folders, other users' homes, app bundles, photo and music libraries, mail data, developer working trees, Time Machine snapshots, open files, and your Keychain. The full never-touch list is shown in Settings and is hard-coded — it cannot be overridden by preferences.

## Privileges

The app runs entirely with your user account's authority. It never asks for an administrator password, installs no privileged helper, and uses no root processes.

## Network and code integrity

Two network endpoints only: the signed update feed and the license service. Updates are cryptographically signed and verified before install; license entitlements are Ed25519-signed by our server and verified on every read. The app ships with Hardened Runtime enabled and is notarized by Apple.

## Reporting

Found a vulnerability? Email security@datadebris.app — we respond within 48 hours.
