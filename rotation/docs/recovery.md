# Interruption recovery

A session process restarts, an account is switched, a quota runs out, a background task dies silently. Everything that matters is still on disk — commits, worktrees, events, remote logs — and what is missing is discovery and a wake-up. Three read-only tools do that; none asks the model to remember.

## recover.sh — one page, one action

`bash .claude/rotation/recover.sh [--json] [--no-probe]`

The page: HEAD and the round's commit count; the main tree's uncommitted files; every other worktree with its commits ahead of the base branch; the last five events; the registered agents (id, role, status, last event); remote jobs with a `remote.start` and no `remote.end`, each with whether its terminal marker is already in its log (`terminal=seen|not-seen|unknown`) and, when seen, a `collect:` line with the command that records the end (and, when the project configured `ROTATION_REMOTE_COLLECT_CMD`, the commands that take the results); commits on the main tree no running executor accounts for; the raw output of the project's remote probe. The last line is the action:

| last line | when |
|---|---|
| `RESUME <agentId>` | an executor of this round is registered as running **with an id**, and the session that registered it equals this session's `CLAUDE_CODE_SESSION_ID` (an event older than the field counts as unknown and is offered as RESUME; the `executor session:` line says so) |
| `CLEAN main tree first` | no resumable executor and the main tree has uncommitted files |
| `RESPAWN executor leftover=…` | no resumable executor and something is left: `executor:<name>(no-id)` / `(<id>,mismatch)` / `(<id>,no-session)`, `foreign-commits:N`, `worktree:<name>(+N[,dirty=M])`, `remote:<kind>@<sha>(<terminal>)`, a worker still registered, an executor that ended abnormally |
| `IDLE` | nothing running, nothing left |

`running rotation executors: N` is flagged `MORE THAN ONE` when N > 1; end the stale one with `ROTATION_AGENT_STATUS=abandoned agent_log.sh end …` before anything else.

### Why RESUME depends on the session

A subagent's transcript lives under the session that spawned it, and `SendMessage` finds it only there. Measured facts (Claude Code 2.1.x):

- the session that spawned the executor, and that same session after `--resume <session id>`, can `SendMessage` it and get an answer;
- **any other session**, given the same agent id, gets `No transcript found for agent ID`. A new session can never continue another session's executor; the right move is always a new executor with the scene in `leftover:`.

So `agent_log.sh start … rotation` records the registering session (`managerSession`), and `decide()` offers RESUME only on a match. A manager that stops on purpose records `manager_log.sh stop <reason>` so the next session knows the executor is orphaned rather than lost.

Two more platform facts the protocol is written around:

- `SendMessage` is asynchronous: the sending session's turn ends when the message is sent (its Stop hook fires), and the reply arrives as a new turn. A session does not wait for the reply inside the same turn.
- `SendMessage` to a subagent that runs in a **worktree** (`isolation: worktree`) can leave the sending session's working directory in that worktree for the rest of the turn. After such a message, check the main tree once (`git -C <main tree> status --porcelain`, `git rev-parse --show-toplevel`) before any command that assumes the main tree.

## watchdog.sh — the exit code is the notification

`bash .claude/rotation/watchdog.sh [--interval 60] [--stale 1800] [--wake 300] [--dirty 600] [--once]`, started by the manager with `run_in_background`. Checks every `--interval` seconds; on the first hit prints one line and exits. It changes nothing. Checked in this order:

| first word | exit | condition |
|---|---|---|
| `MULTI-EXECUTOR` | 15 | more than one rotation executor of this round registered as running (a re-registration under the same name supersedes, it does not count twice) |
| `QUOTA` | 12 | the last `quota.hit`'s reset time has passed and neither an executor event nor a `manager.resume` followed |
| `WAKE` | 10 | the last `executor.waiting`'s condition holds (the remote marker is in the log, or every listed worker has an `agent.end`) and the executor recorded nothing since for `--wake` seconds; **or** the round's last `remote.end` was followed by no executor event and no commit for `ROTATION_WAKE_AFTER` seconds (no `executor.waiting` needed). A `manager.resume` restarts both clocks |
| `DIRTY` | 13 | an uncommitted file in the main tree written `--dirty` seconds after the executor's last event, still there `--dirty` seconds later |
| `FOREIGN-COMMIT` | 14 | `manager.active` exists, the base branch's HEAD moved past the round's `prevHead`, and no executor is registered as running — or the HEAD commit is later than the last executor event and that executor has ended |
| `STALE` | 11 | no sign of life for `--stale` seconds: the latest of the last event, the main tree's HEAD commit time and the newest commit in any worktree, never earlier than the watchdog's own start |

`--once` makes one pass: the hit, or `OK …` and exit 0. Exit 1 is the check itself failing, 2 usage. Activity means executor events and `manager.resume`; the manager's own segments and other `manager.*` events are not the executor moving.

A background task has a lifetime; when it is reached the task is collected without output, and the manager re-arms.

## The resume hook

On `SessionStart` with `source=resume`, while `manager.active` exists, the hook prints the `recover.sh` page into the session's context, framed by two lines saying the manager was active and to act on the last line and re-arm the watchdog. A fresh start prints nothing; a project without `.claude/rotation/` gets nothing written.

## The SubagentStop hook

When a subagent ends, Claude Code runs the hook in the session that spawned it, with the agent's id on stdin. An id registered through `agent_log.sh` gets its end on record mechanically — `agent.stop` for the executor (it finished a reply), `agent.end` for any other registered agent (once; a later `agent_log.sh end` is the usual second row). The watchdog's WAKE reads it, so an executor waiting on a worker is woken without anyone forwarding the completion notice. Unknown ids write nothing.

## The reaper

`kill_stray_shells.sh` runs on every accepted trigger: it walks up from itself to the owning Claude Code process and ends every Bash-tool shell under it (recognised by the `shell-snapshots` marker on its command line), with its subtree — a watcher, poller or remote wait that survives into the next round has, in the record, run for hours polling for a line that never came. Two exceptions: the chain the script itself runs under, and a shell whose subtree runs a `watchdog.sh` — any path ending in `/watchdog.sh`, whichever install of the kernel it came from (the manager started it through the same tool and it is the one process meant to live across a close; it prints `KEEP`). Non-shell children of the process (MCP servers, IDE helpers) are never touched.

**Its scope is the whole Claude Code process, not the repository or the task.** Subagents run inside their parent's process, so a `trigger.sh self` run from any subagent — the round's executor, or a test agent trying the protocol in a throwaway repository — would end the shells of every other agent of that session: the manager's watchdog, another agent's pre-flight, its remote jobs. **In manager mode the reaper therefore does not act**: while `manager.active` exists in the state directory it prints `SKIP: manager mode …` and exits 0, reaping nothing locally or remotely; stray shells in a managed session are collected by PID by whoever started them. The reap runs in session mode (no manager, the interactive session is the executor), where every Bash-tool shell of the process is the round's own. A trial round in a throwaway repository has no `manager.active` of its own to protect anything, so it belongs in a terminal outside Claude Code. It also runs `ROTATION_REAP_REMOTE_CMD` best-effort for processes on a runner that outlive a dropped link. Exit 1 only when no owning session process is found (not run from inside a session: it refuses rather than guesses).

## Recovery and the adapter commands

The whole mechanism rests on the events existing. That is why the adapter commands record their own `remote.start` / `remote.end` / `gate.end` / `preflight.end`, and why `adapter_run.sh` refuses (exit 64) a command that exits 0 without them: a hand-written remote invocation that forgets the event is exactly the job the recovery page cannot see. A project with no remote runner records no `remote.host`; the recovery tools then read the local log file for the marker and call no remote command at all.

Next: [configuration.md](configuration.md).
