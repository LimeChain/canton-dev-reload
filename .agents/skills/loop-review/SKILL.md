---
name: loop-review
description: Run a simple two-session plan/review Markdown loop using .skills-workspace/loop/plan.md and .skills-workspace/loop/review.md.
disable-model-invocation: true
---

# Loop Review

Two already-open agent sessions iterate on a plan: one is `plan`, the other is `review`. They share `.skills-workspace/loop/plan.md` and `.skills-workspace/loop/review.md`. The loop ends **ONLY** when `.skills-workspace/loop/review.md` starts with `STATUS: APPROVED`.

This skill **DOES NOT LAUNCH AGENTS** — the user opens both sessions.

## Role focus

- **Plan**: Address every review issue, but push back in `## Review issues addressed` when a fix would harm the plan rather than silently complying.
- **Review**: Block only on substantive defects (correctness, contradictions, missing constraints) and approve once they're resolved — don't manufacture fresh nits to extend the cycle.

## Loop (run as EITHER `plan` or `review`)

**STAY IN YOUR ROLE AND REPEAT THE STEPS BELOW UNTIL YOU EXIT ON `APPROVED`. DO NOT STOP AFTER A SINGLE TURN.**

Set `scripts_dir=.agents/skills/loop-review/scripts` before running the loop.

1. `$scripts_dir/loop-next.sh <role> --wait 600` — blocks until the other side updates its file (polls every 2s) or 10 minutes elapse.
2. Branch on the script's last line:
   - `APPROVED: ...` → as **plan**, run `$scripts_dir/loop-finalize.sh` (no args; defaults to `.skills-workspace/loop/source.path`) — or `$scripts_dir/loop-finalize.sh <DEST_PATH>` if the source was inline. It merges the approved `.skills-workspace/loop/plan.md` over the source path and wipes the sandbox; report the destination as the final artifact. As **review**, just stop and report — only the plan finalizes (it owns `source.path`).
   - `STALEMATE: ...` → stop and report the disagreement to the user. Plan does **NOT** run `$scripts_dir/loop-finalize.sh`. If review-declared, rationale is in `.skills-workspace/loop/review.md` `## Notes`; if plan-declared, rationale is in `.skills-workspace/loop/.stalemate`.
   - `TURN: plan first-pass` → copy the user's existing plan into `.skills-workspace/loop/plan.md` **VERBATIM**. The plan lives outside this skill — typically at a path the user provides, in the current conversation, or in another agent's plan directory. Do not regenerate, summarize, or paraphrase. If the source is a file path, also record it for finalize: `printf '%s\n' "<abs-path>" > .skills-workspace/loop/source.path`. If the source was inline content with no file path, skip `source.path` (finalize will then need an explicit `DEST_PATH`).
   - `TURN: plan recommit` → `.skills-workspace/loop/plan.md` already exists but no commit is recorded (typically after a warm reset wiped `.state`). Read `.skills-workspace/loop/plan.md`, decide whether to edit; either way run `$scripts_dir/loop-done.sh plan` to publish.
   - `TURN: plan revision` → read `.skills-workspace/loop/review.md`, revise `.skills-workspace/loop/plan.md` to address every issue, append a `## Review issues addressed` section. If the review has reraised an issue after your prior `## Review issues addressed` rebuttal and you still believe the fix would harm the plan, instead write `.skills-workspace/loop/.stalemate` with the reason and stop — do not edit `.skills-workspace/loop/plan.md` and do not call `$scripts_dir/loop-done.sh`.
   - `TURN: review ...` → read `.skills-workspace/loop/plan.md`, then write `.skills-workspace/loop/review.md`: first line is exactly `STATUS: ISSUES`, `STATUS: APPROVED`, or `STATUS: STALEMATE`; followed by a `## Issues` section (bullets, or `None.` when approved) and a `## Notes` section. When STALEMATE, summarize the disagreement in `## Notes`, then publish via `$scripts_dir/loop-done.sh review` (same commit discipline as approval). Do not approve while material issues remain.
   - `NO_TURN: ...` → the 10-minute poll window expired with no change. **IMMEDIATELY CALL `$scripts_dir/loop-next.sh` AGAIN** — do not stop, do not report.
3. After any `TURN`-driven write: `$scripts_dir/loop-done.sh <role>`. Call it **ONLY AFTER THE FINAL EDIT IN YOUR BATCH** — it is the publish/turn-release event the other side polls for, so calling it mid-batch hands a partial file over.
4. Go back to step 1.

## Rules

- Plan writes `.skills-workspace/loop/plan.md` (and `.skills-workspace/loop/.stalemate` only to declare stalemate; do not call `$scripts_dir/loop-done.sh` for `.stalemate`). Review writes `.skills-workspace/loop/review.md`. **NEVER** fabricate the other side.
- Files are **OVERWRITTEN IN PLACE** — no `plan-v2.md`, no transcripts.
- Turns alternate by `loop-done.sh` (the publish event); no file lock. The other side polls for **COMMITTED** hashes, so live in-flight edits stay invisible until you publish.
- `.skills-workspace/loop/` is a single-cycle sandbox. Nothing user-authored lives there long-term; on approval the plan runs `$scripts_dir/loop-finalize.sh` to merge the approved plan back to its source path and wipe the sandbox.
