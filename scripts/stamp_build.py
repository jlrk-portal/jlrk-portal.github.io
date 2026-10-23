# -*- coding: utf-8 -*-
"""배포 직전 BUILD 를 현재 시각(KST)으로 갈아끼운다.
   캐시된 옛 화면으로 적재하면 결과가 달라져서, 화면에서 빌드를 보고
   최신인지 확인할 수 있어야 한다. (2026-10-23)"""
import io, re, sys, datetime, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
stamp = (datetime.datetime.utcnow() + datetime.timedelta(hours=9)).strftime('%m-%d %H:%M')
for rel in ['staging/index.html', 'index.html']:
    p = root / rel
    if not p.exists(): continue
    s = io.open(p, encoding='utf-8').read()
    n = s
    n = re.sub(r"const BUILD = '[^']*';", f"const BUILD = '{stamp}';", n, count=1)
    if n != s:
        io.open(p, 'w', encoding='utf-8').write(n)
        print(f'  {rel} → build {stamp}')
    else:
        print(f'  {rel} — BUILD 자리를 찾지 못했습니다', file=sys.stderr)
