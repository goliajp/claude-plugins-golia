# handoff

Save and resume a project handoff so a new session can pick up where you stopped. Lightweight by design: `save` lands the unfinished work's **plan** in the project's planning area, and writes a thin `<project>/.claude/handoff.md` **pointer** to it; `resume` follows the pointer to where the work is written and how to continue.

/handoff save [note] — locate the project's planning area (`.claude/rfcs|tasks|plans|specs`, or whatever the project's CLAUDE.md defines), update/create the plan file there, then write a thin handoff.md pointing at it + the next step.

/handoff resume — find the newest handoff.md, restate its `## Plan` / `## Next` verbatim, follow the pointer into the plan file (how far it got / how to pick up), report freshness, then end the turn.

To switch sessions: `/handoff save`, then `/clear`, then `/handoff resume` in the fresh session.

## Design

- **交 > 接**: a handoff hands over the next step, it doesn't summarize the past.
- **Plan lives in the planning area; handoff.md is just a pointer.** The unfinished work is recorded in the project's own plan files (`.claude/rfcs|tasks|...`) and in `git log` / `git status`. handoff.md only points there — *where it's written, how far it got, how to pick up*. With the pointer resume is smoother; without it the plan file + git still carry the work.
- **Generic, not a method.** The plugin probes common planning dirs and defers to the project's `CLAUDE.md` for *which* dir and *what* internal structure. It hard-codes no planning methodology — works for any project, falls back to inline next-steps when a project keeps no plan files.
- **Clean turn-end on resume**: resume restates and stops — never a wait-in-the-loop limbo, never filler tool calls. (That limbo made Opus 4.8 spam `echo` probes to keep the turn alive.)
- **User-invoked only**: `disable-model-invocation: true` — fires on your explicit request, never on the model's own judgment.
- **Project-root anchored**: handoff.md always lives at project root, never a drifted cwd.

## Changelog

- **unreleased** — pointer redesign. `save`'s main job becomes *landing the plan* in the project's planning area (probes `.claude/rfcs|tasks|plans|specs`, defers to project `CLAUDE.md` for choice + structure — no methodology hard-coded, per the marketplace's plugin-boundary rule); handoff.md shrinks to a thin pointer (`## Plan` path + `## Next`). resume follows the pointer into the plan file. Degrades to inline next-steps when a project keeps no plan files.
- **0.5.0 (prior local rework)** — lightweight save/resume: cut model-invoke / Mode A·B / eval / Texture; `disable-model-invocation`; resume ends the turn cleanly instead of "stand by and wait" (fixes the Opus 4.8 echo-probing).
- **0.4.3** — write handoff.md in the user's session language.
- **0.4.2** — resume reads `mode:` from metadata instead of grepping translated label text.
- **0.4.0** — Mode A / Mode B split; Texture section.
- **0.3.x** — active-extract rules, project-root anchoring, eval subagent audit.
