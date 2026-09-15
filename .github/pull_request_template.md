## What this changes

<!-- One or two sentences. Link the spec section (§n) or UI screen if relevant. -->

## Why

<!-- The problem, not the diff. -->

## Checklist

- [ ] `make test` passes (116 engine + 45 app tests)
- [ ] `npm test && npm run typecheck` in `services/license-worker`, if it was touched
- [ ] Engine changes have tests, written before the UI
- [ ] No new dependency beyond GRDB / Sparkle / XcodeGen (or it was agreed first)
- [ ] `project.yml` edited rather than the generated `.xcodeproj`
- [ ] No secrets, keys or real Paddle values in the diff
- [ ] Copy rules: no exclamation marks, no emoji, buttons name the amount

## Safety invariants

<!-- Delete this section only if the change cannot touch scanning, matching,
     deletion, restore, Auto Clean or protected paths. -->

Which of S1–S10 does this touch, and what test covers it?

- [ ] A new catalogue rule ships **unticked** for Auto Clean (S9)
- [ ] Nothing can be removed that a rule does not claim (S1)
- [ ] Removal still passes the single Review gate (S2)
- [ ] Journal is written and `fsync`'d before any move (S4)
- [ ] Undo still restores to the original path (S5)

## Verification

<!-- What you actually ran or clicked. "Tests pass" is not enough for UI changes;
     say which screens you exercised. -->
