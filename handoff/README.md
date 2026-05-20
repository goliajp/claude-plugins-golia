# handoff

Save and resume a dense **handoff document** for the current project — so a new session, another machine, or another day can pick up exactly where you stopped.

Different from `claude --resume`: that one replays the whole prior conversation. `/handoff` writes a deliberate briefing for a *fresh-context* session — denser, structured, and meant to be paired with `/clear`.

## What it does

- **`/handoff save [note]`** — actively extracts Goal / Done / In progress / Blocked / Next / **Texture** (half-open conversational threads) / Rejected paths / Decisions / Environment from this session, writes `<project>/.claude/handoff.md` (single file, overwrite).
- **`/handoff resume`** — finds the newest handoff (defends against cwd-drift saves), restates context in plain prose, **waits** for your confirmation before doing any work.
- **`/handoff clear`** — runs save, then prints a minimal two-step instruction: `/clear`, then `/handoff resume`. (The harness cannot chain those itself; you type them.)

## Why `Texture`

The default skill output tends toward "what was done" — a closed-shape list. The **Texture** section deliberately preserves *unfinished* conversational threads: the user's exact words, the implicit assumptions, "what was about to be discussed", "interrupted by". This is what makes resume feel like a continuation rather than a fresh start. Easy to phone in; required by the protocol.

## Install

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install handoff@golia
```

### Development install (local checkout)

To hack on this skill or test changes locally — local-path installs hot-reload, so `SKILL.md` edits land on the next session without `claude plugin update`:

```
git clone https://github.com/goliajp/claude-plugins-golia.git
claude plugin marketplace add ./claude-plugins-golia
claude plugin install handoff@golia
```

## Update

```
claude plugin marketplace update golia
claude plugin update handoff
```

## Uninstall

```
claude plugin uninstall handoff
```

The state file (`<project>/.claude/handoff.md`) is intentionally **not** removed on uninstall — remove by hand if you want a clean slate.

## Where the file lives

`<project-root>/.claude/handoff.md`. The protocol anchors on the session's `Primary working directory:`, not shell cwd, to defend against a real failure mode where a long-running session that worked in a subdirectory wrote the handoff into the subdir and then `resume` in a fresh session read the stale root copy.

## Notes

- `save` can be invoked by you (via `/handoff save …`) **or** by Claude itself at a deliberate checkpoint moment (see SKILL.md `## When the model invokes`). When Claude does it, you'll see a one-line "Saved a checkpoint at … — reason: …" — overrule freely if the timing was off.
- `resume` and `clear` remain user-driven — Claude won't trigger them on its own.
- `eval` is a read-only quality check — runs an isolated subagent that reads your handoff.md cold (no other context). Use it before `/clear` to catch save gaps, or to debug a confused resume. Writes nothing.
- No hooks. Slash-command + optional model-initiated save.
- No plugin-side data file. State lives in the project, not in the plugin directory — `claude plugin update` is safe.

## Changelog

- **0.3.0** — add `/handoff eval [path]`, a read-only audit verb that exists to protect save/resume quality. Spawns an isolated subagent that reads handoff.md with no other context and writes a brief cold-read for the user to compare against their actual mental model. Two usage scenarios: catch save gaps before `/clear`, or localize fault when a resume goes wrong. Writes nothing.
- **0.2.0** — model can now invoke `save` directly at deliberate checkpoint moments (removed `disable-model-invocation: true`); new `## After resume — working rules` section forbids path extrapolation from the skill's base directory (caused a real cold-start failure in a sentori session); new `## When the model invokes` section makes the criteria explicit and forbids `Write`/`Edit` bypass.
- **0.1.0** — initial public release. Extracted from the in-house handoff skill.
