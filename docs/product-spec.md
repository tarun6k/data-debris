# Data Debris — Product & Technical Spec

A disk cleaner for MacBook and Mac mini that finds reclaimable data — app caches, logs, developer leftovers, duplicates, large forgotten files — shows all of it, and removes only what the user approves, reversibly. Companion to the ui-spec.md.

- **Stack** Swift 5.10 · SwiftUI + AppKit · Swift Concurrency · CryptoKit · SQLite
- **Target** macOS 13 Ventura and later, Apple Silicon + Intel
- **Distribution** Direct, signed & notarized DMG, Sparkle updates
- **Draft** v0.1 · 13 Sep 2026

## §1 · What it is

A native macOS utility that answers three questions: *what is taking up space that I don't need, is it safe to remove, and can I get it back if I'm wrong?* It is built around one design promise — **nothing is removed that the user has not seen and approved** — and one technical promise — **every removal is journaled and undoable**.

Its target user is anyone whose Mac is running low on space, with a particular focus on developers and creators, whose machines accumulate the largest and least visible junk (build caches, simulators, package caches, container images, render caches).

#### Position

The transparent cleaner. Competitors hide what they delete behind a big "Clean" button; this app makes the item list the product.

#### Business model

Free scan and full results forever. Subscription unlocks cleaning, Auto Clean and duplicates: **\$20 / 1 year** or **\$50 / 3 years**. Before any purchase, a Privacy & Security sheet is shown and must be acknowledged (§13).

#### Non-goals

Not a "speed booster", antivirus, uninstaller or RAM cleaner. Nothing under /System. These are the features that give cleaners a bad name.

## §2 · What it does

### Detect

- **App caches** — regenerable cache data written by apps and browsers.
- **Logs & crash reports** — diagnostic files nobody reads after a week.
- **Developer junk** — Xcode DerivedData, archives and device support, old simulators, CocoaPods/SwiftPM/Gradle/npm/pip/Cargo caches, node_modules in stale projects, Homebrew downloads, Docker images and build cache.
- **Duplicates** — byte-identical files across the home folder (and opted-in volumes), with one copy kept per group.
- **Large & old files** — files above a size threshold not opened in months, surfaced for a human decision.
- **Trash** — contents of the user's Trash, with size.
- **Leftovers** (v1.1) — support files from apps that are no longer installed.

### Explain

Every item carries a **reason** ("build intermediates, rebuilt automatically"), a **consequence** where one exists ("you may be signed out of some sites"), an owner app, size and last-modified date. Categories carry a safety level: Safe · Review · Manual.

### Let the user decide

Tri-state selection per category and per item, exclusions ("never touch"), Quick Look previews, Reveal in Finder, and a single Review & Confirm gate that lists everything about to move.

### Remove, reversibly

Items move to Trash by default. The app journals every move before it happens and offers one-click Undo (all items) or per-item Restore from History, for as long as the items remain in Trash.

### Automate, narrowly

Opt-in Auto Clean runs only the categories the user ticked on the Auto Clean screen, on a schedule or a low-space trigger, always to Trash, always with a notification and an Undo.

## §3 · What it never does

These are hard-coded and shown to the user under "Built-in protections" in Settings. They are not preferences.

| Never touched | Why |
|---|---|
| /System, /usr, /bin, /sbin, /private/var (except user-scoped tmp), the Preboot/Recovery volumes | SIP-protected or OS-critical; macOS manages them. |
| /Library (system-wide) and other users' home folders | Out of the current user's authority; requires root, which the app never asks for. |
| Application bundles (\*.app) and their contents | Deleting inside a bundle breaks code signing; uninstalling is out of scope. |
| Photos, Music, TV, Books and Final Cut/Logic libraries; Lightroom catalogs; Mail data | Databases with internal references; "duplicates" inside them are managed by the app. |
| Anything inside a Git, Mercurial or SVN working tree (except node_modules/build dirs listed in .gitignore) | Source is never junk; ignored build output may be. |
| ~/Library/Application Support, ~/Library/Preferences, ~/Library/Containers data, ~/Library/Keychains, ~/Library/Mobile Documents | App state, settings, sandboxed app data, credentials, iCloud Drive. A folder *named* "cache" inside these is still not touched in v1. |
| Time Machine backups and local APFS snapshots | Backups are not junk; snapshots are explained to the user, not deleted. |
| Files currently open or memory-mapped by a running process | Checked at clean time; skipped with reason "in use". |
| Hidden dot-files in the home root (.ssh, .gnupg, .zshrc …) | Configuration and secrets. |

**Rule of thumb encoded in the engine:** a path is removable only if it matches a positive rule in the category catalogue (§6). There is no "everything except the protected list" mode. Unknown = untouched.

## §4 · Safety invariants

Enforced in code, tested in CI, and listed in the app's About screen. Any feature that would break one of these does not ship.

1.  **Allowlist only.** An item can be removed only if a catalogue rule (§6) claims it. Rules are positive matches on path patterns plus predicates (age, size, owner), never "everything under X".
2.  **One gate.** Every manual removal passes through Review & Confirm. Smart Clean and the menu-bar shortcut land there too. Auto Clean removes only categories explicitly ticked on its own screen.
3.  **Trash by default.** Removal is `FileManager.trashItem`. Permanent deletion is a per-run choice, double-confirmed, unavailable to Auto Clean, and used automatically only where Trash is impossible (some external volumes), which the app states per item.
4.  **Journal before move.** Each item's original path, size, modification date, inode and (for duplicates) hash are written to the History database *before* the move. A crash mid-clean leaves a consistent, restorable record.
5.  **Undo while it exists.** Restore uses the journal to move items from Trash back to their original paths; if the original path is now occupied, the restored file gets a " (restored)" suffix. Undo is greyed only when Trash has been emptied.
6.  **Re-verify at clean time.** Between scan and clean the file may have changed. Each item is re-stat'ed; if size, mtime or inode differ, or the file is now open, it is skipped and reported.
7.  **Never the last copy.** A duplicate group always keeps at least one file; the UI disables the last checkbox and the engine refuses a group with zero survivors.
8.  **User authority only.** No root helper, no privileged daemon, no `sudo`. What the user can't delete in Finder, the app can't either.
9.  **No silent scope creep.** External volumes, network volumes and additional folders are opt-in. New categories added in updates ship unticked for Auto Clean.
10. **Honest numbers.** "Reclaimable" is computed from allocated blocks, excludes APFS clones and hard-link siblings, and the Done screen separates "moved to Trash" from "freed".

## §5 · How it works — architecture

Catalogue (rules)*→*Scanner*→*Analyzers*→*Findings store*→*UI selection*→*Planner*→*Journal*→*Executor*→*History

#### Catalogue

Declarative rule set (bundled JSON, versioned, updatable with the app). Each rule: id, category, safety level, path patterns, predicates, reason text, consequence text, owner resolution. See §6.

#### Scanner

One pass over in-scope roots using `FileManager.enumerator` with prefetched resource keys (size, allocated size, dates, type, flags). Emits `FileRecord`s into a bounded async stream. Respects protected paths (§3) by pruning at directory level.

#### Analyzers

Consumers of the stream, one per category: RuleMatcher (caches, logs, dev junk, leftovers), DuplicateFinder (§7), LargeOldFinder. Each produces `Finding`s with a stable id and evidence.

#### Findings store

In-memory model plus on-disk snapshot (SQLite) so results survive relaunch and partial scans can be resumed. UI observes it via `@Observable`.

#### Planner

Turns the selection into a `CleanPlan`: ordered items, disposal mode per item, consequence notices, running-app conflicts, estimated bytes. This is what Review & Confirm renders.

#### Journal & Executor

Journal writes the plan to History as *pending*; Executor re-verifies each item, moves it, marks it *done* / *skipped(reason)*. Restore is the inverse walk over the same journal. §8.

### Process model

- **Main app** (SwiftUI): UI, scan and clean run in-process under structured concurrency with `.utility` QoS.
- **Auto Clean agent**: a LaunchAgent (`~/Library/LaunchAgents`) that launches the app headless with `--auto-clean`; it shares the catalogue, engine and History database. No separate daemon, no root.
- **Menu bar extra**: lives in the main app process; when the app is closed it can stay as an agent-style status item if the user enables "Show in menu bar".

### Data

 ~/Library/Application Support/DataDebris/
 history.sqlite runs, items, restore state (WAL mode)
 findings.sqlite last scan snapshot
 catalogue.json current rule set (bundled copy as fallback)
 exclusions.json user "never touch" list
 settings.json thresholds, scope, schedule

## §6 · Category rules (catalogue)

Representative v1 rules. Paths are relative to ~ unless absolute. "Age" is time since last modification unless noted.

| Category | Rule (what matches) | Predicate | Level | Consequence shown |
|---|---|---|---|---|
| App caches | Library/Caches/\<bundle-id\>/\*\* | Any age; skip if bundle-id in exclusions or app has "in use" cache | Safe | App may start slower once |
| | Browser caches — Safari (Library/Caches/com.apple.Safari), Chrome/Edge/Brave/Arc (…/Default/Cache, Code Cache, GPUCache), Firefox (…/cache2) | Cache dirs only — never Cookies, Local Storage, Login Data, profile DBs | Safe | Pages load slower first time; some sites may sign you out |
| | Media app caches — Spotify, Slack, Discord, Teams, Zoom cache dirs | Known cache subfolders per app | Safe | Offline content re-downloads |
| Logs & crash reports | Library/Logs/\*\* | Age \> 7 days | Safe | — |
| | Library/Logs/DiagnosticReports/\*\* | Age \> 7 days | Safe | Older crash reports won't be available to developers |
| Developer junk | Xcode Library/Developer/Xcode/DerivedData/\* | Per-project folder; age \> 2 days for "Safe", else "Review" | Safe | Next build takes longer |
| | Xcode …/iOS DeviceSupport/\*, watchOS/tvOS DeviceSupport | Version not seen in a connected device for 90 days | Review | Re-downloaded when that device connects |
| | Xcode …/Archives/\* | Age \> 180 days | Manual | Needed to symbolicate crashes for that build |
| | Simulators — unavailable/old runtimes via `xcrun simctl` | Runtime not used 90 days | Review | Re-download from Xcode |
| | Package caches — .npm/\_cacache, .yarn/cache, Library/Caches/pip, .gradle/caches, .cargo/registry/cache, Library/Caches/CocoaPods, Library/Caches/org.swift.swiftpm, Homebrew Library/Caches/Homebrew | Any age | Safe | Next install re-downloads packages |
| | node_modules, .build, build/, target/, DerivedData inside projects | Only when listed in that repo's .gitignore and project root not modified for 90 days | Review | Reinstall with npm/swift/cargo build |
| | Docker — dangling images and build cache via `docker system df` | Docker running; user confirms per item | Review | Images re-pulled on next run |
| Duplicates | Byte-identical files in scope (§7) | Size ≥ 1 MB by default; excludes protected libraries and repos | Review | Kept copy is highlighted |
| Large & old | Any regular file in scope | Size ≥ 500 MB and last opened ≥ 180 days (settings) | Manual | None — user judgment |
| Trash | .Trash/\*\* and /Volumes/\*/.Trashes/\<uid\> | Any age; requires "Empty Trash" confirmation (permanent by nature) | Safe | Cannot be undone |

#### Rule format

 {
 "id": "xcode.deriveddata",
 "category": "developer",
 "level": "safe",
 "match": ["~/Library/Developer/Xcode/DerivedData/*"],
 "unit": "directory",
 "predicates": [{ "mtimeOlderThanDays": 2 }],
 "owner": "com.apple.dt.Xcode",
 "reason": "Build intermediates. Xcode rebuilds them automatically.",
 "consequence": "Your next build will take longer.",
 "autoCleanEligible": true
 }

Rules with `autoCleanEligible: false` can never appear on the Auto Clean screen, whatever their level. Catalogue updates ship with the app (not fetched at runtime) so a rule change is always a reviewed release.

## §7 · Duplicate engine

Group by size*→*Drop singletons*→*Hash first 64 KB*→*Drop singletons*→*Full SHA-256*→*Group*→*Pick default keeper

- **Scope**: home folder minus protected paths (§3); external volumes only if opted in; network volumes never.
- **Candidates**: regular files ≥ 1 MB (setting). Below that, duplicates rarely matter and hashing cost dominates.
- **Not duplicates**: files sharing an inode (hard links); APFS clones detected via `FIEMAP`-equivalent — on macOS, compare allocated blocks / use `F_LOG2PHYS` on the first extent — reported separately as "share storage already"; iCloud-evicted placeholders (`ubiquitousItemDownloadingStatus != current`) are skipped and never downloaded to hash; symlinks are never followed.
- **Hashing**: streaming SHA-256 via CryptoKit, 1 MB reads, at most 2 concurrent files on HDD / 6 on SSD, `.background` QoS, paused on low battery. Hashes cached in findings.sqlite keyed by (path, size, mtime, inode) so rescans are incremental.
- **Default keeper**: the copy in the most "canonical" location by a fixed priority (Pictures/Documents/Music \> other home folders \> Desktop \> Downloads), then the oldest. The user can change the rule globally or per group.
- **Presentation**: groups sorted by reclaimable bytes (size × (copies − 1)); Quick Look thumbnails; per-copy path, mtime, and "in Photos library" style annotations.

## §8 · Deletion, journaling and undo

### Clean run

1.  Planner builds a `CleanPlan`; Review & Confirm renders it. Running apps that own selected caches are detected via `NSRunningApplication`; the user chooses quit-and-continue or skip.
2.  On confirm, a `Run` row is inserted (mode, started_at, disposal) and every item is inserted as *pending* with path, size, allocated size, mtime, inode, volume id, and hash if known. `fsync` before proceeding.
3.  Executor processes items sequentially per volume (parallel across volumes): re-stat → compare → check open-file state (via `proc_listpidspath`) → `trashItem(at:resultingItemURL:)` → record the Trash URL and mark *done*; on any mismatch mark *skipped(reason)*.
4.  Directories matched as a unit (e.g. a DerivedData project folder) are trashed as a unit so Undo restores them whole.
5.  Run is marked *completed* (or *cancelled* after the current item). Done screen shows measured freed bytes (volume free space delta) vs. moved-to-Trash bytes.

### Undo / restore

- For each *done* item, verify the recorded Trash URL still exists and its size/inode match; move it back to the original path (creating intermediate directories). If the original path is occupied, restore with a " (restored)" suffix and tell the user.
- Partial success is reported per item; the run's status becomes *restored* or *partially restored*.
- If the Trash has been emptied, Undo is disabled with the reason and the timestamp of the empty, if detectable.

### Permanent delete (opt-in per run)

- Second confirmation sheet with a red button and the item count; not available for Auto Clean; History marks these items *irreversible*.
- Used implicitly only for Trash contents ("Empty Trash") and volumes where `trashItem` fails with "no Trash" — surfaced per item in Review.

## §9 · Auto Clean

- **Opt-in**, off by default. Enabling installs a LaunchAgent plist; disabling removes it.
- **Triggers**: calendar schedule (daily/weekly/monthly at a time) and a low-space threshold checked hourly.
- **Scope**: only categories/rules ticked on the Auto Clean screen and marked `autoCleanEligible`. Duplicates, Large & old, Archives are never eligible.
- **Conditions to run**: on AC power or battery \> 20 %; no full-screen app in front; not during a Time Machine backup; volume mounted and healthy. Otherwise reschedule +1 h, max 24 h, then skip and note it in History.
- **Behaviour**: full engine path (scan restricted to ticked rules → plan → journal → execute to Trash). No permanent delete, no Empty Trash.
- **Reporting**: notification with freed size and an "Undo" action button (24 h); History row marked Auto; menu-bar item shows "Auto Clean ran · Undo" for a day.

## §10 · Permissions

- **Full Disk Access (FDA)** is needed to read ~/Library subfolders macOS protects (Safari, Mail, Messages, Containers) and to see all caches. The app detects FDA by attempting to read a known protected path (e.g. ~/Library/Safari) and shows the live status; it deep-links to System Settings → Privacy & Security → Full Disk Access.
- **Without FDA** the app still works on the home folder with a persistent banner and a lower reclaimable figure; it never nags on a timer.
- **Moved-app trap**: FDA is granted to a specific binary path. If the app was granted in Downloads then moved to Applications, the grant silently breaks. The app checks its own location on launch and, if not in /Applications, offers to move itself *before* asking for FDA.
- **Not sandboxed**; distributed outside the App Store for this reason. Hardened Runtime enabled; entitlements limited to what Sparkle and Quick Look need.
- **No root, ever.** No privileged helper tool, no admin prompt.
- **External volumes** use a one-time per-volume opt-in stored by volume UUID.

## §11 · Performance & resource use

- Scan of a typical 1 TB home folder: target \< 60 s excluding duplicate hashing; hashing is incremental and cached.
- QoS `.utility` for scanning, `.background` for hashing; concurrency limited per volume type; pauses when the system reports thermal pressure or low battery.
- Network volumes are skipped; disconnected external volumes are detected via mount table before enumeration, so the app never blocks on a vanished disk.
- Memory: findings stream to SQLite; UI lists virtualize above 5,000 rows. Target \< 200 MB RSS during a full scan.
- App size target \< 20 MB; cold launch \< 1 s on Apple Silicon.

## §12 · Privacy & trust

- **No telemetry by default.** An optional, off-by-default crash reporter sends stack traces only, never paths or file names.
- **Network use** limited to the update check (Sparkle appcast, signed with EdDSA) and license validation against our license service (which talks to Paddle). Both are documented on the About screen with the exact endpoints.
- **Nothing leaves the Mac**: file names, hashes and paths are stored only in the local History database, in the user's own Application Support folder, deletable from Settings.
- **Transparent protections**: the never-touch list (§3) is visible in Settings, not only in this document.
- **Honest marketing**: the website states what the app does not do (no speed-up claims, no "System Data" magic) and shows the Review screen as the hero.
- Human name and support address on the About screen and website; a public changelog; a refund policy of 14 days no questions asked.

## §13 · Distribution, pricing & updates

- Developer ID signed, notarized, stapled; Hardened Runtime; universal binary (arm64 + x86_64).
- DMG with a "drag to Applications" layout; first launch checks it is in /Applications (see §10).
- Sparkle 2 for updates with signed appcast; updates never change the Auto Clean selection or exclusions; new catalogue rules ship unticked for Auto Clean and are announced in a "What's new" sheet.
- Optional App Store edition later, if a sandboxed subset (home folder + user-granted folders) proves worthwhile.

### Pricing & licensing

| Plan | Price | Per month | Includes |
|---|---|---|---|
| **Free** | \$0 | — | Unlimited scans, full results with reasons, exclusions, History viewer. No cleaning. |
| **1 Year**  | \$20  | \$1.67 | Cleaning, Undo, Duplicates, Auto Clean, all updates for the term. 2 Macs. |
| **3 Years** | \$50  | \$1.39 · Save 17 % | Same, 3-year term. 2 Macs. |

- **Subscription term, not auto-renew by default.** The user picks at purchase whether the plan renews automatically; a reminder email goes out 14 days before renewal either way. When a term lapses the app returns to Free — scan and results keep working, cleaning is locked, History and Undo of past runs remain available.
- **Payment** through **Paddle** as merchant of record, so global VAT/GST, invoices and refunds are handled and the app never sees card details; payouts to India by Payoneer or bank wire. Paddle Billing issues no license keys, so a small license service (one Cloudflare Worker) turns Paddle's `transaction.completed` and `subscription.*` webhooks into Ed25519-signed licenses and answers activate / validate / deactivate with a 2-Mac limit. Recovery by email link; 30-day offline grace; family plan (5 Macs, 2× price) later.
- **14-day refund**, no questions asked, from the merchant's portal.
- **Region pricing** via the merchant's purchasing-power parity tables (India and similar markets get localized prices), still anchored on \$20 / \$50.

### Privacy & Security sheet — shown before purchase

Whenever a locked action is attempted (Clean, Auto Clean toggle, Duplicates review) or the user opens Buy, the app first presents a modal sheet titled **"Before you pay: how this app treats your Mac"**. It must be scrolled to the end and acknowledged once per install before the plan picker appears. Its contents, in order:

1.  **What we can see** — the folders the app scans (home folder; ~/Library caches with Full Disk Access; volumes you opt in) and a link to the built-in never-touch list (§3).
2.  **What leaves your Mac** — nothing about your files. Exactly two network calls exist: signed update check and license validation (endpoints listed). No telemetry by default.
3.  **How deletion works** — Trash by default, journal before move, one-click Undo, no root helper, no system folders. The ten invariants (§4) in plain language.
4.  **Your payment** — processed by the merchant of record; the app never handles card data; 14-day refund; what happens when the term ends (Free mode, nothing deleted, nothing lost).
5.  **Links** — full Privacy Policy, Terms, and Security page on the website, opened in the browser; the same texts are bundled in the app for offline reading.
6.  **Acknowledge** — a single checkbox "I've read how this app handles my data" and a Continue button that stays disabled until the sheet has been scrolled through. No pre-ticked boxes, no countdown, no "skip".

After acknowledgement the plan picker appears (Free · 1 Year \$20 · 3 Years \$50) with the auto-renew choice visible, then the Paddle checkout opens in the default browser and the app polls the license service for the key, then activates. The sheet is available again at any time from Settings → About → "How this app treats your Mac" and is re-shown once if its text changes in an update.

## §14 · Testing strategy

#### Unit

- Every catalogue rule has positive and negative fixture paths
- Protected-path pruning
- Duplicate pipeline with clones, hard links, symlinks, evicted files
- Journal/restore round-trip incl. occupied original path

#### Synthetic home

- Script that builds a fake home with every category populated, plus traps (a game's "cache" save folder, a repo's node_modules, a Photos library)
- CI asserts: traps untouched, expected items found, freed bytes within 2 %

#### Real machines

- Matrix: Intel + Apple Silicon; macOS 13/14/15/current beta; iCloud Optimize on/off; external HDD/SSD; case-sensitive volume; second user account
- Beta of 20–50 users with an in-app "report a wrong deletion" button that attaches the run's journal

#### Release gate

- All S1–S10 invariants have an automated test
- No new rule ships without consequence text and a fixture
- Manual pass on the September macOS release before it ships to users

## §15 · Scope & roadmap

| Version | Includes |
|---|---|
| **v1.0**  | App caches, logs, developer junk, duplicates, large & old, Trash · Review gate · Trash + Undo · History · Exclusions · Auto Clean (caches/logs only) · Menu bar · FDA flow · Direct distribution |
| **v1.1**  | Leftovers from uninstalled apps · language packs · mail attachment cache · external volume duplicates · CSV export |
| **v1.2**  | Storage map (treemap) view · per-project developer cleanup view · scripting via Shortcuts |
| **Never** | System folder cleaning · RAM "optimization" · antivirus · speed claims · privileged helper |

The two documents together — this product spec and the UI spec — are enough to start the Swift project. Suggested build order: catalogue + protected paths → scanner + rule matcher → journal/executor/restore with tests → Results/Detail/Review UI → duplicates → Auto Clean → FDA and distribution.
