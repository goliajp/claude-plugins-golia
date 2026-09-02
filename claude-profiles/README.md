# claude-profiles

Add, remove and audit multiple Claude Code accounts on one machine.

Claude Code picks its account from `CLAUDE_CONFIG_DIR`. Running several
accounts means several profile directories that share a workspace through
symlinks while keeping their own credentials and history.

## Install

```bash
/plugin marketplace add goliajp/claude-plugins-golia
/plugin install claude-profiles@golia
```

For every profile on the machine:

```bash
for dir in ~/.claude-profile-*; do
  CLAUDE_CONFIG_DIR="$dir" claude plugin install claude-profiles@golia
done
```

## Use

```bash
scripts/new-profile.sh 5        # create ~/.claude-profile-5 from the newest profile
scripts/profile-doctor.sh       # audit every profile; exits non-zero on a problem
```

`new-profile.sh` mirrors only symlinks — never `history.jsonl`, which must stay
per-profile or session attribution collapses.

`profile-doctor.sh` checks, per profile: `history.jsonl` is a real file, the
shared symlink set matches the other profiles, no symlink dangles, whether a
keychain login exists under the derived service name, and whether a shell alias
points at it. Runs on the bash 3.2 that ships with macOS.

The skill covers the rest: the derived keychain naming, removal, and what to do
when another repo keeps its own copy of the account roster.

MIT
