---
name: handoff
description: Use for an explicit handoff request — slash (`/handoff save|resume`) or a natural-language equivalent ("handoff save", "做个 handoff", "save 一下进度", "switch session", "pause and pick this up later"). Manages `<project>/.claude/handoff.md`, a thin pointer card so a fresh session can continue. Lightweight by design: it captures only what `git log` can't (the goal + the next steps); it does not re-narrate history.
argument-hint: save [note] | resume
disable-model-invocation: true
---

# handoff — Protocol

A handoff is a **thin pointer card**, not a movie-frame reconstruction. `git log` / `git status` already record what changed; the handoff captures only what they can't — the one-line goal and the concrete next steps. Keep it short.

## When to invoke

This skill owns every read/write of `<project>/.claude/handoff.md`. It runs only on an **explicit user request** (`disable-model-invocation: true` — never auto-fire on your own judgment):

- Slash command: `/handoff save|resume [args]`.
- Natural language whose intent is "freeze the current working state so a fresh session can pick up" — in any language, with or without the word "handoff" (e.g. "做个 handoff", "save 一下进度", "switch session", "pause and resume later"). For a bare trigger like "做个 handoff", default to **save**.

Dispatch on the first argument: `save` → save · `resume` → resume · empty/unrecognized → print Usage, write nothing.

### NEVER bypass with Write/Edit

When a trigger fires, run the protocol below — do not hand-roll `.claude/handoff.md` with `Write`/`Edit`, and never write the file directly outside this protocol. A bypassed file looks real but skips the format contract that keeps `resume` trustworthy.

## Where the file lives

Always `<project-root>/.claude/handoff.md`, absolute path. `<project-root>` is the session's **starting working directory** (the `Primary working directory:` line of the environment block) — never the shell's drifted cwd. Even if all work happened in a subdirectory, the file goes to project root; record the actual subdir in the `work-dir:` metadata field. (Single exception: the user's note explicitly directs another path.)

## Language consistency

All natural-language content written into handoff.md — title, section headings, prose — uses **the language the user has been using in this session** (a `永远用中文` / "respond in Japanese" instruction in CLAUDE.md wins; otherwise follow the user's recent turns; else English). Field names (`saved:`, `branch:`, `last:`, `work-dir:`), timestamps, paths, commit subjects, code identifiers, filenames, and commands stay verbatim. The English section names below (`## Next`, `## Status`) are schema — translate the wording, keep the structure.

## save

Write the current unfinished task's state to `<project-root>/.claude/handoff.md` (single file, overwrite). Reader = someone opening a fresh session to continue. Keep it thin.

1. **Directory** — if `<project-root>/.claude/` is missing, `mkdir -p` it (absolute path).

2. **Timestamp** — run `date -Iseconds` and use its stdout verbatim as `saved:`. Do NOT guess from the `currentDate` context line (day-resolution, often stale) — resume diffs this against a fresh clock to show "saved N minutes/hours ago", so a guessed value makes the delta meaningless.

3. **Git pointer** — if `<project-root>` is a git repo, capture (run with `-C <project-root>`): `git rev-parse --abbrev-ref HEAD`, `git log -1 --pretty=format:"%h %s"`. The handoff points at `git log` / `git status` for detail rather than copying it.

4. **Extract the two things git can't give** — from this conversation:
   - **Goal**: what the user originally wanted — quote their exact phrasing if you have it.
   - **Next steps**: the concrete immediate moves. What was the last instruction or the obvious next action? Each step is **imperative, verb-first, with a real artifact** (`file:line`, a command, or a precise question) — `Edit foo.rs:123 …`, `Run cargo test …`, `Ask the user whether …`. No vague verbs ("refactor X", "clean up Y"), no narration ("the user wants…", "we were trying…"), no invented umbrella terms not used in the actual conversation.

5. **Write** the file with this structure (heading levels exact — one `#` H1 title, `##` sections):

   ```
   # Handoff — <one-line goal>

   > saved: <ISO> · root: <project-root abs path> · work-dir: <subdir or =root> · branch: <branch or N/A> · last: <hash + subject, or N/A>

   ## Goal
   <one line; verbatim user quote of the task framing if available>

   ## Next
   1. <imperative step with file:line / command>
   2. …

   ## Status
   <1–3 lines: what this session changed + "see `git log` / `git status` for detail". Blockers, if any. Optionally one line for a still-open thread the user raised but didn't close.>
   ```

   Keep `## Next` concrete enough to act on cold. If the next move is genuinely undecided (a design choice is open), say so plainly in `## Next` — phrase it as the question to settle and list the candidate options actually discussed; don't manufacture a fake step.

6. **Tell the user** in two or three lines (don't restate the document):
   - **Written to** `<absolute path>`
   - One sentence naming the next move (or the open question)
   - **To switch sessions**: `/clear`, then run `/handoff resume` in the fresh session to continue.

## resume

Deliver the handoff, then **get out of the way**. resume restates; it does not start work and does not linger.

1. **Find first** — don't assume the project-root copy is newest:

   ```
   find <project-root> -maxdepth 4 -type f -path "*/.claude/handoff.md" -exec stat -f "%m %N" {} +
   ```

   Zero matches → "no handoff in this project — want to `/handoff save` now?", stop. One → read it. Multiple → read the newest by mtime and mention the others.

2. **Print the `## Goal` and `## Next` sections verbatim** — character-for-character, no paraphrase, no translation, no "improving". Those sections were written under the anti-summary rules in `save`; re-wording them here re-introduces the drift `save` worked to avoid.

3. **One short freshness line.** Run `date -Iseconds`, diff against the metadata `saved:`, and report the delta at natural resolution ("saved 7 minutes ago" / "saved 3 hours ago" / "⚠ saved 9 days ago — may be stale"). Never guess the delta. Add one line if the current branch diverges from the metadata. Nothing else — don't re-summarize Status.

4. **End the turn and yield to the user. This is the whole point of resume.**
   - Do **not** announce that you are "waiting", "ready", or holding for input.
   - Do **not** keep the turn alive with filler tool calls — **no filler**, no `echo`, no probing, no empty actions. Just stop, the way any normal answer ends.
   - Do **not** start executing the next step on the assumption the snapshot is still accurate — the repo may have moved. The user reads the restated handoff and types the next instruction when ready.

   > Why this rule exists: under Opus 4.8, an earlier resume contract told the model to wait idly for the user while keeping the turn open. The model read that as "do nothing but stay in the loop", concluded a turn still needed a tool call, and emitted filler `echo "checking"` / `echo "still working"` calls to avoid an empty turn — burning tokens for no work. The cure is a clean turn-end: print, give the freshness line, stop. Never reintroduce a keep-waiting-in-the-loop instruction here.

## Boundary: handoff vs memory

Handoff = **transient state** of an unfinished task, overwritten/deleted when done. Memory = **enduring facts/preferences** across conversations. Don't smuggle ephemeral task state into memory just because you're writing a handoff.

## Usage

```
/handoff save [note]   write a thin pointer card to <project>/.claude/handoff.md
/handoff resume        find + restate Goal/Next verbatim, then end the turn
```
To switch sessions: `/handoff save`, then `/clear`, then `/handoff resume` in the fresh session.
