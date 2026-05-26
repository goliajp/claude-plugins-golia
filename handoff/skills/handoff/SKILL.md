---
name: handoff
description: Save / resume / clear a working handoff document for the current project — a dense briefing so a new session (or another machine, another day) can pick up where you stopped. `/handoff save [note]` writes `<project>/.claude/handoff.md`; `/handoff resume` reads it and restates context; `/handoff clear` saves then prompts the user to /clear + resume. Different from `claude --resume`, which replays full conversation history.
argument-hint: save [note] | resume | clear | eval [path]
---

# handoff — Protocol

Read the first word of `$ARGUMENTS` and branch:

- `save` (optional note follows) → run **save**
- `resume` → run **resume**
- `clear` → run **clear** (= save + prompt user to /clear + /handoff resume)
- `eval` (optional path follows) → run **eval**
- anything else (including empty) → print the **Usage** block at the bottom. Write nothing.

## Design principle: 交 > 接 (handoff > summary)

A handoff's core verb is **交** (hand over) — not **总结** (summarize). "交" means: hand the next step, in concrete form, to a fresh session. "总结" means: review what got done, what was decided, what was produced — necessary, but never the headline.

The reader of `/handoff resume` wants to know **where to go next**, not what happened in the past. Every writing rule in this skill is engineered so the handed-over document is as high-fidelity as it would be if no session-switch happened at all.

**Failure mode this protocol prevents**: save degenerates into a quality-poor summary — abstract verbs ("refactor X"), invented umbrella terms not present in the original conversation, third-person narration ("the user wants…", "we were trying…"). Once such a summary is written, **the hallucinations are baked in** — resume reads a corrupted contract and amplifies it. The fix lives on the save side, not the resume side: write Handoff content under the strict rules below.

## Boundary: handoff vs memory

Handoff captures **transient state** of an unfinished task — overwritten or deleted when the task is done. Memory captures **enduring facts / preferences** that survive across conversations. Do not smuggle ephemeral task state into memory just because you happen to be writing a handoff.

## Where the file lives (applies to save AND resume)

Anchor on the Claude Code session's **starting working directory** — i.e. the absolute path on the `Primary working directory:` line of the environment block. Call this `<project-root>`. Do NOT use the shell's current cwd, which may have drifted via `cd <subdir> && …` during the session.

Always write/read `<project-root>/.claude/handoff.md` with an absolute path. **Never** infer the path from shell cwd, even if the entire session worked inside a subdirectory.

**Why this matters — a real past failure:** a session worked for hours inside `<project>/<subproject>/`, save wrote to `<project>/<subproject>/.claude/handoff.md`, next session's resume read `<project>/.claude/handoff.md` (the project-root one — stale, from days earlier) and thought THAT was the latest. The newer handoff was buried in the subdirectory. So: **handoff.md always lives at project root**, regardless of where the work happened. Capture the actual work subdirectory in metadata's `work-dir:` field.

Single exception: if the user's `save` note explicitly directs another path (e.g. "save to ./foo/.claude/", "store at mars"), follow the user's directive.

## save

Write the **current unfinished task**'s transient state to `<project-root>/.claude/handoff.md` (single file, overwrite). The reader is "someone opening a new session to continue from here" — write so they can pick up cold, without leaning on this conversation's implicit context.

**Core rule — actively extract, don't slack off:**

Even if the user gave no note, even if there's no git repo, even if the session didn't use TaskList — extract material from **this very conversation** as completely as possible. A section may say "none" only when you genuinely searched and found nothing, and the wording should make that clear (e.g. "none: this session did not touch X"). **Do not write "none" in every section just because no source actively fed you data.**

The goal: resume reads like one frame of a paused movie with the picture intact — not an empty index.

### 1. Prepare directory

If `<project-root>/.claude/` doesn't exist, `mkdir -p <project-root>/.claude` (absolute path, no shell-cwd dependency).

### 2. Decide Mode A vs Mode B (the very first writing decision)

Before extracting anything, decide which mode this save is in. The whole `## Handoff` section's shape depends on this.

- **Mode A — path defined**: the next step is known. There is a concrete tasklist / edit / command sequence the new session should execute. The pickup contract is: *new session reads, restates, and waits for the user's go-ahead.*
- **Mode B — path open**: the next step is **not yet decided**. Multiple candidate directions, design trade-offs unresolved, waiting on a user decision. The pickup contract is: *new session reads, then talks with the user about the choice — does not pick a path on its own.*

No ambiguity allowed. "Mostly clear with one open question" is **Mode A** with the open question flagged in-line. **Mode B is reserved for "the main line is undecided"** — the whole thing cannot just be executed.

Why this is forced: the failure mode is "Handoff section that's vague enough to be either, so the new session guesses". Pinning Mode A or B at save time forces concreteness on the save side and gives the resume side a clean two-branch pickup contract.

### 3. Extract material (gather BEFORE writing)

a. **Code layer** — only when `<project-root>` is a git repo (`git -C <project-root> rev-parse --is-inside-work-tree`), gather in parallel (always with `-C <project-root>`):
   - `git -C <project-root> rev-parse --abbrev-ref HEAD`
   - `git -C <project-root> log -1 --pretty=format:"%h %s"`
   - `git -C <project-root> status --short`
   - `git -C <project-root> diff --stat`

   If the actual work happened in a nested sub-repo (e.g. `<project>/<subproject>/`), gather git info from the sub-repo and note the subpath in metadata. The handoff.md still lives at the outer project root.

b. **Task layer** — if the session used TaskList / TodoWrite, copy in-progress and pending items verbatim into the `## Handoff` step list (Mode A) or `## Status` (Mode B) — least effort, highest fidelity.

c. **Conversation layer** (most critical — **never skip**) — review this session's context and ask yourself:
   - What did the user originally want? **Find their exact phrasing.** (→ "Goal", use quotes)
   - **What is the immediate next move?** What was the last concrete instruction or implicit next step? What did the user **last say** about "what to do next"? (→ "Handoff", Mode A or B)
   - What files were changed, what commands run, what tools used? (→ "Status / Done")
   - What were the **last one or two turns** doing? Any unfinished edits, unrun tests, half-finished searches? (→ "Status / In progress")
   - What are you blocked on — an error, waiting for a user decision, an external dependency? (→ "Status / Blocked")
   - What approaches did you **try and reject**, and why? Even one entry beats zero (→ "Rejected paths")
   - What design/selection decisions did you make, what alternatives were weighed? (→ "Decisions")
   - **Are there half-finished topics the user raised but didn't close?** What were the **exact words**? What's the implicit assumption? How does this connect to prior context? What was about to be discussed? What cut it off? (→ "Texture" — **the cure for recall gaps**, easiest to phone in, NEVER skip)

   Ground each extraction in concrete artifacts: file:line, command, error message verbatim. Don't write "tweaked the logic" — that's compressed past usefulness.

### 4. Write the file

**Heading-level self-check before Write** (defends against cwd drift):

1. `file_path` starts with `/` (absolute path)
2. `file_path` equals exactly `<value of 'Primary working directory:'>` + `/.claude/handoff.md`, character-for-character
3. **Do NOT** splice in any subdirectory you happened to work in — handoff.md ALWAYS goes to project root; capture the subdirectory in `work-dir:` metadata

If shell cwd has drifted into a subdir (look back at Bash history for `cd <subdir>`), be extra alert: write the project-root absolute path explicitly, never let any implicit cwd into the file_path.

Use Write to create `<project-root>/.claude/handoff.md` (absolute path) with this heading structure (note heading levels — the title MUST be `#` H1, all sections are `##` H2; do not downgrade the title to H2 just because the body has many H2 sections):

   - `# Handoff — <one-line goal>` (single H1 at the top; use the user's `save` note if provided; otherwise synthesize one from the extracted goal — don't write "untitled")
   - One blockquote-style metadata line: `saved: <ISO timestamp> · root: <project-root absolute path> · work-dir: <subdir actually worked in, or same as root> · branch: <branch or N/A> · last: <commit hash + msg, or N/A>`
   - `## Goal` — one paragraph stating the done-criteria. **Include a verbatim quote of how the user originally framed the task**, in `"..."`, if you have it. Don't replace the user's framing with your own paraphrase.
   - **`## Handoff`** — *the headline section, immediately after Goal.* Mode A or Mode B format (see "## Handoff section formats" below). This is **what the new session reads first** — it carries the entire "交" payload.
   - `## Status` — three bold sub-sections: **Done** / **In progress** / **Blocked**. Each item carries evidence: file:line, command, output snippet. This is supporting material for the Handoff, not a substitute.
   - `## Texture` — (**this section cures recall gaps; opposite style from the others**) capture the **unfinished conversational fabric**: half-finished topics, ideas still cooking, directions still under consideration. Allow it to be **messy, first-person, verbatim-faithful** — this is not for conclusions, it's for "what was the thread of thought and where did it stop". Each entry:
     - **User's exact words** (in `"..."` quotes; if a multi-turn exchange, paste the relevant lines in order — don't paraphrase)
     - **Connects to**: which prior thread / earlier session this picks up; what's the subtext
     - **Implicit assumption** (prefix with `**guess:**` — needs user confirmation)
     - **What's not said yet** — clearly unfinished; what would the user likely expand on next
     - **Interrupted by**: what cut it off, what was the user's last sentence
     Boundary: **rejected** directions go to "Rejected paths" (closed); **still-considering** directions go here (half-open). If the session has zero half-open topics (all closed technical work), write one line "no half-open topics: session was all closed tasks" and skip — but don't skip out of laziness.
   - `## Rejected paths` — failed approaches + why they failed. Easiest to omit, highest value: forgetting failures costs more than forgetting successes.
   - `## Decisions` — what was chosen, what was rejected, why. Lets the new session not re-litigate settled direction.
   - `## Environment snapshot` — git info from step 3a, in a code block.

### 5. `## Handoff` section formats

Two formats. Pick one based on the Mode you decided in step 2. Don't mix.

#### Mode A — path defined

First line, literally: `**Mode A — path defined.**` followed by **one short sentence** naming the next move.

Then a numbered step list, **strict rules**:

```
1. Edit foo.rs:123 — replace `bar(a)` with `baz(a, ctx)` so that callers thread the context.
   Verify: `cargo test foo::bar_calls_baz` passes.
2. Run `cargo build --workspace`. Confirm no new warnings beyond the existing `unused_imports` in bar.rs:45.
3. Commit with message: "refactor(foo): thread ctx through bar→baz".
```

Strict rules for every step:

- **Imperative form. Verb first.** `Edit …`, `Run …`, `Add …`, `Remove …`, `Investigate …`, `Confirm with user …`, `Open …`. Forbidden: `"the user wants …"`, `"we were trying to …"`, `"the next thing is to …"`, `"the goal is to …"` — these are narrative-style summary, not a handoff instruction.
- **Concrete artifacts.** Every step names a file:line, a shell command, or a precise question. Forbidden abstract verbs: `"refactor X"`, `"clean up Y"`, `"improve Z"`, `"finish the work on …"` — too vague to execute cold.
- **No new terms.** Use the exact names (files, variables, concepts) that appeared in this session. **Do not invent** umbrella terms or paraphrased labels. If you feel a noun needs to be summarized, go find what the user / code called it and copy that verbatim. (This is the single biggest source of "handoff hallucination": save-time concept-reification.)
- **Verify line.** Each step that mutates state ends with a `Verify: <command>` or `Verify: <observable>` so the executor knows when the step is done.

End the Mode A section with one line, literally:

`Pickup signal: Restate complete, then stand by — execute step 1 only after the user gives the go-ahead.`

#### Mode B — path open

First line, literally: `**Mode B — path open.**` followed by **one short sentence** naming the open question.

Then the decision material — four required sub-blocks:

```
### Open question
> <user's exact words framing the open question, in a blockquote — verbatim, no paraphrase>

### Candidates
- Option 1: <name>. <one-line description>. Known constraint: <…>.
- Option 2: <name>. <one-line description>. Known constraint: <…>.
- Option 3: …

### What we know
- <constraint / confirmed fact / user's stated preference — quote when possible>

### What we don't know
- <the specific point that needs a user decision>
- <another open point>
```

Strict rules:

- **Verbatim user quotes** in "Open question" and "What we know" wherever possible. Same anti-invention rule as Mode A.
- **Candidates must be ones that were actually surfaced in this session.** Don't manufacture candidate options to "look balanced" — if only one was discussed, list one and say so.
- **No leading recommendation.** Save-time does not pick the path for Mode B; that's exactly what resume is supposed to hand back to the user.

End the Mode B section with one line, literally:

`Pickup signal: Discuss the open question with the user first — do not pick a path or start work autonomously.`

### 6. Post-write self-check (run on the `## Handoff` section)

After writing, re-read the `## Handoff` section and pass three checks. If any fails, revise and re-Write.

1. **Cold-read test** — could a session with zero prior context act on this directly? If a step says "refactor X", "clean up Y", "improve Z" — fail. Rewrite into a specific file:line / command / question.
2. **New-term test** — does any noun appear here that did **not** appear in this session's actual conversation? If yes, it's concept-reification — go find the original wording and replace.
3. **Imperative test** — does every Mode A step start with a verb? Did any sentence slip into `"the user wants …"` / `"we plan to …"` / `"the goal is …"` narration? If yes, rewrite as imperative.

### 7. Tell the user

Tell the user explicitly with three points (don't restate the full document):

   - **Written to** `<absolute path>` — **Mode A** *(or **Mode B**)*
   - One sentence naming the next move (Mode A) **or** the open question (Mode B)
   - **Run `/handoff resume` in a new session to continue**

   The point: the user should see "saved + which mode + how to pick back up" at a glance and feel safe switching sessions. The Mode label also lets them sanity-check the categorization — if you wrote Mode A but they think it's really Mode B (or vice versa), they can override now while context is still hot.

   Note: if arriving here via `clear` (not direct `/handoff save`), follow the `clear` section's format instead — don't duplicate this.

## resume

The resume verb's job is to **deliver the "交"**, not to summarize the past. Show the user the Handoff section as written, then add only the minimum surrounding context. Never paraphrase the Handoff section — paraphrasing is precisely where save-time hallucinations get amplified.

1. **Always `find` first** — don't assume the project-root copy is the newest. Save may have drifted to a subdir, making the root copy stale (see the failure case at top):

   ```
   find <project-root> -maxdepth 4 -type f -path "*/.claude/handoff.md" -exec stat -f "%m %N" {} +
   ```

   (`%m` = mtime epoch — easy to compare.) Branch on result:

   - **Zero matches** → say "no handoff in this project — want to `/handoff save` now?", stop
   - **One match** → read it
   - **Multiple matches** → read the newest by mtime, **mention in the freshness line below**: "found another handoff at `<other path>` (mtime X); using the newest at `<chosen path>`. Let me know if the older one should be cleaned up."

2. **Print the `## Handoff` section verbatim.** Extract the lines from `## Handoff` up to (but not including) the next `##` heading, and reproduce them **character-for-character** in your reply — including the `**Mode A — path defined.**` / `**Mode B — path open.**` opener, every numbered step / sub-block, and the `Pickup signal:` line. Do **not** paraphrase. Do **not** "improve" the wording. Do **not** drop steps you think are obvious. Do **not** add commentary inside it.

   Why verbatim: the Handoff section was written under save-time anti-summary rules. Re-paraphrasing it here would re-introduce exactly the hallucination class save was trying to prevent (invented terms, narrative drift, lost specificity).

3. **One short freshness-and-terrain block** after the verbatim print. In your own words, two or three lines max, covering only:
   - `saved <N days/hours> ago` (from metadata). If >7 days, **flag prominently**: "⚠ N days old — may be stale."
   - Branch / repo state if it diverges from the handoff's metadata (e.g. handoff said `branch: feature/foo`, current branch is `develop` → mention it).
   - If multiple handoffs were found, the "other handoff at …" line from step 1.

   **Do NOT** add a "summary of where we were", **do NOT** restate Status / Texture / Decisions, **do NOT** "shall we do step 1 now?" — the verbatim Handoff already carries the contract.

4. **Pickup signal — branch on Mode**:

   - If the section was **Mode A**: tell the user you're standing by to execute step 1 and waiting for their go-ahead. Then stop.
   - If the section was **Mode B**: tell the user you need to talk through the open question first before any work starts. Then stop. **Do not propose which candidate to pick.**

   Phrase these in whatever language the user has been using in this session — the contract is "stand by for go-ahead" (Mode A) or "discuss before acting" (Mode B); the exact wording is the model's call.

5. **Stop and wait for the user.** Do NOT proceed into actual work on the assumption that the handoff is still accurate. A handoff is a snapshot; the repo may have moved (others committed, deps changed, files renamed). Calibrate before acting — same principle as "verify before trusting memory".

## After resume — working rules

These rules apply throughout the resumed session, not just during restate. They prevent the cold-start failure mode where Claude grabs whatever path is closest in its context (typically the skill's own base directory) and extrapolates user workspace structure from it.

**Anti-path-extrapolation guard**: any project name or path word newly appearing in this resumed session — i.e. not explicitly listed inside the handoff.md you just read — MUST be verified with `ls` or `find` before use (passing to a subagent, opening, citing, telling the user it exists at X). Do NOT extrapolate from:

- **The skill's own base directory** (`Base directory for this skill: ...` system prompt). That path is the **plugin installation location**, not the user's workspace root. Its parent directory is NOT "user workspace". Never use the skill's location as an anchor for guessing where the user's other projects live.
- **Memory file paths** (`~/.claude-profile-N/projects/...`). Same reasoning — that's Claude Code internal state.
- **Your general expectation** of "how workspaces are usually laid out". Different users organize differently; never assume.

If the user mentions a project by name without giving its path, either ask, or run a verification command yourself:

```bash
find ~/workspace -maxdepth 4 -type d -name <project-name>
```

Use the result. If multiple matches, ask which one. If zero matches, tell the user the project isn't where you expected — don't proceed by guessing.

**Why this rule exists**: a real past failure (sentori session, 2026-05-20). In a cold-start resume, the user mentioned "tasks 项目", Claude grabbed the handoff skill's base directory `.../claude-plugins-golia/handoff/skills/handoff` as anchor, extrapolated `claude-plugins-golia/tasks` as the project location, fed that to an Explore subagent, agent reported "not found", Claude relayed "no such project" to the user. Real path was in a completely different parent directory. One `find` would have caught it.

## clear

`/handoff clear`'s goal is **smooth context switching**: save current progress → clear current session → read the handoff back in a clean context.

**Claude Code harness constraint**: a skill running in Claude's current turn **cannot** trigger `/clear` itself — `/clear` is a harness built-in, not exposed to skills/hooks/tools. Keybindings also can't chain multiple slash commands into a single key. So this final step must be typed by the user; no truly one-key version exists.

What `/handoff clear` actually does:

1. **Run the full save flow** — per the "actively extract" rule above; don't slack off.

2. **Print a minimal handoff instruction** — only show the user the next keystrokes:

   ```
   Handoff written to <absolute path>
   Next two steps: /clear to wipe, then /handoff resume to continue.
   ```

   **Do NOT** restate the document, **do NOT** list anything long, **do NOT** ask "shall we do this step now" — give a direct two-step instruction.

3. **Do NOT accept `/handoff clear <note>`** — notes belong on `/handoff save <note>`. `clear` is the no-brainer switching path; no args.

If the user doesn't actually type `/clear` next and instead asks something else, answer normally — don't nag.

## eval

Read-only audit of an existing handoff.md. Exists to **protect save/resume quality** — not a feature in its own right. Two usage scenarios:

- **After a save, before `/clear`** — confirm the snapshot captures enough. If gaps surface, supplement now while the original context is still alive.
- **When a resume goes wrong** — localize fault: is the handoff itself shallow, or is `resume` mis-reading a faithful handoff?

### Protocol

1. Find handoff.md using the same logic as `## resume` step 1 (`find <project-root> -maxdepth 4 -type f -path "*/.claude/handoff.md"`). If the user passed an explicit path argument, use that instead. Multi-match → newest by mtime. Zero match → tell the user "no handoff to evaluate" and stop.

2. Spawn a subagent via the Task tool with `subagent_type: general-purpose`. Pass the handoff.md **absolute path**. Use this prompt and **nothing else** — no this-session context, no extra hints, no leading framing:

   > Read the file at `<absolute path>` as your only source. Write 3-5 sentences describing what was happening, what's pending, and what's still uncertain. Don't propose next steps. Don't say "shall we". Just describe what you'd think reading this cold.

3. Present the subagent's output **verbatim**, prefixed by one line:

   > Cold-read of `<absolute path>`:

4. Stop. Do NOT add your own analysis. Do NOT ask "is this right?". The user reads, decides whether the handoff captured enough, and acts on that judgment themselves.

**Writes nothing. Modifies nothing.** No changes to handoff.md, no changes to session state.

## When the model invokes

`save` may be invoked by the model directly (this skill no longer carries the `disable-model-invocation` flag). Use this when you, the model, judge a **deliberate checkpoint moment** — typically one of:

- Just finished a self-contained piece of work and about to enter a risky action (irreversible operation, multi-file refactor, etc.)
- About to switch context (topic jump, task wrap-up, new investigation thread)
- User signaled pause / break / "continue another time" semantics (e.g. "先暂停", "let's pick this up later")

When you invoke save yourself, **follow the full `## save` protocol exactly** — actively-extract, Texture, Decisions, Rejected paths, Environment snapshot, all of it. The protocol's self-checks exist precisely because they're easy to skip in autopilot.

**Do NOT** use `Write` or `Edit` to write `.claude/handoff.md` directly bypassing this skill. Bypass produces an inferior handoff that **looks** identical to a real one (same path, same title) but silently misses every actively-extract self-check. The right path is exactly one: run the `## save` flow.

After a model-initiated save, **report to the user in one line**:

> Saved a checkpoint at `<absolute path>` — reason: <one sentence on why now>.

Single line, single reason. Lets the user notice it happened and overrule if your judgment was off (deliberate-moment threshold misjudged, ongoing topic not actually finished, etc.).

`resume` and `clear` remain **user-driven verbs** — they change session state in ways only the user should trigger (resume restores context the user wants restored; clear coordinates a context wipe the user initiated). If you, the model, think "we should resume" or "we should clear and restart", **tell the user**, don't invoke yourself.

## Usage

```
/handoff save [note]   write handoff to <project>/.claude/handoff.md
/handoff resume        read handoff + restate, wait for user before continuing
/handoff clear         save + prompt "then /clear and /handoff resume" (harness doesn't auto-chain)
/handoff eval [path]   read-only audit: cold-read a handoff via isolated subagent
```
