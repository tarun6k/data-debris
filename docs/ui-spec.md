# Data Debris — UI Spec

Screen-by-screen specification for a transparent disk cleaner: every detected item is shown, nothing is removed without an explicit or pre-approved choice, and every deletion is reversible via Trash.

**Platform** macOS 13+, SwiftUI **Window** 960 × 640 min, sidebar + content **Distribution** Direct (notarized DMG), Full Disk Access requested **Draft** v0.1 · 12 Sep 2026

Welcome*→*Home*→*Scanning*→*Results*→*Category / Duplicates*→*Review & Confirm*→*Cleaning → Done*→*History

Primary manual path above. Auto Clean (screen 8) runs the same engine in the background and reports into History (screen 10). On the Free plan, the first locked action (Clean, Auto Clean, Duplicates) opens the Privacy & Security sheet (screen 12) and then Choose a Plan (screen 13), after which the flow resumes where it was.

## Screen 0 · Welcome & Access

First launch only. Explains what the app does, asks for Full Disk Access, and sets the safety expectation before anything is scanned.

*(wireframe: see docs/design/ PNG)*

### Elements

- 3-step carousel: What we clean · How we keep you safe · Grant access
- Live FDA status pill (polls every 2 s while Settings is open)
- Primary: Open System Settings → Privacy & Security → Full Disk Access (deep link)
- Secondary: Continue with limited access

### States

- **Not granted** — amber pill, explanation text
- **Granted** — green pill, button becomes "Start scanning"
- **Limited** — Home shows a persistent banner "Some caches hidden · Grant access"

### Rules

- Never block the app on FDA; degrade, don't nag
- No account, no email, no analytics prompt here
- Shown again only if FDA is later revoked

## Screen 1 · Home

Landing screen every launch. Answers "how full is my disk, when did I last clean, what can I do now" in one glance.

*(wireframe: see docs/design/ PNG)*

### Elements

- Disk gauge: free / total, segmented usage bar (System, Apps, Documents, Other) using APFS container figures
- Volume picker if more than one volume is mounted
- Primary: **Scan now**. Secondary: **Smart Clean** (pre-selects safe categories, still goes through Review)
- Auto Clean status line with next run
- Last-clean summary linking to History

### States

- **First run** — no last-clean; copy "Run your first scan"
- **Low space** (\<10 % free) — gauge turns amber, Scan button gains "Recommended"
- **Limited access** — banner under toolbar
- **Scan cached** (\<24 h old) — "View last results" appears beside Scan now

### Interactions

- ⌘R starts a scan from anywhere
- Sidebar items disabled until a scan exists (Results, Duplicates)

## Screen 2 · Scanning

Progress with meaning: which category is being scanned, what's been found so far, and a way out that doesn't waste the work.

*(wireframe: see docs/design/ PNG)*

### Elements

- Running total of reclaimable bytes (the number users watch)
- Per-category checklist: done / in progress / queued, with live size and count
- Current path, truncated middle, monospace
- Overall progress bar — determinate for cache/log stages, indeterminate during duplicate hashing
- **Stop & show results** keeps partial results; categories not finished are marked "Incomplete · rescan"

### Rules

- Duplicate hashing runs last and is throttled on battery; a "Skip duplicates" link appears after 30 s
- Scan resumes if the window is closed; a menu-bar item shows progress
- Unreadable paths (permission denied) are counted and reported once, never shown as errors per file

## Screen 3 · Results

The heart of the app: every category, its reclaimable size, its safety level, and a tri-state checkbox. This is where the "show everything" promise is kept.

*(wireframe: see docs/design/ PNG)*

### Elements

- Category rows: tri-state checkbox, name, safety pill, size, item count, disclosure chevron → Category Detail
- Safety pills: Safe pre-checked · Review partially or un-checked · Manual never pre-checked
- Sticky footer: selected size + count, Deselect all, **Review…** (never "Delete" directly from here)
- Sort: by size (default), by category, by safety

### Categories (v1)

| Category | Sources | Default |
|---|---|---|
| App caches | ~/Library/Caches, browser caches | Checked |
| Logs & crash reports | ~/Library/Logs, DiagnosticReports | Checked |
| Developer junk | DerivedData, iOS DeviceSupport, old simulators, node_modules \> 90 d unused, Homebrew cache, Docker | Partial |
| Duplicates | Home folder, byte-identical groups | Unchecked |
| Large & old files | \> 500 MB and not opened in 6 months | Unchecked |
| Trash | User Trash | Checked |

### States

- **Nothing found** — "Your Mac is already tidy" with disk gauge
- **Partial scan** — incomplete categories greyed with "Rescan" link
- **Stale** (\> 24 h) — banner "Results from yesterday · Rescan"

## Screen 4 · Category Detail

Every individual item in a category with enough context to decide: path, owner app, size, last modified, and a one-line reason it is considered removable.

*(wireframe: see docs/design/ PNG)*

### Columns / row content

- Checkbox · name · full path (monospace, middle-truncated, tooltip shows full) · size · modified date
- Reason line (subtitle): why it's removable and what happens after ("rebuilt automatically", "reinstall with npm install")
- Owner app icon where resolvable from bundle id

### Interactions

- Group by: App · Folder · None. Sort: Size · Name · Date
- Space bar → Quick Look preview; ⌘⏎ Reveal in Finder
- Right-click: Exclude this item / Exclude this folder / Copy path
- Multi-select with shift/⌘, then bulk check/uncheck
- "Never touch selected" adds to Exclusions (screen 9) and removes from list with an undo toast

### Rules

- Items inside running apps' active caches are flagged "In use · app will be signed out" with a warn pill
- Lists over 5,000 items virtualize; counts stay exact
- Selection survives navigating back to Results

## Screen 5 · Duplicates

Duplicates need a different layout: groups of identical files where the user picks which copy survives, with previews so photos and documents can be judged by eye.

*(wireframe: see docs/design/ PNG)*

### Elements

- Left list: one row per group (name, copies, size); sorted by reclaimable size
- Right pane: previews side by side (Quick Look thumbnails), one row per copy
- Exactly one copy per group carries the **Keep** badge; others have checkboxes
- Auto-keep rule buttons: Keep oldest · Keep newest · Keep in *folder* · Keep shortest path
- "Apply rule to all groups" with a count of groups affected

### Rules

- Duplicate = same size + same full SHA-256; name is irrelevant
- APFS clones and iCloud-evicted placeholders are excluded and noted in a footnote ("38 clone pairs ignored — they share storage already")
- Files inside app bundles, Photos/Music libraries and Git repos are never listed
- A group can never end with zero kept copies; the last checkbox is disabled

### States

- **No duplicates** — empty state with tip to include external drives (Settings)
- **Hashing skipped** — CTA "Scan for duplicates now"

## Screen 6 · Review & Confirm

The single gate before anything moves. A flat, complete list of what is about to go, the consequences, and the choice between Trash and permanent removal.

*(wireframe: see docs/design/ PNG)*

### Elements

- Headline number: bytes to be freed
- Consequence notices at the top, one per known side effect, each with "Remove from list"
- Collapsible per-category lists — full paths available here too
- Disposal mode dropdown: **Move to Trash** (default) · Delete permanently (shows a second confirmation and a red button)
- Primary button names the amount: "Clean 9.7 GB"
- Export list (.txt) of everything about to be deleted

### Rules

- Permanent delete is required only for items that cannot go to Trash (external volumes without .Trashes) — the app says so per item
- If an app that owns selected caches is running, offer "Quit Safari and continue" or "Skip Safari items"
- No timers, no auto-advance

## Screen 7 · Cleaning & Done

Short progress phase, then a receipt: what was freed, what was skipped and why, and a one-click Undo.

*(wireframe: see docs/design/ PNG)*

### Cleaning phase

- Determinate bar by bytes, current file name, Cancel (stops after current file; already-moved items stay in Trash and are logged)
- Sheet, not a new screen; Review list remains behind it

### Done phase

- Actual bytes freed (measured, may differ from estimate) and new free space
- Skipped items with reasons: in use · permission denied · vanished
- **Undo** restores every item from this run to its original path; available while items remain in Trash
- "Empty Trash now" is offered, never done automatically
- Run is written to History

## Screen 8 · Auto Clean

Opt-in scheduled cleaning, limited to categories the user explicitly approves. Everything else stays manual.

*(wireframe: see docs/design/ PNG)*

### Elements

- Master toggle; everything below disabled when off
- Schedule: Daily / Weekly / Monthly + time; plus a low-space trigger
- Category checklist mirroring Results, with per-category sub-options (e.g. exclude browser caches, age threshold)
- Duplicates and Large & old files are visibly locked to manual
- Notification setting: Always · Only if \> 1 GB · Never; disposal is always Trash
- Next/last run line, Run now

### Rules

- Runs via a LaunchAgent; skipped on battery below 20 % or when a full-screen app is active, rescheduled +1 h
- Never runs a category that was not ticked here, even if it is "Safe"
- Every run produces a History entry with an Undo

## Screen 9 · Exclusions & Settings

Where trust is configured: things the app must never touch, where it is allowed to look, and how it disposes of files.

*(wireframe: see docs/design/ PNG)*

### Exclusions

- List of paths and apps; type badge (folder / file / app); drag-and-drop from Finder to add
- Built-in, non-removable protections listed under a disclosure: system folders, app bundles, Photos & Music libraries, Git working trees, Time Machine local snapshots

### Scan scope

- Volumes to include (internal default; external drives opt-in)
- Folders for duplicate search (default: home folder)
- Thresholds: large file size (500 MB), "old" age (6 months), dev junk age (90 days)
- Full Disk Access status and re-request link

### Cleaning

- Default disposal: Move to Trash (locked default; permanent delete is per-run only)
- Keep History for: 30 / 90 / 365 days
- Warn before deleting caches of running apps (on by default)

### General

- Show in menu bar; launch at login; check for updates; appearance follows system
- Export diagnostics (scan log without file contents)

## Screen 10 · History & Undo

A ledger of every run, manual or automatic, with exact item lists and restore controls. This is the answer to "what did you delete?"

*(wireframe: see docs/design/ PNG)*

### Elements

- One row per run: timestamp, mode (Manual / Auto / Smart), item count, bytes freed, restore status
- Expand a run → full item list with original paths; per-item Restore
- **Undo** restores all items still in Trash; greyed with reason once Trash has been emptied
- 30-day total; export as CSV

### Rules

- History is written before the move begins (path, size, hash) so a crash mid-clean is still recoverable
- Retention per Settings; the log never stores file contents

## Screen 11 · Menu Bar Item

Optional always-available glance and shortcut; never a second UI.

### Contents

- Free space (icon shows a small gauge; amber when below threshold)
- Scan now · Smart Clean · Open Mac Cleaner
- During a scan/clean: progress and Cancel
- Auto Clean next run; "Auto Clean ran · 1.9 GB freed · Undo" for 24 h after a run

### Rules

- Smart Clean from the menu bar still opens the Review screen — no deletion is ever one click from the menu bar

## Screen 12 · Privacy & Security Sheet

Shown before the plan picker the first time a locked action is attempted (Clean, Auto Clean toggle, Duplicates) or Buy is opened. The user reads how the app treats their Mac and their payment before seeing a price.

*(wireframe: see docs/design/ PNG)*

### Elements

- Modal sheet, four numbered sections in fixed order: Scope · Data leaving the Mac · Deletion safety · Payment
- Each section has a plain-language summary and a link to the detailed page (opens in browser; bundled copy in About for offline)
- One checkbox, unchecked by default; **Continue** enabled only after the sheet is scrolled to the end *and* the box is ticked
- **Not now** closes the sheet and returns to the locked screen unchanged

### Rules

- Shown once per install; re-shown once if the text changes in an update
- No countdown, no pre-ticked box, no "skip", no price on this screen
- Always reachable from Settings → About → "How this app treats your Mac"
- Acknowledgement is stored locally with the text's version hash; nothing is sent

## Screen 13 · Choose a Plan

Appears only after the Privacy & Security sheet has been acknowledged. Three columns, one decision, no dark patterns.

*(wireframe: see docs/design/ PNG)*

### Elements

- Three plan cards: Free · 1 Year \$20 · 3 Years \$50, with per-month equivalents and the 3-year saving computed, not hard-coded
- The 3-year card is visually highlighted but not pre-selected; there is no default selection
- Auto-renew checkbox, **off by default**, with the reminder promise stated
- "Already have a license?" → email + key sheet
- Regional price shown when Paddle returns one ("₹1,299 / year" with the USD anchor in a tooltip)

### Flow & states

- Click a paid plan → Paddle checkout opens in the default browser with the chosen price (recurring or one-time, per the auto-renew checkbox) → app shows "Waiting for checkout…" with Cancel → the license service issues a key from Paddle's webhook, the app picks it up and activates → the locked action resumes where the user left off
- **Active**: Settings → License shows plan, expiry date, Macs used (2 max), Manage / Cancel renewal / Refund links to Paddle's customer portal
- **Expiring** (14 days): one banner on Home, dismissable
- **Lapsed**: back to Free; scan and results work, cleaning locked with "Renew" — History and Undo of past runs remain
- **Offline**: 30-day grace before license re-check is required

## Global rules

### Safety invariants

- Nothing is removed without passing through Review (manual) or an explicitly ticked Auto Clean category
- Default disposal is Trash; permanent delete is per-run, double-confirmed, and never available for Auto Clean
- Every removal is logged before it happens and is undoable while in Trash
- Protected locations are hard-coded and shown to the user, not just hidden

### Visual language

- Safety pills carry meaning (Safe / Review / Manual); they are the only semantic colour and are never used for decoration
- Sizes are always shown in binary-decimal style matching Finder (GB, MB) and right-aligned with tabular figures
- Paths in monospace, middle-truncated, full path on hover and in tooltips
- Native SwiftUI controls, sidebar navigation, system appearance (light/dark) followed

### Copy rules

- Buttons name the outcome and the amount: "Clean 9.7 GB", "Restore 1,318 items"
- Every removable item has a one-line reason and, where relevant, a consequence
- No fear language ("junk is slowing down your Mac"); state facts

### Keyboard

- ⌘R scan · ⌘⌫ toggle selection · Space Quick Look · ⌘⏎ Reveal in Finder · ⌘Z undo last clean (from Done/History) · Esc closes Review

**Out of scope for v1:** uninstaller, malware scan, memory "optimization", startup item management, and any deletion under /System or /Library. These are either handled by macOS itself or are the features that give cleaners a bad name.
