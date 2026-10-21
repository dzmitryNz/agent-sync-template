#!/usr/bin/env python3
"""Parses [REVIEW RESULT] from transcripts (the agent-review result goes only to the herdr pane,
not to GitHub) and groups findings by the key [<category>/<key>] from
agent-review/review-keys.md. Findings without a key (old reviews) are listed for
manual classification.
"""
import argparse, collections, hashlib, json, pathlib, re
import os, subprocess

SYNC_HOME = pathlib.Path(os.environ.get('SYNC_HOME') or pathlib.Path.home() / '.agent-sync')


def _project_env():
    """PROJECT_ROOT, PROJECT_KEY, PROJECT_GIT_ORG: environment > agent-sync.env > defaults (bin/lib/project-env.sh)."""
    lib = SYNC_HOME / 'bin/lib/project-env.sh'
    out = subprocess.run(['bash', '-c', f'. "{lib}" && printf "%s\\n%s\\n%s" "$PROJECT_ROOT" "$PROJECT_KEY" "$PROJECT_GIT_ORG"'],
                         capture_output=True, text=True).stdout.split('\n')
    return out if len(out) == 3 else [os.environ.get('PROJECT_ROOT', ''), '', '']


PROJECT_ROOT, PROJECT_KEY, PROJECT_GIT_ORG = _project_env()

PROJECTS = pathlib.Path.home() / '.claude/projects'
PREFIX = PROJECT_KEY

MARK = '[REVIEW RESULT]'
VERDICT = re.compile(r'(?:Verdict:)\s*`?([a-z-]+)', re.I)
PR_URL = re.compile(r'github\.com/[\w.-]+/([\w.-]+)/pull/(\d+)')
PR_NUM = re.compile(r'PR\s*#(\d+)')
ITEM = re.compile(r'^\s*(\d+)\.\s+(.+)$')
KEY = re.compile(r'^\[([a-z]+)/([a-z0-9-]+)\]\s*')
# Synonyms reviewers invent outside review-keys.md -> canonical (cat, key).
# Matched by key alone first, then by cat/key.
KEY_ALIASES = {
    'pr-body-mismatch': ('style', 'pr-body-inaccurate'),
    'pr-body-claim': ('style', 'pr-body-inaccurate'),
    'body-mismatch': ('style', 'pr-body-inaccurate'),
    'pr-body-inaccurate': ('style', 'pr-body-inaccurate'),
    'stale-comment': ('style', 'stale-comment'),
    'stale-claim': ('style', 'doc-stale-claim'),
    'coverage-gap': ('correctness', 'test-gap'),
    'missing-case': ('correctness', 'test-gap'),
    'test-gap': ('correctness', 'test-gap'),
    'mirror-implementation': ('correctness', 'test-mirrors-impl'),
    'test-mirrors-impl': ('correctness', 'test-mirrors-impl'),
}


def canonical(cat, key):
    if key in KEY_ALIASES:
        return KEY_ALIASES[key]
    return cat, key


SECTION = re.compile(r'^\s*(Blockers?|Fix before merge|Minor)\b', re.I)
SEV_INLINE = re.compile(r'\b(Blocker|Fix before merge|Minor)\b', re.I)


BASE = pathlib.Path(PROJECT_ROOT)


def remote_names():
    names = set()
    for p in BASE.iterdir() if BASE.is_dir() else []:
        cfg = p / '.git' / 'config'
        if cfg.is_file():
            m = re.search(r'url\s*=\s*\S*[/:][\w.-]+/([\w.-]+?)(?:\.git)?\s*$', cfg.read_text(errors='replace'), re.M)
            if m:
                names.add(m.group(1))
    return sorted(names, key=len, reverse=True)


REPOS = remote_names()


def repo_of(cwd):
    """Worktree `acme-api-task-123` -> `acme-api`; project root -> '?'."""
    name = pathlib.Path(cwd or '?').name
    for r in REPOS:
        if name == r or name.startswith(r + '-'):
            return r
    alias = ALIASES.get(name.split('-')[0])
    if alias:
        return alias
    return '?' if name == BASE.name else name


# Worktree prefixes in .worktrees/ are the same as in bin/wt-short-names.conf (<repo> = <prefix>).
def _aliases():
    out = {}
    conf = SYNC_HOME / 'bin/wt-short-names.conf'
    for line in conf.read_text().splitlines() if conf.is_file() else []:
        m = re.match(r'\s*([\w.-]+)\s*=\s*([\w.-]+)', line)
        if m:
            out[m.group(2)] = m.group(1)
    return out


ALIASES = _aliases()


def texts(rec):
    content = (rec.get('message') or {}).get('content')
    if isinstance(content, str):
        yield content
        return
    for b in content or []:
        if b.get('type') == 'text':
            yield b.get('text') or ''
        elif b.get('type') == 'tool_use':
            yield (b.get('input') or {}).get('command') or ''


def blocks(text):
    parts = text.split(MARK)[1:]
    for p in parts:
        yield p.split('[REVIEW REQUEST]')[0]


def parse(block, cwd):
    head = block[:600]
    m = VERDICT.search(head)
    if not m:
        return None
    verdict = m.group(1).lower()
    url = PR_URL.search(block)
    if url:
        repo, pr = url.group(1), url.group(2)
    else:
        n = PR_NUM.search(head)
        pr = n.group(1) if n else '?'
        repo = repo_of(cwd)
    items, sev = [], None
    cur = None
    for line in block.splitlines():
        s = SECTION.match(line)
        if s and not ITEM.match(line):
            sev = s.group(1).lower().rstrip('s')
            continue
        if line.strip().startswith('Checked'):
            break
        it = ITEM.match(line)
        if it:
            body = it.group(2).strip()
            k = KEY.match(body)
            inline = SEV_INLINE.search(body[:40])
            cat, key = canonical(k.group(1), k.group(2)) if k else (None, None)
            cur = {
                'cat': cat,
                'key': key,
                'sev': (inline.group(1).lower() if inline else sev) or '?',
                'text': KEY.sub('', body),
            }
            items.append(cur)
        elif cur and line.startswith(('   ', '\t')) and line.strip():
            cur['text'] += ' ' + line.strip()
        elif not line.strip():
            cur = None
    return {'repo': repo, 'pr': pr, 'verdict': verdict, 'items': items}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--min-repeat', type=int, default=2, help='key repeat threshold')
    ap.add_argument('--max-untagged', type=int, default=80, help='how many findings without a key to show')
    ap.add_argument('--since', default='', help='YYYY-MM-DD: only reviews not older than the date (check against the protocol)')
    a = ap.parse_args()

    seen = set()
    reviews = 0
    by_key = collections.defaultdict(list)
    untagged = []
    for f in sorted(PROJECTS.glob(PREFIX + '*/**/*.jsonl')):
        for line in f.open(errors='replace'):
            if MARK not in line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if a.since and (rec.get('timestamp') or '') < a.since:
                continue
            for t in texts(rec):
                t = t.replace('\\n', '\n')
                for b in blocks(t):
                    r = parse(b, rec.get('cwd'))
                    if not r or not r['items']:
                        continue
                    rid = hashlib.md5(f"{r['repo']}#{r['pr']}{b[:400]}".encode()).hexdigest()
                    if rid in seen:
                        continue
                    seen.add(rid)
                    reviews += 1
                    for it in r['items']:
                        entry = (r['repo'], r['pr'], it['sev'], it['text'])
                        if it['key']:
                            by_key[(it['cat'], it['key'])].append(entry)
                        else:
                            untagged.append(entry)

    print(f'# reviews parsed: {reviews}, findings with a key: '
          f'{sum(map(len, by_key.values()))}, without a key: {len(untagged)}\n')
    print(f'## Repeated keys (>= {a.min_repeat} different PRs)\n')
    shown = 0
    for (cat, key), v in sorted(by_key.items(), key=lambda kv: -len(kv[1])):
        prs = sorted({f'{r}#{p}' for r, p, *_ in v})
        if len(prs) < a.min_repeat:
            continue
        shown += 1
        print(f'- [{cat}/{key}] {len(v)}x, PR: {", ".join(prs)}')
        for r, p, sev, text in v[:4]:
            print(f'    {r}#{p} ({sev}) {text[:180]}')
        print()
    if not shown:
        print('(no repeats by key)\n')
    print(f'## Without a key (first {a.max_untagged}): classify by hand\n')
    for r, p, sev, text in untagged[:a.max_untagged]:
        print(f'- {r}#{p} ({sev}) {text[:180]}')


if __name__ == '__main__':
    main()
