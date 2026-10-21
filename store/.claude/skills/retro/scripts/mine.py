#!/usr/bin/env python3
"""Extracts "the agent made a mistake here" signals from Claude Code transcripts.

Prints three blocks (as in `main()`): "User corrections", "Repeated tool
failures", "Expensive commands" (output volume of tools and Bash shapes).
Context is saved by truncating the texts; the agent then reads the result by eye.
"""
import argparse, json, pathlib, re, collections, sys, datetime, os

import subprocess

def _project_env():
    """PROJECT_ROOT, PROJECT_KEY, PROJECT_GIT_ORG: environment > agent-sync.env > defaults (bin/lib/project-env.sh)."""
    sync = os.environ.get('SYNC_HOME') or str(pathlib.Path.home() / '.agent-sync')
    lib = pathlib.Path(sync) / 'bin/lib/project-env.sh'
    out = subprocess.run(['bash', '-c', f'. "{lib}" && printf "%s\\n%s\\n%s" "$PROJECT_ROOT" "$PROJECT_KEY" "$PROJECT_GIT_ORG"'],
                         capture_output=True, text=True).stdout.split('\n')
    return out if len(out) == 3 else [os.environ.get('PROJECT_ROOT', ''), '', '']

PROJECT_ROOT, PROJECT_KEY, PROJECT_GIT_ORG = _project_env()
PROJ = pathlib.Path.home() / '.claude/projects' / PROJECT_KEY
HISTORY = pathlib.Path.home() / '.claude/history.jsonl'
# Lives in the skill directory so that agent-sync carries the date between machines.
LAST_RUN = pathlib.Path(__file__).resolve().parent.parent / 'last-run'
STAMP_FMT = '%Y-%m-%dT%H:%M'


def select_files(proj, stamp, n, default_n=40):
    """Sessions to analyze and the date of the previous retro, if the window starts from it."""
    files = sorted(proj.glob('*.jsonl'), key=lambda p: p.stat().st_mtime)
    if n is None and stamp.exists():
        since = stamp.read_text().strip()
        t = datetime.datetime.strptime(since, STAMP_FMT).timestamp()
        return [f for f in files if f.stat().st_mtime > t], since
    return files[-(n or default_n):], None


def mark(stamp, now=None):
    stamp.write_text((now or datetime.datetime.now()).strftime(STAMP_FMT) + '\n')

# Correction markers: the user objects to something already done.
# "look at what is wrong" is a task statement, not a correction, so "not so"
# counts only without request words nearby.
# Language-neutral English markers. Extra phrases for another language go in a
# local file next to this script; do not ship them in the template.
CORRECTION = re.compile(
    r'(i (already )?(said|asked|told you)|why did you|you (broke|deleted|removed)|'
    r'put it back|revert|that was not needed|that is not it|'
    r'\bwrong\b|again(\?| the same)|read carefully|i did not ask|'
    r'\bstop\b|how many times)',
    re.I)
TASK_MARKER = re.compile(r'(look at|check|find|why.{0,20}\?)', re.I)
# Cut off long task statements where the marker matched by chance.
MAX_CORRECTION_LEN = 400

# A tool failure is visible not only through is_error: Bash reports a non-zero code in the text.
FAILURE = re.compile(
    r'(Exit code [1-9]|command not found|No such file|not found for|unknown (flag|command)|'
    r'Permission for this action was denied|permission denied|'
    r'fatal:|error TS\d|SyntaxError|ModuleNotFoundError|has not been read yet)', re.I)


def human_turns(path):
    """(index, timestamp, text) of human messages; tool_results are dropped."""
    out = []
    for i, line in enumerate(path.open(errors='replace')):
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get('type') != 'user' or o.get('isSidechain'):
            continue
        if not o.get('promptSource'):       # no promptSource => this is a tool_result
            continue
        c = o['message'].get('content')
        if isinstance(c, list):
            c = ' '.join(b.get('text', '') for b in c if b.get('type') == 'text')
        if c and c.strip():
            out.append((i, o.get('timestamp', '')[:16], c.strip()))
    return out


def history_corrections(project_prefix, seen_session_ids):
    """Corrections from ~/.claude/history.jsonl, the shared message history of ALL projects.

    Unlike session transcripts (PROJ), this file is not cut into 100+ MB chunks:
    it holds only the text of user messages, without tool_use/tool_result, so
    it can be read whole. It helps for sessions that already fell out of the `-n` window
    of the transcripts, and for messages not tied to a specific tool (general
    style wishes). Sessions already analyzed from PROJ are skipped, otherwise
    the same correction would be counted twice.
    """
    out = []
    if not HISTORY.exists():
        return out
    for line in HISTORY.open(errors='replace'):
        try:
            o = json.loads(line)
        except Exception:
            continue
        project = o.get('project', '')
        if not project.startswith(project_prefix):
            continue
        sid = o.get('sessionId', '')
        if sid[:8] in seen_session_ids:
            continue
        text = (o.get('display') or '').strip()
        if not text or len(text) > MAX_CORRECTION_LEN:
            continue
        if not (CORRECTION.search(text) and not TASK_MARKER.search(text)):
            continue
        ts = o.get('timestamp')
        ts = ts and __import__('datetime').datetime.fromtimestamp(ts / 1000).strftime('%Y-%m-%dT%H:%M') or ''
        out.append((ts, sid[:8] or '?', text, ('history.jsonl', pathlib.Path(project).name)))
    return out


SELF_INVOCATION = re.compile(r'skills/retro/scripts/mine\.py')


def tool_calls(path):
    """(index, tool, short description of the input) and (index, error) by tool_use_id.

    Runs of mine.py itself (and their output) are excluded: otherwise the report of the previous
    /retro stays in the transcript and on the next run is counted as
    a new failure, so the reports would accumulate themselves.
    """
    calls, errors = {}, []
    ids = {}
    skip_ids = set()
    for i, line in enumerate(path.open(errors='replace')):
        try:
            o = json.loads(line)
        except Exception:
            continue
        msg = o.get('message') or {}
        content = msg.get('content')
        if not isinstance(content, list):
            continue
        for b in content:
            if b.get('type') == 'tool_use':
                inp = b.get('input') or {}
                brief = inp.get('command') or inp.get('file_path') or inp.get('pattern') or inp.get('query') or ''
                if b.get('name') == 'Bash' and SELF_INVOCATION.search(str(brief)):
                    skip_ids.add(b.get('id'))
                    continue
                ids[b.get('id')] = (b.get('name'), str(brief))
                calls[i] = (b.get('name'), str(brief))
            elif b.get('type') == 'tool_result':
                if b.get('tool_use_id') in skip_ids:
                    continue
                body = str(b.get('content'))
                if not (b.get('is_error') or FAILURE.search(body[:1500])):
                    continue
                name, brief = ids.get(b.get('tool_use_id'), ('?', ''))
                m = FAILURE.search(body[:1500])
                errors.append((i, name, brief, (m.group(0) + ' | ' if m else '') +
                               body[:160].replace('\n', ' ')))
    return calls, errors


def norm(cmd):
    """Normalizes a command to a "shape" to count repeats across sessions."""
    c = re.sub(r'/tmp/\S+|/home/\S+', 'PATH', cmd)
    c = re.sub(r'\b\d{3,}\b', 'N', c)
    return ' '.join(c.split()[:6])[:90]


_SHAPE_TOOLS = (
    'git', 'gh', 'herdr', 'npm', 'npx', 'pnpm', 'mysql', 'curl',
    'jq', 'rg', 'psql', 'docker', 'claude',
)


def shape(cmd):
    """Reduces a Bash command to a shape for aggregating the output volume."""
    first = re.split(r'\s*(?:&&|\|\||;|\||\n)\s*', (cmd or '').strip())
    parts = []
    for seg in first:
        seg = seg.strip()
        if not seg or seg.startswith(('cd ', 'echo ')):
            continue
        toks = seg.split()
        while toks and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', toks[0]):
            toks = toks[1:]
        if not toks:
            continue
        head = toks[0]
        if head in _SHAPE_TOOLS:
            if head == 'git' and len(toks) > 2 and toks[1] == '-C':
                sub = [t for t in toks[3:5] if not t.startswith('-') and '/' not in t and not t.isdigit()][:1]
            else:
                # 1 subcommand (herdr workspace; git status); npm/pnpm up to 2 (npm run)
                limit = 2 if head in ('npm', 'npx', 'pnpm') else 1
                sub = [t for t in toks[1:4] if not t.startswith('-') and '/' not in t and not t.isdigit()][:limit]
            parts.append(' '.join([head] + sub))
        else:
            parts.append(os.path.basename(head))
        if len(parts) >= 3:
            break
    return ' ; '.join(parts) or '?'


def _result_text(content):
    if isinstance(content, list):
        return ' '.join(
            x.get('text', '') for x in content if isinstance(x, dict)
        )
    return str(content or '')


def tool_output_sizes(path):
    """Sums of output characters per tool and per Bash shape; mine.py is excluded."""
    tools = collections.defaultdict(lambda: {'n': 0, 'chars': 0})
    shapes = collections.defaultdict(lambda: {'n': 0, 'chars': 0})
    uses = {}
    skip_ids = set()
    for line in path.open(errors='replace'):
        try:
            o = json.loads(line)
        except Exception:
            continue
        content = (o.get('message') or {}).get('content')
        if not isinstance(content, list):
            continue
        for b in content:
            if b.get('type') == 'tool_use':
                inp = b.get('input') or {}
                cmd = inp.get('command', '') if b.get('name') == 'Bash' else ''
                if b.get('name') == 'Bash' and SELF_INVOCATION.search(str(cmd)):
                    skip_ids.add(b.get('id'))
                    continue
                uses[b.get('id')] = (b.get('name'), cmd)
            elif b.get('type') == 'tool_result':
                tid = b.get('tool_use_id')
                if tid in skip_ids:
                    continue
                name, cmd = uses.get(tid, ('?', ''))
                n = len(_result_text(b.get('content')))
                tools[name]['n'] += 1
                tools[name]['chars'] += n
                if name == 'Bash':
                    s = shape(cmd)
                    shapes[s]['n'] += 1
                    shapes[s]['chars'] += n
    return dict(tools), dict(shapes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-n', '--sessions', type=int,
                    help='how many latest sessions to take (default: all since the previous retro, 40 without a date)')
    ap.add_argument('--mark', action='store_true',
                    help='write the current time as the date of the previous retro and exit')
    ap.add_argument('--min-repeat', type=int, default=2, help='repeat threshold for the failures block')
    ap.add_argument('--min-sessions', type=int, default=5,
                    help='session threshold for Bash shapes in the expensive commands block')
    ap.add_argument('--no-history', action='store_true',
                     help='do not mix in ~/.claude/history.jsonl (transcripts only)')
    a = ap.parse_args()

    if a.mark:
        mark(LAST_RUN)
        print(f'retro date written to {LAST_RUN}: {LAST_RUN.read_text().strip()}')
        return

    files, since = select_files(PROJ, LAST_RUN, a.sessions)
    if not files:
        sys.exit(f'no transcripts in {PROJ}' + (f' newer than {since}' if since else ''))

    corrections, err_forms = [], collections.defaultdict(list)
    tool_tot = collections.defaultdict(lambda: {'n': 0, 'chars': 0})
    shape_tot = collections.defaultdict(lambda: {'n': 0, 'chars': 0, 'sess': set()})
    seen_session_ids = set()
    for f in files:
        sid = f.stem[:8]
        seen_session_ids.add(sid)
        turns = human_turns(f)
        calls, errors = tool_calls(f)
        call_idx = sorted(calls)
        for idx, ts, text in turns:
            if (len(text) <= MAX_CORRECTION_LEN and CORRECTION.search(text)
                    and not TASK_MARKER.search(text)):
                prev = [j for j in call_idx if j < idx]
                before = calls[prev[-1]] if prev else ('—', '')
                corrections.append((ts, sid, text, before))
        for idx, name, brief, msg in errors:
            err_forms[(name, norm(brief))].append((sid, msg))
        tools, shapes = tool_output_sizes(f)
        for name, v in tools.items():
            tool_tot[name]['n'] += v['n']
            tool_tot[name]['chars'] += v['chars']
        for form, v in shapes.items():
            shape_tot[form]['n'] += v['n']
            shape_tot[form]['chars'] += v['chars']
            shape_tot[form]['sess'].add(sid)

    hist_corrections = []
    if not a.no_history:
        # PROJ holds the transcripts of this project only (the project directory in ~/.claude/projects),
        # so we filter history.jsonl by the same root, to avoid pulling in messages
        # from the user's personal or third-party projects.
        hist_corrections = history_corrections(PROJECT_ROOT, seen_session_ids)
        corrections.extend(hist_corrections)
    corrections.sort(key=lambda c: c[0])

    print(f'# sessions analyzed (transcripts): {len(files)}  ({files[0].stem[:8]} … {files[-1].stem[:8]})')
    print(f'# window: since the previous retro {since}' if since else
          f'# window: last {len(files)} sessions' + ('' if LAST_RUN.exists() else f': no date of the previous retro ({LAST_RUN})'))
    if not a.no_history:
        print(f'# + history.jsonl: {len(hist_corrections)} corrections from sessions outside the -n window '
              f'(source declared in SKILL.md, was not scanned before)')
    print()

    print(f'## User corrections ({len(corrections)})\n')
    for ts, sid, text, before in corrections:
        tool, brief = before
        print(f'- [{ts} {sid}] «{text[:220]}»')
        print(f'    before this: {tool} {brief[:110]}')

    print(f'\n## Repeated tool failures (>= {a.min_repeat})\n')
    rows = sorted(((len(v), k, v) for k, v in err_forms.items()), reverse=True)
    for cnt, (name, form), v in rows:
        if cnt < a.min_repeat:
            continue
        sessions = len(set(s for s, _ in v))
        print(f'- {cnt}x (sessions: {sessions}) {name}: {form}')
        print(f'    example: {v[0][1][:150]}')

    print('\n## Expensive commands\n')
    print('### Tools (top 12 by output characters)\n')
    for name, v in sorted(tool_tot.items(), key=lambda x: -x[1]['chars'])[:12]:
        print(f'- {v["chars"]} characters, {v["n"]} calls, {name}')
    print(f'\n### Bash shapes (top 30, sessions >= {a.min_sessions})\n')
    shape_rows = [
        (form, v) for form, v in shape_tot.items()
        if len(v['sess']) >= a.min_sessions
    ]
    for form, v in sorted(shape_rows, key=lambda x: -x[1]['chars'])[:30]:
        avg = v['chars'] // max(v['n'], 1)
        print(f'- {v["chars"]} characters, {v["n"]} calls, {len(v["sess"])} sessions, '
              f'average {avg}, {form}')


if __name__ == '__main__':
    main()
