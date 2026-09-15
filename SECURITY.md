# Security policy

Data Debris deletes files and handles licence payments, so security reports are taken
seriously and are welcome.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's
[private vulnerability reporting](https://github.com/tarun6k/data-debris/security/advisories/new)
on this repository, or email **security@datadebris.app**.

Please include what you need to demonstrate the problem: affected version or commit, steps
to reproduce, and what an attacker gains. If a proof of concept deletes files, describe it
rather than shipping something that runs unattended.

Expect an acknowledgement within 3 working days and an assessment within 10. You will be
credited in the release notes unless you prefer otherwise.

## What matters most here

Ranked by how much damage a bug would do:

1. **Data loss** — anything that removes, overwrites or fails to restore a file the user did
   not approve. Breaking a safety invariant (S1–S10 in [`CLAUDE.md`](CLAUDE.md)) counts even
   without an attacker: a path escaping the allowlist, a protected path treated as
   removable, a clean that bypasses Review, a journal that does not survive a crash, an
   Undo that restores to the wrong place.
2. **Privilege** — any route to root, a privileged helper or `sudo`. The app is designed to
   run with user authority only; a bug that escalates is a serious finding.
3. **Licensing and payment** — forging an entitlement, bypassing Ed25519 verification,
   evading the 2-Mac activation limit, or replaying a Paddle webhook.
4. **Privacy** — any path by which file names, paths, contents or scan results leave the
   machine. The app promises to contact only the Sparkle update host and the licence
   worker; a third destination is a bug.
5. **Update integrity** — anything that lets an unsigned or substituted update install.

## Out of scope

- The user deleting their own files through the Review screen as designed.
- Requiring Full Disk Access; that is a documented macOS permission, granted explicitly.
- Reports that the app is unsandboxed. It is distributed directly and not sandboxed by
  design, with Hardened Runtime on.
- Findings that need physical access to an unlocked Mac with an admin session.
- Automated scanner output with no demonstrated impact.

## Handling secrets

Never include real credentials in a report. If you find a live secret committed to this
repository, say that it exists and where, without pasting the value — it will be rotated
first and scrubbed from history second.
