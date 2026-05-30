# handoff

Save and resume a thin handoff document for the current project so a new session can pick up where you stopped. Lightweight by design — it captures only what `git log` can't (the goal + the next steps), it does not re-narrate history.

/handoff save [note] — write `<project>/.claude/handoff.md`: a thin pointer card (one-line goal, concrete next steps, a short status that points at `git log` / `git status`).

/handoff resume — locate the newest handoff.md, restate the Goal/Next sections verbatim, report freshness, then end the turn and hand back to you.

To switch sessions: `/handoff save`, then `/clear`, then `/handoff resume` in the fresh session.

## Design

- **交 > 接**: a handoff hands over the next step, it doesn't summarize the past.
- **Thin pointer card**: `git log` / `git status` already record what changed; the handoff stores only the goal and the next steps. No history re-narration.
- **Clean turn-end on resume**: resume restates and stops — it never enters a wait-in-the-loop limbo, never emits filler tool calls. (That limbo made Opus 4.8 spam `echo` probes to keep the turn alive.)
- **User-invoked only**: `disable-model-invocation: true` — the skill fires on your explicit request, never on the model's own judgment.
- **Project-root anchored**: handoff.md always lives at project root, never a drifted cwd.

## Changelog

- **0.4.3** — write handoff.md in the user's session language (title, headings, body) instead of always English.
- **0.4.2** — resume reads `mode:` from metadata instead of grepping translated Mode label text.
- **0.4.1** — `mode:` metadata field added as language-agnostic anchor for resume.
- **0.4.0** — Mode A / Mode B split; resume branches on mode; Texture section added.
- **0.3.x** — active-extract rules, project-root anchoring, eval subagent audit.
