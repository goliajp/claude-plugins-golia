---
description: Wire the rotation kernel into this project — kernel.path, the .claude/rotation shims, project.sh / rotation.conf / close_rules.tsv from the templates, the state directory
allowed-tools: Bash(bash:*), Read, Edit
---

Run the kernel's init script from the project root and show its output verbatim:

```
bash "${CLAUDE_PLUGIN_ROOT}/bin/init.sh" $ARGUMENTS
```

Then:

1. Read `.claude/rotation/project.sh` and `.claude/rotation/rotation.conf` as written. Tell the user which files were written from the templates and which were kept.
2. Do not fill in the adapter commands or thresholds yourself: they are the project's measurements. Ask the user for each `ROTATION_*_CMD` the project has (gate, pre-flight, close segment, bench, sweep line), or confirm the paths the template proposes, and edit `project.sh` to match. Keep `rotation.conf` in observe mode unless the user has data for the thresholds.
3. Finish with `bash .claude/rotation/doctor.sh` and show its last line. `DOCTOR PASS kernel=… conf=…` means the project can start a round; every `FAIL` line names what to fix.

If `init.sh` says it is not inside a git work tree, stop and tell the user: the kernel keeps its project files under the repository's `.claude/`, which the project keeps out of git.
