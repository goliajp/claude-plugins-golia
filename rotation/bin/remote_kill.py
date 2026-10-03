#!/usr/bin/env python3
"""The one way the kernel ends a job on a runner: by the pid its remote.start registered, with that pid's
descendants, never by a command-line pattern. A runner is shared; a pattern (`pkill -f`, a `pgrep -f` fed to a
tree kill) also matches other sessions' jobs and their launchers, which carry the same words (bench-lock heavy,
cargo, xargs).

remote_run.sh registers remote.pid (the shell sshd started for the job; everything the job starts is under it)
and remote.pidStart (that process's `ps -o lstart`). The command below re-reads the start time first and kills
nothing when it differs: the runner may have given the pid to another process since. It then stops the whole
tree, sends TERM, and continues it, so no member can start a new child between the passes. A lock wrapper such
as bench-lock defers a TERM until its child exits and leaves the lock fd in that child, so killing the
registered pid alone would end nothing; the tree is the job.

usage: remote_kill.py <events.jsonl> [<rotationId>]
  prints one command per line for each remote.start of that round (every round when empty) that has no
  remote.end / gate.end yet and registered a pid and a host; the trigger's reaper runs them.
"""
import json
import os
import re
import shlex
import sys

HOST_RE = re.compile(r'^[A-Za-z0-9._@-]+$')
START_RE = re.compile(r'^[A-Za-z0-9: ]+$')


def tree_kill(pid, start):
    """the shell text that ends pid and its descendants, after checking pid still started at `start`; written
    for sh, bash and zsh alike (the runner's login shell runs it): command substitution splits in all three,
    a plain $l does not in zsh. The tree is listed once, before any signal: a stopped process that gets TERM
    dies on macOS, and listing again would lose its children, now reparented away"""
    return ('t(){ echo $1; for c in $(pgrep -P $1); do t $c; done; }; '
            f'set -- $(ps -o lstart= -p {pid}); '
            f'[ "$*" = "{start}" ] || {{ echo "pid {pid} is not the registered job (started: $*); nothing killed"; exit 3; }}; '
            f'l=$(t {pid}); for s in STOP TERM CONT; do for x in $(echo $l); do kill -$s $x 2>/dev/null; done; done; '
            f'echo "ended pid {pid} and its descendants"')


def kill_command(host, pid, start):
    """(command, None) or (None, why not): only a job that registered an int pid, a readable start time and,
    when it ran on a runner, a plain host name gets a command"""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return None, 'no PID registered'
    if not isinstance(start, str) or not START_RE.match(' '.join(start.split())):
        return None, f'pid {pid} registered without a readable start time'
    body = tree_kill(pid, ' '.join(start.split()))
    if not host:
        return f"sh -c {shlex.quote(body)}", None
    if not HOST_RE.match(host):
        return None, f'host {host!r} is not a plain host name'
    return f"ssh -o BatchMode=yes -o ConnectTimeout=5 {host} {shlex.quote(body)}", None


def open_jobs(events, rid=''):
    """remote.start rows with no later remote.end (or gate.end) for the same log, in order"""
    opened = []
    for e in events:
        if rid and e.get('rotationId') != rid:
            continue
        k = e.get('kind')
        if k == 'remote.start':
            opened.append(e)
        elif k in ('remote.end', 'gate.end'):
            r = e.get('remote') or e.get('gate') or {}
            if r.get('log'):
                opened = [o for o in opened if (o.get('remote') or {}).get('log') != r['log']]
            else:
                opened = [o for o in opened if ((o.get('remote') or {}).get('kind'), (o.get('remote') or {}).get('sha'))
                          != (r.get('kind'), r.get('sha'))]
    return opened


def main(argv):
    if not argv:
        print('usage: remote_kill.py <events.jsonl> [<rotationId>]', file=sys.stderr)
        return 2
    path, rid = argv[0], (argv[1] if len(argv) > 1 else '')
    events = []
    if os.path.isfile(path):
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except ValueError:
                continue
    for e in open_jobs(events, rid):
        r = e.get('remote') or {}
        if not r.get('host'):
            continue
        cmd, _ = kill_command(r.get('host'), r.get('pid'), r.get('pidStart'))
        if cmd:
            print(cmd)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
