---
name: handoff
description: Use for an explicit handoff request — slash (`/handoff save|resume`) or a natural-language equivalent ("handoff save", "做个 handoff", "save 一下进度", "switch session", "pause and pick this up later"). save lands the unfinished work's plan in the project's planning area and writes a thin `<project>/.claude/handoff.md` pointer; resume follows the pointer to where the work is written and how to pick up. Lightweight by design — the plan file and `git log` hold the detail, handoff.md is just the pointer.
argument-hint: save [note] | resume
disable-model-invocation: true
---

# handoff — Protocol

A handoff is a **thin pointer**, not a document dump. The real state of unfinished work already lives in two places: the project's **plan files** (a planning area under `.claude/`, if the project keeps one) and **`git log` / `git status`**. So `save`'s main job is to land the plan where it belongs; `handoff.md` is just a thin card pointing at it — *where the work is written, how far it got, how to pick up*. With the card, resume is smoother; without it, the plan file + git log still carry the work. That is the "有了更顺滑，没有也行" contract.

## When to invoke

This skill owns every read/write of `<project>/.claude/handoff.md`. It runs only on an **explicit user request** (`disable-model-invocation: true` — never auto-fire on your own judgment):

- Slash command: `/handoff save|resume [args]`.
- Natural language whose intent is "freeze the current working state so a fresh session can pick up" — any language, with or without the word "handoff" (e.g. "做个 handoff", "save 一下进度", "switch session", "pause and resume later"). For a bare trigger, default to **save**.

Dispatch on the first argument: `save` → save · `resume` → resume · empty/unrecognized → print Usage, write nothing.

## The planning area (how save knows where to land the plan)

`save` does **not** hard-code any single planning method. It locates the project's planning area in this priority order:

1. **Project convention** — if the project's `CLAUDE.md` (or a memory) describes where plans are kept and how they're chosen, follow that exactly. This is the consumer hook: a project's own planning method (whatever it is) plugs in here, and this skill defers to it.
2. **Probe common dirs** — otherwise look under `<project-root>/.claude/` for a planning area: `rfcs/`, `tasks/`, `plans/`, `specs/`. Use the one that exists; if several do, pick by the project convention from step 1, else ask the user.
3. **No planning area** — if none exists and the project keeps no plan files, there is no plan file to update; the next steps go **inline** in handoff.md (the degraded, still-useful form).

This skill never dictates the *internal structure* of a plan file, nor how to choose between (say) an RFC dir and a dated task dir — those belong to the project's method, not to this plugin. It only needs the plan file to answer two things: **how far the work got** and **what the next step is**.

> Note on Write/Edit: plan files are ordinary work artifacts — create and edit them with `Write`/`Edit` as normal. The one file you must **not** hand-roll outside this protocol is `handoff.md` itself; its pointer format is what keeps `resume` trustworthy.

## Where handoff.md lives

Always `<project-root>/.claude/handoff.md`, absolute path. `<project-root>` is the session's **starting working directory** (the `Primary working directory:` line of the environment block) — never the shell's drifted cwd. (Single exception: the user's note explicitly directs another path.)

## Language consistency

Natural-language content in handoff.md and in any plan file you write uses **the language the user has been using this session** (a `永远用中文` / "respond in Japanese" directive in CLAUDE.md wins; else follow recent user turns; else English). Field names (`saved:`, `branch:`, `last:`), timestamps, paths, commit subjects, code identifiers, and commands stay verbatim. The English section names below (`## Plan`, `## Next`) are schema — translate the wording, keep the structure.

## save

`save`'s main job is **landing the plan**, not writing prose. Two outputs, in this order: (1) update/create the plan file in the planning area; (2) write a thin handoff.md pointer to it.

1. **Timestamp** — run `date -Iseconds`, use its stdout verbatim as `saved:`. Don't guess from the `currentDate` context line (day-resolution, stale) — resume diffs this against a fresh clock.

2. **Git pointer** — if `<project-root>` is a git repo: `git -C <project-root> rev-parse --abbrev-ref HEAD` and `git -C <project-root> log -1 --pretty=format:"%h %s"`. The handoff points at `git log` / `git status` for detail rather than copying it.

3. **Land the plan (the important step).** Locate the planning area (see above), then:
   - **Active plan file exists** → update it: advance its "how far it got" (status) and its "next step", in the project's own structure. This is where the unfinished work is recorded.
   - **No plan file yet, work is unfinished** → create one in the planning area, following the project convention for path and shape. If the project gives no convention, pick a sensible path under the existing planning dir and tell the user where you put it.
   - **No planning area / small one-off** → skip the plan file; the next steps live inline in handoff.md instead.
   Keep what you write concrete: file:line, command, or a precise question — never vague verbs ("refactor X"), never narration ("the user wants…"), never invented umbrella terms not used in the actual session. Don't copy what `git log` already says.

4. **Write the thin handoff.md pointer** (heading levels exact — one `#` H1, `##` sections):

   ```
   # Handoff — <one-line goal>

   > saved: <ISO> · root: <project-root abs path> · branch: <branch or N/A> · last: <hash + subject, or N/A>

   ## Plan
   <relative path to the active plan file, e.g. .claude/rfcs/<slug>/plan.md — or "none: next steps inline below">

   ## Next
   <one imperative line: how to pick up — point into the plan file's step ("see Plan §Next, step 2"), or an inline step if there is no plan file>
   ```

   This is the whole card. The "how far it got" detail is *not* duplicated here — it lives in the plan file and `git log`; the pointer just says where.

5. **Tell the user** in two or three lines (don't restate anything):
   - **Plan** updated/created at `<path>` *(or "no plan file — next steps inline")*
   - **Handoff** at `<absolute path>` — one sentence naming the next move
   - **To switch sessions**: `/clear`, then `/handoff resume` in the fresh session.

## resume

Deliver the pointer, then **get out of the way**. resume restates where the work is and how to pick up; it does not start work and does not linger.

1. **Find handoff.md first** — don't assume the project-root copy is newest:

   ```
   find <project-root> -maxdepth 4 -type f -path "*/.claude/handoff.md" -exec stat -f "%m %N" {} +
   ```

   Multiple → newest by mtime, mention the others.

2. **Follow the pointer.**
   - **handoff.md found** → print its `## Plan` and `## Next` **verbatim** (character-for-character, no paraphrase, no translation). Then, if `## Plan` names a plan file, open it and surface — verbatim — its "how far it got" and "next" sections, so the user sees *done so far / where it's recorded / how to continue*. Don't summarize; the plan file was written to be read directly.
   - **No handoff.md** → degrade gracefully: probe the planning area for the most recent plan file (and/or `git log`), and report where the work stands. Say plainly there was no handoff card, so you're reconstructing from the plan file + git.

3. **One short freshness line.** Run `date -Iseconds`, diff against the metadata `saved:`, report at natural resolution ("saved 7 minutes ago" / "saved 3 hours ago" / "⚠ saved 9 days ago — may be stale"). Never guess. Add one line if the current branch diverges from the metadata. Nothing else.

4. **End the turn and yield to the user. This is the whole point of resume.**
   - Do **not** announce that you are "waiting", "ready", or holding for input.
   - Do **not** keep the turn alive with filler tool calls — **no filler**, no `echo`, no probing, no empty actions. Just stop, the way any normal answer ends.
   - Do **not** start executing the next step on the assumption the snapshot is still accurate — the repo may have moved. The user reads the restated pointer and types the next instruction when ready.

   > Why this rule exists: an earlier resume contract told the model to wait idly for the user while keeping the turn open. The model read that as "do nothing but stay in the loop", concluded a turn still needed a tool call, and emitted filler `echo` calls to avoid an empty turn — burning tokens for no work. The cure is a clean turn-end: print, give the freshness line, stop. Never reintroduce a keep-waiting-in-the-loop instruction here.

## Boundary: handoff vs memory

Handoff (and the plan file) = **transient state** of an unfinished task, overwritten/deleted when done. Memory = **enduring facts/preferences** across conversations. Don't smuggle ephemeral task state into memory just because you're writing a handoff.

## Usage

```
/handoff save [note]   land the plan in the planning area + write a thin .claude/handoff.md pointer
/handoff resume        follow the pointer: restate where the work is + how to pick up, then end the turn
```
To switch sessions: `/handoff save`, then `/clear`, then `/handoff resume` in the fresh session.
