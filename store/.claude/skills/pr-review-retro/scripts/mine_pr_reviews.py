#!/usr/bin/env python3
"""Pulls reviewer comments on the user's merged PRs from GitHub and groups
similar ones by text, to show which remarks repeat across PRs/repos.

It does not classify by bug category: the agent does that by reading the output (see SKILL.md).
"""
import argparse, json, subprocess, pathlib, re, collections, sys
import os, subprocess

SYNC_HOME = pathlib.Path(os.environ.get('SYNC_HOME') or pathlib.Path.home() / '.agent-sync')


def _project_env():
    """PROJECT_ROOT, PROJECT_KEY, PROJECT_GIT_ORG: environment > agent-sync.env > defaults (bin/lib/project-env.sh)."""
    lib = SYNC_HOME / 'bin/lib/project-env.sh'
    out = subprocess.run(['bash', '-c', f'. "{lib}" && printf "%s\\n%s\\n%s" "$PROJECT_ROOT" "$PROJECT_KEY" "$PROJECT_GIT_ORG"'],
                         capture_output=True, text=True).stdout.split('\n')
    return out if len(out) == 3 else [os.environ.get('PROJECT_ROOT', ''), '', '']


PROJECT_ROOT, PROJECT_KEY, PROJECT_GIT_ORG = _project_env()

BASE = pathlib.Path(PROJECT_ROOT)

TRIVIAL = re.compile(r'^(lgtm|nice|thanks|thank you|👍|✅|\+1|good|ok|approved?)\W*$', re.I)


def sh(cmd, cwd=None):
    r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return r.stdout.strip()


def find_repos():
    return [p for p in sorted(BASE.iterdir()) if (p / '.git').exists()]


def repo_slug(repo):
    return sh('gh repo view --json nameWithOwner -q .nameWithOwner', cwd=repo) or None


def norm(text):
    """Normalizes a comment text to a "shape" to merge repeats."""
    t = re.sub(r'```.*?```', ' CODE ', text, flags=re.S)
    t = re.sub(r'`[^`]*`', 'CODE', t)
    t = re.sub(r'https?://\S+', 'URL', t)
    t = re.sub(r'\b\d+\b', 'N', t)
    t = re.sub(r'\s+', ' ', t).strip().lower()
    return ' '.join(t.split()[:10])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repos', nargs='*', help='names of subfolders in PROJECT_ROOT/ (default: all with .git)')
    ap.add_argument('-n', '--prs', type=int, default=10, help='how many latest merged PRs to take per repo')
    ap.add_argument('--min-repeat', type=int, default=2, help='repeat threshold to show a group')
    a = ap.parse_args()

    repos = [BASE / r for r in a.repos] if a.repos else find_repos()
    author = sh('gh api user -q .login')
    if not author:
        sys.exit('gh is not authenticated (gh auth status)')

    forms = collections.defaultdict(list)
    total = 0
    scanned_prs = 0
    seen_slugs = {}
    skipped = []

    for repo in repos:
        if not (repo / '.git').exists():
            continue
        slug = repo_slug(repo)
        if not slug:
            continue
        if slug in seen_slugs:
            # the same remote (nameWithOwner) was already scanned through another checkout:
            # a worktree/duplicate clone of the same repo, otherwise PRs/comments would be counted twice
            skipped.append((repo.name, slug, seen_slugs[slug]))
            continue
        seen_slugs[slug] = repo.name
        prs_json = sh(
            f'gh pr list --author {author} --state merged --limit {a.prs} '
            f'--json number,title,url', cwd=repo)
        try:
            prs = json.loads(prs_json) if prs_json else []
        except Exception:
            prs = []
        for pr in prs:
            scanned_prs += 1
            num = pr['number']
            raw = sh(
                f'gh api repos/{slug}/pulls/{num}/comments --paginate '
                f'-q ".[] | {{user: .user.login, path: .path, line: .line, body: .body}}"',
                cwd=repo)
            for line in raw.splitlines():
                try:
                    c = json.loads(line)
                except Exception:
                    continue
                if c.get('user') == author:
                    continue
                body = (c.get('body') or '').strip()
                if not body or TRIVIAL.match(body):
                    continue
                total += 1
                entry = (slug, num, pr.get('title', ''), c.get('user'),
                         c.get('path'), c.get('line'), body)
                forms[norm(body)].append(entry)

    print(f'# repos scanned: {len(seen_slugs)}, PRs scanned: {scanned_prs}, '
          f'reviewer comments (non-trivial): {total}\n')
    if skipped:
        print(f'# skipped duplicate checkouts (same remote, other worktree/clone): {len(skipped)}')
        for name, slug, orig in skipped:
            print(f'    {name} -> same repo as {orig} ({slug})')
        print()

    print(f'## Repeated reviewer remarks (>= {a.min_repeat})\n')
    rows = sorted(((len(v), k, v) for k, v in forms.items()), reverse=True)
    shown = 0
    for cnt, form, v in rows:
        if cnt < a.min_repeat:
            continue
        shown += 1
        repos_hit = len(set(e[0] for e in v))
        print(f'- {cnt}x (repos: {repos_hit}) "{form}"')
        for e in v[:4]:
            print(f'    {e[0]}#{e[1]} ({e[3]}) {e[4]}:{e[5]} — {e[6][:200]}')
        print()
    if not shown:
        print('(no repeats found: either little data or the remarks differ every time)\n')


if __name__ == '__main__':
    main()
