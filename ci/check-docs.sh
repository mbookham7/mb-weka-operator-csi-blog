#!/usr/bin/env bash
#
# Do the docs still hang together?
#
# WHY THIS EXISTS
#
# The README used to be 1133 lines and is now a summary with a page per topic
# behind it. Easier to read, and much easier to break: every cross-page link
# is a relative path plus an anchor derived from a heading, and renaming a
# heading silently breaks every link pointing at it. Nothing about a broken
# markdown link fails loudly -- it renders as a link, and 404s only when
# somebody clicks it.
#
# Two checks:
#
#   1. Every relative link resolves -- the file exists, and if there is a
#      #fragment, some heading in that file actually produces it.
#   2. Every page under docs/ is reachable from the README. An orphan page is
#      documentation nobody will ever find, which is the same as not having
#      written it.
#
# External (http/https) links are NOT checked. This runs in CI on every push
# and should not fail because somebody else's site is down.
#
# Usage:  ./ci/check-docs.sh
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

python3 - <<'PY'
import re, os, glob, sys

def anchors(path):
    """The anchors GitHub generates from the headings in a file."""
    out, fence = set(), False
    for line in open(path):
        if line.startswith('```'):
            fence = not fence
            continue
        if fence:
            continue
        m = re.match(r'^#{1,6} (.+?)\s*$', line)
        if not m:
            continue
        t = m.group(1)
        t = re.sub(r'`([^`]*)`', r'\1', t)                # code ticks drop out
        t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)    # links keep their label
        out.add(re.sub(r'[^\w\s-]', '', t.lower()).strip().replace(' ', '-'))
    return out

files = ['README.md'] + sorted(glob.glob('docs/*.md'))
fails = []

# --- 1. every relative link resolves ------------------------------------
links = 0
for f in files:
    base = os.path.dirname(f)
    for m in re.finditer(r'\[([^\]]+)\]\(([^)]+)\)', open(f).read()):
        label, target = m.group(1), m.group(2)
        if target.startswith(('http://', 'https://', 'mailto:')):
            continue
        links += 1
        path_part, _, frag = target.partition('#')
        tgt = os.path.normpath(os.path.join(base, path_part)) if path_part else f
        if path_part and not os.path.exists(tgt):
            fails.append(f'{f}: link to a file that does not exist -> {target}  ({label})')
            continue
        if frag and frag not in anchors(tgt):
            fails.append(f'{f}: link to an anchor that does not exist -> {target}  ({label})')
print(f'  checked {links} relative links across {len(files)} files')

# --- 2. no orphan pages --------------------------------------------------
readme = open('README.md').read()
for page in sorted(glob.glob('docs/*.md')):
    if page not in readme and os.path.basename(page) not in readme:
        fails.append(f'{page}: not linked from README.md -- an orphan page is documentation nobody finds')
print(f'  checked {len(glob.glob("docs/*.md"))} pages are reachable from the README')

if fails:
    print()
    print('DOCS CHECK FAILED:')
    for x in fails:
        print('  ' + x)
    sys.exit(1)
print()
print('Docs check passed -- every link resolves and every page is reachable.')
PY
