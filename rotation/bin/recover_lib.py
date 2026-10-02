#!/usr/bin/env python3
"""What the events, git and the remote probe say about an interrupted rotation.

Two entry points, both read-only:
  recover [--json] [--no-probe]   one page of the scene, last line = the suggested action
  watch --stale S --wake S --dirty S --floor TS
                                  one watchdog pass: prints `OK` (exit 0) or one reason line
                                  WAKE (10) / STALE (11) / QUOTA (12) / DIRTY (13) / FOREIGN-COMMIT (14) /
                                  MULTI-EXECUTOR (15)

Environment (set by recover.sh / watchdog.sh from lib.sh and the project adapter):
  CLAUDE_CODE_SESSION_ID     the session running this check; RESUME is offered only when it is the session
                             that registered the executor (a subagent transcript lives under the session that
                             spawned it, so SendMessage reaches it from there and its --resume, nowhere else)
  ROTATION_REPO              the main working tree
  ROTATION_EVENTS_LOG        events.jsonl
  ROTATION_ROTATIONS_LOG     rotations.jsonl
  ROTATION_MANAGER_ACTIVE    the manager marker file; FOREIGN-COMMIT is checked only while it exists
  ROTATION_AGENT_ORIGIN_PATTERN  the commit-message pattern of agent-landed commits
  ROTATION_BASE_BRANCH       the branch worktrees are compared against (default: the main tree's branch)
  ROTATION_REMOTE_PROBE_CMD  shell command whose output is shown verbatim (processes, lock queue)
  ROTATION_REMOTE_GREP_CMD   command called as `<cmd> <log> <marker> [host]` for a job recorded with a host:
                             exit 0 = marker seen in the remote log, 1 = not seen, anything else = unknown.
                             A job recorded without a host (remote.host absent or null) ran on this machine:
                             its log is a local file and is read here; neither command is called for it, so a
                             project with no runner configures neither.
  ROTATION_REMOTE_COLLECT_CMD
                             command called as `<cmd> <kind> <sha> <log> <host> <rotationId>` for a job whose terminal
                             marker is already in its log and whose end was never recorded: it prints, one per line,
                             the commands that take the results and record the end (the project knows where each
                             kind leaves its files). Prints nothing for a kind it does not know, and the page then
                             offers recording the end alone. Unset: the same fallback for every kind.
  ROTATION_WAKE_AFTER        seconds (rotation.conf, default 300): a remote.end of this round followed by no executor
                             event for that long is a WAKE — the executor need not have recorded executor.waiting.
                             A manager.resume after the remote.end restarts the clock; other manager.* events do not.
  ROTATION_WORKER_STALE      seconds (rotation.conf, default 1200): a non-executor agent of this round still registered
                             as running whose transcript has not been written for that long is `dead?` on the page
                             and a WAKE for the watchdog, until a manager.resume of this round records the manager
                             relaying it to the executor: from then the page marks it relayed and the watchdog stays
                             quiet about it, until its transcript is written again and then stops for that long once
                             more. The transcript is <config>/projects/<project>/<session>/
                             subagents/agent-<id>.jsonl, <session> being the managerSession on the agent's start event,
                             else on the round's executor's (agents are nested under the session that started the
                             executor); with no session or id on record, or no such file, the state is unknown.
  ROTATION_CLAUDE_CONFIG_DIRS
                             `:`-separated Claude Code config directories searched for that transcript; default
                             $CLAUDE_CONFIG_DIR, ~/.claude and every ~/.claude-* directory (several accounts may run
                             side by side, and the agent may live under any of them)
"""
import datetime
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time

REPO = os.environ['ROTATION_REPO']
EVENTS = os.environ['ROTATION_EVENTS_LOG']
ROTATIONS = os.environ['ROTATION_ROTATIONS_LOG']
PROBE_CMD = os.environ.get('ROTATION_REMOTE_PROBE_CMD', '')
GREP_CMD = os.environ.get('ROTATION_REMOTE_GREP_CMD', '')
COLLECT_CMD = os.environ.get('ROTATION_REMOTE_COLLECT_CMD', '')
WAKE_AFTER = int(os.environ.get('ROTATION_WAKE_AFTER') or 300)
WORKER_STALE = int(os.environ.get('ROTATION_WORKER_STALE') or 1200)
KERNEL_DIR = os.path.dirname(os.path.abspath(__file__))
ORIGIN = os.environ.get('ROTATION_AGENT_ORIGIN_PATTERN') or os.environ.get('HARDEV_AGENT_ORIGIN_PATTERN') or '^Agent-Origin:'
# the manager marker: while it exists a rotation is being managed, and every commit on the main tree must come
# from a registered, running executor (FOREIGN-COMMIT checks only then)
MANAGER_ACTIVE = os.environ.get('ROTATION_MANAGER_ACTIVE', '')
CURRENT_SESSION = os.environ.get('CLAUDE_CODE_SESSION_ID') or None
EXIT = {'WAKE': 10, 'STALE': 11, 'QUOTA': 12, 'DIRTY': 13, 'FOREIGN-COMMIT': 14, 'MULTI-EXECUTOR': 15}


def read_jsonl(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except FileNotFoundError:
        pass
    return out


def git(*args, cwd=None):
    r = subprocess.run(['git', '-C', cwd or REPO, *args], capture_output=True, text=True)
    return r.stdout.rstrip('\n') if r.returncode == 0 else None


def lines(text):
    return [l for l in (text or '').split('\n') if l]


def iso(ts):
    if ts is None:
        return None
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def is_manager(e):
    a = e.get('agent')
    return isinstance(a, dict) and a.get('role') == 'manager'


def is_manager_event(e):
    """an event the manager session wrote about itself: a manager-role agent segment, or a manager.* kind other
    than manager.resume, which records the executor being continued and so counts as the executor's activity"""
    k = e.get('kind') or ''
    return is_manager(e) or (k.startswith('manager.') and k != 'manager.resume')


def executor_events(events):
    return [e for e in events if not is_manager_event(e)]


def dirty_files():
    out = []
    for line in lines(git('status', '--porcelain')):
        path = line[3:].split(' -> ')[-1].strip('"')
        try:
            mtime = int(os.lstat(os.path.join(REPO, path)).st_mtime)
        except OSError:
            mtime = None
        out.append({'status': line[:2], 'path': path, 'mtime': mtime})
    return out


def base_branch():
    return os.environ.get('ROTATION_BASE_BRANCH') or git('rev-parse', '--abbrev-ref', 'HEAD') or 'HEAD'


def worktrees(base):
    out, cur = [], {}
    for line in (git('worktree', 'list', '--porcelain') or '').split('\n') + ['']:
        if not line:
            if cur:
                out.append(cur)
            cur = {}
            continue
        key, _, val = line.partition(' ')
        if key == 'worktree':
            cur['path'] = val
        elif key == 'HEAD':
            cur['head'] = val[:9]
        elif key == 'branch':
            cur['branch'] = val.replace('refs/heads/', '', 1)
        elif key == 'detached':
            cur['branch'] = None
    main = os.path.realpath(REPO)
    rows = []
    for w in out:
        if os.path.realpath(w['path']) == main:
            continue
        ref = w.get('branch') or w.get('head')
        ahead = lines(git('log', '--format=%h %s', f'{base}..{ref}'))
        ct = git('log', '-1', '--format=%ct', ref)
        status = git('status', '--porcelain', cwd=w['path']) if os.path.isdir(w['path']) else None
        rows.append({'path': w['path'], 'name': os.path.basename(w['path']), 'branch': w.get('branch'), 'head': w.get('head'),
                     'ahead': ahead, 'dirty': len(lines(status)) if status is not None else None,
                     'commitTs': int(ct) if ct else None})
    return rows


def activity(events, trees):
    """the latest sign of life: the last event, the main tree's HEAD commit, or the newest commit on any worktree"""
    ct = git('log', '-1', '--format=%ct')
    marks = [('event ' + str(events[-1].get('kind')), events[-1].get('ts')) if events else ('event', None),
             ('commit on the main tree', int(ct) if ct else None)]
    marks += [('commit in worktree ' + w['name'], w['commitTs']) for w in trees]
    what, ts = max(marks, key=lambda m: m[1] or 0)
    return {'ts': ts, 'at': iso(ts), 'what': what if ts else None}


def current_round(rows):
    last = rows[-1] if rows else None
    if not last:
        return {'rotationId': None, 'ts': 0, 'at': None, 'prevHead': None, 'commits': None}
    prev = last.get('prevHead')
    count = None
    if prev:
        every = git('rev-list', f'{prev}..HEAD')
        main = git('rev-list', '--first-parent', '--invert-grep', '-E', f'--grep={ORIGIN}', f'{prev}..HEAD')
        if every is not None and main is not None:
            count = {'all': len(lines(every)), 'main': len(lines(main)), 'agent': len(lines(every)) - len(lines(main))}
    return {'rotationId': last.get('rotationId'), 'ts': last.get('ts') or 0, 'at': last.get('at'), 'prevHead': prev, 'commits': count}


def agents_of(events, round_ts):
    """agent.start paired with the next agent.end of the same name; an unpaired start is running. listed: every
    agent of the current round, plus older ones still open (their end was never recorded)"""
    open_by_name, done = {}, []
    for e in events:
        k = e.get('kind')
        if k not in ('agent.start', 'agent.end'):
            continue
        a = e.get('agent') or {}
        name = a.get('name')
        if k == 'agent.start':
            if name in open_by_name:
                done.append(dict(open_by_name.pop(name), status='superseded'))
            # managerSession: the session that registered the agent; absent on events older than the field
            open_by_name[name] = {'name': name, 'role': a.get('role'), 'model': a.get('model'), 'id': a.get('id'),
                                  'worktree': a.get('worktree'), 'scratch': a.get('scratch'), 'gateLog': a.get('gateLog'),
                                  'task': a.get('task'), 'rotationId': e.get('rotationId'), 'status': 'running',
                                  'startedTs': e.get('ts'), 'lastTs': e.get('ts'),
                                  'managerSession': e.get('managerSession'), 'sessionRecorded': 'managerSession' in e}
        else:
            rec = open_by_name.pop(name, None) or {'name': name, 'role': a.get('role'), 'model': a.get('model'), 'id': a.get('id'),
                                                    'worktree': None, 'scratch': None, 'gateLog': None, 'task': a.get('task'),
                                                    'rotationId': e.get('rotationId'), 'startedTs': None,
                                                    'managerSession': None, 'sessionRecorded': False}
            rec['id'] = rec.get('id') or a.get('id')
            rec['status'] = a.get('status') or 'ok'
            rec['lastTs'] = e.get('ts')
            done.append(rec)
    rows = [r for r in done if (r.get('lastTs') or 0) >= round_ts and r['status'] != 'superseded'] + list(open_by_name.values())
    for r in rows:
        r['inRound'] = (r.get('startedTs') or r.get('lastTs') or 0) >= round_ts
        r['lastAt'] = iso(r.get('lastTs'))
    rows.sort(key=lambda r: r.get('lastTs') or 0)
    return rows


def marker_seen(log, marker, host):
    """True / False / None (no probe configured, nothing to look for, or the probe itself failed); a job without
    a host is local, and its log is read here (no log file yet = not seen)"""
    if not log or not marker:
        return None
    if not host:
        try:
            with open(log) as f:
                return any(re.search(marker, line) for line in f)
        except OSError:
            return False
    if not GREP_CMD:
        return None
    try:
        r = subprocess.run(['bash', '-c', GREP_CMD + ' "$@"', 'remote-grep', log, marker, host or ''],
                           capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None
    return True if r.returncode == 0 else False if r.returncode == 1 else None


def collect_commands(job):
    """the commands that take a finished job's results and record its end, for a job whose marker is in its log
    and whose remote.end was never written: the project's ROTATION_REMOTE_COLLECT_CMD prints them for the kinds it
    knows where the results of are; a kind it does not know (nothing printed), or no command configured, leaves
    the one thing the kernel can offer by itself — recording the end"""
    out = []
    if COLLECT_CMD:
        try:
            r = subprocess.run(['bash', '-c', COLLECT_CMD + ' "$@"', 'remote-collect', job['kind'] or '', job['sha'] or '',
                                job['log'] or '', job['host'] or '', job['rotationId'] or ''],
                               capture_output=True, text=True, timeout=30)
            if r.returncode == 0:
                out = lines(r.stdout)
        except subprocess.TimeoutExpired:
            out = []
    if not out:
        host = f" remote.host={shlex.quote(job['host'])}" if job['host'] else ''
        out = [f"bash {shlex.quote(os.path.join(KERNEL_DIR, 'event.sh'))} remote.end remote.kind={shlex.quote(job['kind'] or '')}"
               f" remote.sha={shlex.quote(job['sha'] or '')} remote.log={shlex.quote(job['log'] or '')}{host} remote.status=ok"]
    return out


def open_remotes(events, probe):
    """remote.start rows with no later remote.end (or gate.end) for the same log; a job whose marker is already in
    its log carries the commands that collect it (`collect`)"""
    opened = []
    for e in events:
        k = e.get('kind')
        if k == 'remote.start':
            r = e.get('remote') or {}
            opened.append({'kind': r.get('kind'), 'sha': r.get('sha'), 'log': r.get('log'), 'marker': r.get('marker'),
                           'host': r.get('host'), 'startedTs': e.get('ts'), 'startedAt': iso(e.get('ts')), 'rotationId': e.get('rotationId')})
        elif k in ('remote.end', 'gate.end'):
            r = e.get('remote') or e.get('gate') or {}
            if r.get('log'):
                opened = [o for o in opened if o['log'] != r['log']]
            else:
                opened = [o for o in opened if (o['kind'], o['sha']) != (r.get('kind'), r.get('sha'))]
    opened = opened[-10:]
    for o in opened:
        seen = marker_seen(o['log'], o['marker'], o['host']) if probe else None
        o['terminal'] = {True: 'seen', False: 'not-seen', None: 'unknown'}[seen]
        o['collect'] = collect_commands(o) if seen else []
    return opened


def remote_end_state(events, round_ts):
    """the round's last remote.end and whether the executor moved after it. any executor event after it answers it;
    a manager.resume after it restarts the clock (the executor was continued then); the manager's own events do not
    count either way. None when the round has no remote.end"""
    acts = [e for e in executor_events(events) if (e.get('ts') or 0) >= round_ts]
    i = last_index(acts, 'remote.end')
    if i is None:
        return None
    end = acts[i]
    after = acts[i + 1:]
    moved = [e for e in after if e.get('kind') != 'manager.resume']
    resumes = [e for e in after if e.get('kind') == 'manager.resume']
    ref = resumes[-1].get('ts') if resumes else end.get('ts')
    moved_by = 'event ' + str(moved[-1].get('kind')) if moved else None
    # a commit on the main tree after the end is the executor at work as surely as an event is
    ct = git('log', '-1', '--format=%ct')
    if not moved and ct and int(ct) >= (ref or 0):
        moved_by = 'commit on the main tree'
    r = end.get('remote') or {}
    return {'at': iso(end.get('ts')), 'ts': end.get('ts'), 'kind': r.get('kind'), 'sha': r.get('sha'), 'log': r.get('log'),
            'pending': moved_by is None, 'movedBy': moved_by, 'resumed': bool(resumes), 'refTs': ref, 'wakeAfter': WAKE_AFTER}


def parse_resets(value, event_ts):
    """epoch seconds for a quota reset written as an epoch, an ISO time, or HH:MM local (the next one after the event)"""
    if isinstance(value, (int, float)):
        return int(value)
    if not isinstance(value, str) or not value.strip():
        return None
    v = value.strip()
    if v.isdigit():
        return int(v)
    m = re.fullmatch(r'(\d{1,2}):(\d{2})', v)
    if m:
        base = datetime.datetime.fromtimestamp(event_ts or time.time())
        t = base.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=0, microsecond=0)
        if t < base:
            t += datetime.timedelta(days=1)
        return int(t.timestamp())
    try:
        t = datetime.datetime.fromisoformat(v.replace('Z', '+00:00'))
    except ValueError:
        return None
    return int(t.timestamp())


def last_index(events, kind):
    for i in range(len(events) - 1, -1, -1):
        if events[i].get('kind') == kind:
            return i
    return None


def config_dirs():
    raw = os.environ.get('ROTATION_CLAUDE_CONFIG_DIRS')
    if raw:
        return [d for d in raw.split(':') if d]
    home = os.path.expanduser('~')
    dirs = [os.environ.get('CLAUDE_CONFIG_DIR') or '', os.path.join(home, '.claude')]
    return [d for d in dirs if d] + sorted(glob.glob(os.path.join(home, '.claude-*')))


def transcript_state(agent, session, now):
    """how long ago the agent's transcript was last written: alive / dead? (ROTATION_WORKER_STALE or more) /
    unknown (no session or id on record, or no transcript under any config directory)"""
    aid = agent.get('id')
    if not session or not aid:
        why = 'no session on record' if not session else 'no agent id on record'
        return {'state': 'unknown', 'why': why, 'path': None, 'mtime': None, 'age': None, 'session': session}
    found = {}
    for d in config_dirs():
        for path in glob.glob(os.path.join(d, 'projects', '*', session, 'subagents', f'agent-{aid}.jsonl')):
            found[os.path.realpath(path)] = path
    if not found:
        return {'state': 'unknown', 'why': 'no transcript found', 'path': None, 'mtime': None, 'age': None, 'session': session}
    path = found[max(found, key=os.path.getmtime)]
    mtime = int(os.path.getmtime(path))
    age = now - mtime
    return {'state': 'dead?' if age >= WORKER_STALE else 'alive', 'why': None, 'path': path, 'mtime': mtime, 'age': age,
            'session': session}


def worker_states(agents, now, events, round_ts):
    """every agent of this round still registered as running that is not the executor or the manager: the ones
    the executor is waiting on. each gets its transcript state; a dead? one also gets relayedTs, the last
    manager.resume of the round recorded once it was already dead? (transcript mtime + ROTATION_WORKER_STALE or
    later), else None. a write after that resume moves the mtime past it, which clears it"""
    resumes = [e.get('ts') or 0 for e in events if e.get('kind') == 'manager.resume' and (e.get('ts') or 0) >= round_ts]
    ex = executor_of(agents)
    rounds = [a for a in agents if a['role'] == 'rotation' and a['inRound'] and a.get('managerSession')]
    fallback = (ex or {}).get('managerSession') or (rounds[-1]['managerSession'] if rounds else None)
    out = []
    for a in agents:
        if a['status'] != 'running' or not a['inRound'] or a['role'] in ('rotation', 'manager'):
            continue
        t = transcript_state(a, a.get('managerSession') or fallback, now)
        if t['state'] == 'dead?':
            t['relayedTs'] = max((r for r in resumes if r >= t['mtime'] + WORKER_STALE), default=None)
        a['transcript'] = t
        out.append(a)
    return out


def waiting_state(events, probe=True):
    """the last executor.waiting, whether the executor has moved since, and whether what it waits for has happened"""
    acts = executor_events(events)
    i = last_index(acts, 'executor.waiting')
    if i is None:
        return None
    w = acts[i]
    spec = w.get('waiting') or {}
    remote = w.get('remote') or spec.get('remote')
    workers = w.get('workers') or spec.get('workers')
    after = acts[i + 1:]
    state = {'at': iso(w.get('ts')), 'ts': w.get('ts'), 'remote': remote, 'workers': workers, 'refTs': w.get('ts')}
    if workers:
        ended = lambda e: e.get('kind') == 'agent.end' and (e.get('agent') or {}).get('name') in workers
        state['pending'] = all(ended(e) for e in after)
        latest = {}
        for e in acts:
            if e.get('kind') in ('agent.start', 'agent.end') and (e.get('agent') or {}).get('name') in workers:
                latest[e['agent']['name']] = e['kind']
        state['satisfied'] = all(latest.get(n) == 'agent.end' for n in workers)
        if after:
            state['refTs'] = after[-1].get('ts')
    elif remote:
        state['pending'] = not after
        seen = marker_seen(remote.get('log'), remote.get('marker'), remote.get('host')) if (probe and state['pending']) else None
        state['satisfied'] = seen
    else:
        state['pending'] = not after
        state['satisfied'] = None
    return state


def quota_state(events, now):
    """the last quota.hit; pending until the executor records anything or the manager records manager.resume
    (the manager's own segments and other manager.* events do not count as the executor having moved)"""
    acts = executor_events(events)
    i = last_index(acts, 'quota.hit')
    if i is None:
        return None
    q = acts[i]
    body = q.get('quota') if isinstance(q.get('quota'), dict) else q
    resets = parse_resets(body.get('resets'), q.get('ts'))
    return {'at': iso(q.get('ts')), 'agent': body.get('agent') if isinstance(body.get('agent'), str) else None,
            'resets': body.get('resets'), 'resetsTs': resets, 'resetsAt': iso(resets),
            'pending': i == len(acts) - 1, 'due': resets is not None and resets <= now}


def running_executors(agents):
    return [a for a in agents if a['role'] == 'rotation' and a['status'] == 'running' and a['inRound']]


def executor_of(agents):
    live = running_executors(agents)
    return live[-1] if live else None


def session_state(ex):
    """whether this session can reach the executor by SendMessage. match: it was registered from this session;
    unknown: registered before the session was recorded (an older event), taken as reachable; no-session: the
    registration or this check has no session id; mismatch: another session registered it, only a respawn can go on"""
    cur = CURRENT_SESSION
    if ex is None:
        return {'registered': None, 'current': cur, 'recorded': None, 'verdict': None}
    if not ex.get('sessionRecorded'):
        return {'registered': None, 'current': cur, 'recorded': False, 'verdict': 'unknown'}
    reg = ex.get('managerSession')
    verdict = 'no-session' if (reg is None or cur is None) else 'match' if reg == cur else 'mismatch'
    return {'registered': reg, 'current': cur, 'recorded': True, 'verdict': verdict}


def foreign_commits(rnd, agents, events):
    """commits on the main tree that no running executor accounts for, while a rotation is being managed:
    HEAD moved past the round's prevHead and no rotation executor is registered as running, or the HEAD
    commit is later than the last rotation-executor event and that executor is not running. None when the
    manager marker is absent (a plain session commits to the main tree itself)"""
    if not MANAGER_ACTIVE or not os.path.isfile(MANAGER_ACTIVE):
        return None
    prev = rnd.get('prevHead')
    head = git('rev-parse', 'HEAD')
    if not prev or not head or head.startswith(prev):
        return {'count': 0, 'reason': None}
    ct = git('log', '-1', '--format=%ct')
    head_ts = int(ct) if ct else 0
    ex = executor_of(agents)
    execs = [e for e in events if e.get('kind') in ('agent.start', 'agent.end')
             and (e.get('agent') or {}).get('role') == 'rotation' and (e.get('ts') or 0) >= rnd.get('ts', 0)]
    last_exec_ts = execs[-1].get('ts') if execs else None
    ahead = lines(git('rev-list', '--first-parent', f'{prev}..HEAD'))
    if ex is None:
        if last_exec_ts is None:
            return {'count': len(ahead), 'reason': 'no rotation executor was ever registered for this round'}
        if head_ts > last_exec_ts:
            return {'count': len(ahead), 'reason': f'HEAD committed at {iso(head_ts)}, after the last executor event {iso(last_exec_ts)}, and no executor is running'}
    return {'count': 0, 'reason': None}


def run_probe():
    if not PROBE_CMD:
        return None
    try:
        r = subprocess.run(['bash', '-c', PROBE_CMD], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=45)
        return {'cmd': PROBE_CMD, 'rc': r.returncode, 'output': r.stdout}
    except subprocess.TimeoutExpired as e:
        return {'cmd': PROBE_CMD, 'rc': None, 'output': (e.stdout or '') + '\n(probe timed out after 45 s)'}


def summary(e):
    rest = {k: v for k, v in e.items() if k not in ('at', 'ts', 'kind', 'rotationId', 'head')}
    text = json.dumps(rest, ensure_ascii=False, separators=(',', ':'))
    return text if len(text) <= 150 else text[:147] + '...'


def decide(scene):
    """RESUME when an executor of this round is still registered as running with an id, from the session that
    registered it (or from before sessions were recorded); an executor registered without an id, or from another
    session, cannot be reached and is a leftover; otherwise the main tree has to be clean before anything new
    starts; otherwise a new executor takes over whatever is left; otherwise nothing to do"""
    ex = scene['executor']
    verdict = scene['session']['verdict']
    if ex and ex.get('id') and verdict in ('match', 'unknown'):
        return f"RESUME {ex['id']}"
    if scene['dirty']:
        return 'CLEAN main tree first'
    left = []
    if ex:
        left.append(f"executor:{ex['name']}(no-id)" if not ex.get('id') else f"executor:{ex['name']}({ex['id']},{verdict})")
    fc = scene.get('foreign') or {}
    if fc.get('count'):
        left.append(f"foreign-commits:{fc['count']}")
    for w in scene['worktrees']:
        if w['ahead'] or w['dirty']:
            left.append(f"worktree:{w['name']}(+{len(w['ahead'])}" + (f",dirty={w['dirty']}" if w['dirty'] else '') + ')')
    for r in scene['remotes']:
        left.append(f"remote:{r['kind']}@{r['sha']}({r['terminal']})")
    for a in scene['agents']:
        if a is ex:
            continue
        if a['status'] == 'running' and a['inRound'] and a['role'] != 'manager':
            left.append(f"{a['role']}:{a['name']}" + (f"({a['id']})" if a.get('id') else ''))
        elif a['role'] == 'rotation' and a['inRound'] and a['status'] not in ('ok', 'running'):
            left.append(f"executor:{a['name']}({a['status']})")
    return 'RESPAWN executor leftover=' + ';'.join(left) if left else 'IDLE'


def build_scene(probe):
    now = int(time.time())
    events = read_jsonl(EVENTS)
    rnd = current_round(read_jsonl(ROTATIONS))
    base = base_branch()
    head = git('log', '-1', '--format=%h %s')
    agents = agents_of(events, rnd['ts'])
    trees = worktrees(base)
    # an agent's last sign of life includes the newest commit in the worktree it was registered with
    by_path = {os.path.realpath(w['path']): w for w in trees}
    for a in agents:
        w = by_path.get(os.path.realpath(a['worktree'])) if a.get('worktree') else None
        if w and a['status'] == 'running' and (w['commitTs'] or 0) > (a.get('lastTs') or 0):
            a['lastTs'] = w['commitTs']
            a['lastAt'] = iso(w['commitTs'])
    scene = {
        'now': iso(now), 'repo': REPO, 'head': head, 'branch': git('rev-parse', '--abbrev-ref', 'HEAD'), 'base': base,
        'round': rnd, 'dirty': dirty_files(), 'worktrees': trees,
        'activity': activity(events, trees),
        'events': {'count': len(events), 'last': events[-5:]},
        'agents': agents, 'executor': executor_of(agents), 'executors': running_executors(agents),
        'session': session_state(executor_of(agents)),
        'foreign': foreign_commits(rnd, agents, events),
        'remotes': open_remotes(events, probe),
        'remoteEnd': remote_end_state(events, rnd['ts']),
        'waiting': waiting_state(events, probe), 'quota': quota_state(events, now),
        'workers': worker_states(agents, now, events, rnd['ts']), 'workerStale': WORKER_STALE,
        'probe': run_probe() if probe else None,
    }
    scene['action'] = decide(scene)
    return scene


def ago(ts, now):
    return '—' if ts is None else f'{(now - ts) // 60} min ago'


def print_scene(s):
    now = int(time.time())
    p = print
    p(f"== rotation recover · {os.path.basename(os.path.realpath(s['repo']))} · {s['now']} ==")
    p(f"head: {s['head']}  (branch {s['branch']})")
    r = s['round']
    c = r['commits']
    p(f"round: {r['rotationId'] or '—'} opened {r['at'] or '—'} prevHead={r['prevHead'] or '—'} · commits "
      + (f"{c['all']} (main {c['main']} · agent {c['agent']})" if c else '— (range unknown)'))
    p(f"dirty files in the main tree: {len(s['dirty'])}")
    for d in s['dirty'][:40]:
        p(f"  {d['status']} {d['path']}  mtime={iso(d['mtime']) or '—'}")
    if len(s['dirty']) > 40:
        p(f"  ... {len(s['dirty']) - 40} more")
    p(f"worktrees: {len(s['worktrees'])}  ({s['base']}..<branch>)")
    for w in s['worktrees']:
        p(f"  {w['path']}  [{w['branch'] or 'detached'}] {w['head']} ahead={len(w['ahead'])} dirty={'—' if w['dirty'] is None else w['dirty']}")
        for line in w['ahead'][:10]:
            p(f"    {line}")
        if len(w['ahead']) > 10:
            p(f"    ... {len(w['ahead']) - 10} more")
    p(f"events: last {len(s['events']['last'])} of {s['events']['count']}")
    for e in s['events']['last']:
        p(f"  {e.get('at')} {e.get('kind')} {summary(e)}")
    act = s['activity']
    p(f"last activity: {act['at'] or '—'} ({ago(act['ts'], now)}) · {act['what'] or '—'}")
    p(f"agents: {len(s['agents'])}")
    for a in s['agents']:
        extra = ''.join(f" {k}={a[k]}" for k in ('worktree', 'scratch', 'gateLog') if a.get(k))
        t = a.get('transcript')
        if t:
            extra += (f" transcript={t['state']} ({t['age'] // 60} min since written)" if t['age'] is not None
                      else f" transcript=unknown ({t['why']})")
        p(f"  {a['name']} role={a['role']} status={a['status']}{'' if a['inRound'] else ' (earlier round)'} id={a.get('id') or '—'}"
          f" last={a['lastAt']} ({ago(a.get('lastTs'), now)}){extra}")
    for a in s['workers']:
        t = a['transcript']
        if t['state'] != 'dead?':
            continue
        p(f"  dead? {a['name']}: its transcript {t['path']} has not been written for {t['age'] // 60} min "
          f"(ROTATION_WORKER_STALE={s['workerStale']} s) while it is still registered as running. Tell the executor: "
          f"continue it (SendMessage to {a['id']}, from session {t['session']}), or record its end "
          f"(ROTATION_AGENT_STATUS=abandoned agent_log.sh end {a['name']} {a['role']} {a.get('model') or '-'}) and dispatch "
          f"its task again: {a.get('task') or '—'}" + (f" · worktree {a['worktree']}" if a.get('worktree') else '')
          + (f" · relayed {iso(t['relayedTs'])} (manager.resume; no WAKE until it is written again and stops again)"
             if t['relayedTs'] else ''))
    ex_names = ', '.join(f"{a['name']}({a.get('id') or 'no-id'})" for a in s['executors'])
    p(f"running rotation executors: {len(s['executors'])}" + (f" — {ex_names}" if ex_names else '')
      + (' · MORE THAN ONE: the protocol runs one executor at a time, end the stale one first' if len(s['executors']) > 1 else ''))
    ss = s['session']
    if ss['verdict']:
        reg = ss['registered'] or 'null'
        if not ss['recorded']:
            reg = 'not recorded (registered before the field existed; taken as this session)'
        p(f"executor session: registered={reg} current={ss['current'] or 'null'} → {ss['verdict']}")
    fc = s.get('foreign')
    if fc is None:
        p('foreign commits: not checked (no manager marker)')
    elif fc.get('count'):
        p(f"foreign commits: {fc['count']} on the main tree with no running executor — {fc['reason']}")
    else:
        p('foreign commits: 0')
    p(f"remote jobs with no recorded end: {len(s['remotes'])}")
    for o in s['remotes']:
        p(f"  kind={o['kind']} sha={o['sha']} log={o['log']} host={o['host'] or '—'} started={o['startedAt']} terminal={o['terminal']}")
        for cmd in o.get('collect') or []:
            p(f"    collect: {cmd}")
    re_ = s.get('remoteEnd')
    if re_:
        p(f"last remote.end: {re_['at']} kind={re_['kind']} sha={re_['sha']} · executor moved since={'no' if re_['pending'] else 'yes (' + re_['movedBy'] + ')'}"
          + (f" · clock restarted by manager.resume {iso(re_['refTs'])}" if re_['resumed'] else '')
          + f" · wake after {re_['wakeAfter']} s")
    else:
        p('last remote.end: none this round')
    w = s['waiting']
    if w:
        what = f"workers {','.join(w['workers'])}" if w.get('workers') else f"remote {json.dumps(w.get('remote'), ensure_ascii=False)}"
        sat = {True: 'yes', False: 'no', None: 'unknown'}[w['satisfied']]
        p(f"executor.waiting: {w['at']} for {what} · still waiting={'yes' if w['pending'] else 'no'} · satisfied={sat}")
    else:
        p('executor.waiting: none')
    q = s['quota']
    if q:
        p(f"quota.hit: {q['at']} agent={q['agent'] or '—'} resets={q['resetsAt'] or q['resets']} · due={'yes' if q['due'] else 'no'}"
          f" · events since={'no' if q['pending'] else 'yes'}")
    else:
        p('quota.hit: none')
    pr = s['probe']
    if pr:
        p(f"remote probe (rc={pr['rc']}): {pr['cmd']}")
        for line in pr['output'].rstrip('\n').split('\n'):
            p(f"  {line}")
    else:
        p('remote probe: not run' if PROBE_CMD else 'remote probe: ROTATION_REMOTE_PROBE_CMD not set')
    p(s['action'])


def watch(stale, wake, dirty_age, floor):
    now = int(time.time())
    events = read_jsonl(EVENTS)
    rnd = current_round(read_jsonl(ROTATIONS))
    agents = agents_of(events, rnd['ts'])
    ex = executor_of(agents)
    who = (ex.get('id') or f"name:{ex['name']}") if ex else '—'

    multi = running_executors(agents)
    if len(multi) > 1:
        names = ','.join(f"{a['name']}({a.get('id') or 'no-id'})" for a in multi)
        return 'MULTI-EXECUTOR', f"MULTI-EXECUTOR n={len(multi)} executors={names} · one rotation executor at a time, end the stale one"

    q = quota_state(events, now)
    if q and q['pending'] and q['due']:
        return 'QUOTA', f"QUOTA resets={q['resetsAt']} passed, no event since {q['at']} · agent={q['agent'] or who}"

    w = waiting_state(events)
    if w and w['pending'] and w['satisfied'] and now - (w['refTs'] or 0) >= wake:
        what = f"workers={','.join(w['workers'])}" if w.get('workers') else f"remote={w['remote'].get('log')}"
        return 'WAKE', f"WAKE {what} is done, executor silent {now - w['refTs']} s since {iso(w['refTs'])} · agent={who}"

    # the same without an executor.waiting on record: a remote job of this round ended and nothing followed
    re_ = remote_end_state(events, rnd['ts'])
    if re_ and re_['pending'] and now - (re_['refTs'] or 0) >= WAKE_AFTER:
        since = f"manager.resume {iso(re_['refTs'])}" if re_['resumed'] else f"remote.end {re_['at']}"
        return 'WAKE', (f"WAKE remote.end kind={re_['kind']} sha={re_['sha']} log={re_['log']} is on record and no executor event followed "
                        f"for {now - re_['refTs']} s since {since} · agent={who}")

    # a worker the executor is waiting on whose transcript stopped: the executor would wait for it forever
    # once relayed (a manager.resume after it went dead?) it stays quiet until its transcript moves and stops again
    dead = [a for a in worker_states(agents, now, events, rnd['ts'])
            if a['transcript']['state'] == 'dead?' and not a['transcript']['relayedTs']]
    if dead:
        names = ','.join(f"{a['name']}({a.get('id')},{a['transcript']['age']}s)" for a in dead)
        return 'WAKE', (f"WAKE dead? worker(s) {names}: transcript not written for ≥ {WORKER_STALE} s while still registered "
                        f"as running · continue or end and re-dispatch (recover.sh) · agent={who}")

    fc = foreign_commits(rnd, agents, events)
    if fc and fc.get('count'):
        head = git('log', '-1', '--format=%h %s') or '?'
        return 'FOREIGN-COMMIT', f"FOREIGN-COMMIT n={fc['count']} head={head} · {fc['reason']} · agent={who}"

    acts = executor_events(events)
    if acts:
        last_act = acts[-1].get('ts') or 0
        late = [d for d in dirty_files()
                if d['mtime'] is not None and d['mtime'] - last_act >= dirty_age and now - d['mtime'] >= dirty_age]
        if late:
            names = ','.join(d['path'] for d in late[:5]) + (f",+{len(late) - 5}" if len(late) > 5 else '')
            return 'DIRTY', f"DIRTY n={len(late)} files={names} · last executor event {iso(last_act)} · agent={who}"

    act = activity(events, worktrees(base_branch()))
    ref = max(act['ts'] or 0, floor)
    if ref and now - ref >= stale:
        what = act['what'] if (act['ts'] or 0) >= floor else 'watchdog start'
        return 'STALE', f"STALE no event and no commit for {now - ref} s (last: {what} at {iso(ref)}) · agent={who}"
    return None, f"OK {iso(now)} last_activity={act['at']}"


def main(argv):
    if argv[:1] == ['recover']:
        scene = build_scene(probe='--no-probe' not in argv)
        if '--json' in argv:
            print(json.dumps(scene, ensure_ascii=False, indent=1))
        else:
            print_scene(scene)
        return 0
    if argv[:1] == ['watch']:
        opt = dict(zip(argv[1::2], argv[2::2]))
        reason, line = watch(int(opt['--stale']), int(opt['--wake']), int(opt['--dirty']), int(opt.get('--floor', 0)))
        print(line)
        return EXIT[reason] if reason else 0
    print('usage: recover_lib.py recover [--json] [--no-probe] | watch --stale S --wake S --dirty S [--floor TS]', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
