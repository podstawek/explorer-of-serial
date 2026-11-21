#!/usr/bin/env python3
"""Citation audit: every `file.ext:line[,...][-range]` reference in RESULT.md
must resolve to an existing file (evidence/ first, then workspace root) and
every cited line number must be within the file's line count."""
import re, os, sys
WS = os.environ.get("CITE_WS", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
res = re.compile(r'([A-Za-z0-9_./-]+\.(?:log|txt|py|md|bin|s1|bin))[: ](\d+(?:\s*[-,]\s*\d+)*)')
text = open(os.path.join(WS, "RESULT.md")).read()
# also scan FINDINGS.md refs only when explicitly "FINDINGS.md:"
problems, seen, ok = [], set(), 0
for m in res.finditer(text):
    f, lns = m.group(1), m.group(2)
    key = (f, lns)
    if key in seen: continue
    seen.add(key)
    base = f if f.startswith("evidence/") else f
    cand = [os.path.join(WS, base), os.path.join(WS, "evidence", os.path.basename(f)), os.path.join(WS, f)]
    path = next((c for c in cand if os.path.isfile(c)), None)
    if path is None:
        problems.append(f"MISSING FILE: {f}:{lns}")
        continue
    n = sum(1 for _ in open(path, errors="replace"))
    for tok in re.split(r'\s*,\s*', lns):
        if '-' in tok:
            a, b = [int(x) for x in re.split(r'\s*-\s*', tok)]
        else:
            a = b = int(tok)
        if a < 1 or b > n:
            problems.append(f"OUT OF RANGE: {f}:{tok} (file has {n} lines)")
        else:
            ok += 1
print(f"citation audit: {ok} refs resolve, {len(problems)} problems")
for p in problems: print("  " + p)
sys.exit(1 if problems else 0)
