# 작업폴더 iCloud Drive 이전 (2026-09-27) — 구조와 규칙

> 두 봇의 작업폴더를 iCloud Drive 안 `Claude` 폴더로 옮겼다.
> **git 메타데이터와 Python venv는 iCloud에 넣지 않는다** — 이게 이 구조의 핵심이다.

## 실제 위치

| 봇 / 용도 | 실제 위치 | 옛 경로 (심볼릭링크로 유지) |
|---|---|---|
| 정산/CC 봇 | `~/icloud/Claude/jlrk-settlement` | `~/Desktop/jlrk-settlement` |
| 비서(PA) 봇 | `~/icloud/Claude/pa` | `~/pa` |

- `~/icloud` → `~/Library/Mobile Documents/com~apple~CloudDocs` (iCloud Drive 루트)
  경로에 공백이 있어서(`Mobile Documents`) 명령마다 따옴표를 붙이는 걸 피하려고 만든 링크다.
- **옛 경로도 그대로 쓸 수 있다.** `~/pa`, `~/Desktop/jlrk-settlement` 는 새 위치를 가리키는
  심볼릭링크라서 `cd ~/pa` 든 `cd ~/icloud/Claude/pa` 든 같은 폴더다.

## 왜 심볼릭링크를 남겼나

`~/pa` 안 스크립트 **40개**가 `/Users/youngjung/pa/...` 절대경로를 하드코딩하고 있었다.
링크를 남기지 않으면 그 스크립트가 전부 깨진다. `~/.zshenv` 의 `PPT_PY` 도 이 경로를 쓴다.

→ **옛 경로 심볼릭링크는 지우지 말 것.**

## iCloud에 넣지 않은 것 (의도적)

| 대상 | 실제 위치 | 연결 방식 |
|---|---|---|
| 정산포털 `.git` | `~/.local/claude-git/jlrk-settlement.git` | 작업폴더의 `.git` **파일**에 `gitdir:` 한 줄 |
| slide-master `.git` | `~/.local/claude-git/slide-master.git` | 같음 |
| slide-master `.venv` (226MB) | `~/.local/claude-venvs/slide-master-venv` | `.venv` 심볼릭링크 |

**이유:**
- **`.git`**: iCloud가 loose object·index·packfile을 각각 따로 동기화하다가 git 작업 중간 상태를
  올려버리면 저장소가 깨진다. 실제로 흔한 사고다. `git init --separate-git-dir` 로 분리했다.
- **`.venv`**: 파일 1만 개 이상 + 절대경로가 내부에 박혀 있어 동기화 대상으로 최악이다.

git 명령은 평소처럼 쓰면 된다 (`git -C ~/Desktop/jlrk-settlement status` 도 동작).
`--separate-git-dir` 는 `.git` 을 디렉터리에서 파일로 바꾼 것뿐이고, remote·브랜치·이력은 그대로다.

> ⚠️ 저장소를 **다시 clone 하거나 폴더를 또 옮기면** 이 분리가 풀린다.
> 옮긴 뒤 `git status` 가 `not a git repository` 라고 하면 `.git` 파일 안의 `gitdir:` 경로와
> `~/.local/claude-git/<repo>.git/config` 의 `core.worktree` 를 새 경로로 고치면 된다.

## Claude Code 기억·세션기록 (중요)

Claude Code는 대화기록과 `memory/`(= `MEMORY.md`)를 **작업폴더 절대경로를 슬러그로 바꾼**
디렉터리에 저장한다. 폴더를 옮기면 슬러그가 바뀌어서 **기억이 안 읽힌다.** 그래서 같이 옮겼다.

```
~/.claude/projects/-Users-youngjung-Library-Mobile-Documents-com-apple-CloudDocs-Claude-jlrk-settlement
~/.claude/projects/-Users-youngjung-Library-Mobile-Documents-com-apple-CloudDocs-Claude-pa
```

옛 슬러그 디렉터리(`-Users-youngjung-pa` 등)는 새 쪽을 가리키는 심볼릭링크로 남겨뒀다.
(슬러그 규칙: 절대경로의 영숫자 아닌 문자를 전부 `-` 로 치환)

> 앞으로 작업폴더를 옮길 때는 **이 디렉터리도 같이 옮겨야 한다.** 안 옮기면 두 봇이
> 기억을 전부 잃은 것처럼 행동한다.

## 알아둘 부작용

- **"저장공간 최적화"를 켜지 말 것.** iCloud가 안 쓰는 파일을 플레이스홀더로 바꾸면
  `python`·`grep` 이 파일을 읽는 순간 다운로드를 기다리며 멈춘다. 오프라인이면 실패한다.
  (시스템 설정 → Apple 계정 → iCloud → iCloud Drive)
- 첫 업로드는 3.4GB(pa 2.8GB + 정산 0.6GB)라 시간이 걸린다. 진행상황:
  ```
  brctl status | grep -c needs-upload
  ```
- 정산포털의 `ASAP Program Support`(504MB)는 `.gitignore` 대상이라 GitHub엔 없었다.
  이제 iCloud에 올라가므로 이 원본데이터도 백업된다 — 이전의 실질적 이득.

## 되돌리는 방법

```
mv ~/icloud/Claude/pa /tmp/pa.tmp
rm ~/pa
mv /tmp/pa.tmp ~/pa
```

정산포털도 같은 식으로 `~/Desktop/` 으로 되돌리고, `~/.claude/projects/` 의 슬러그 디렉터리를
옛 이름으로 되돌린 뒤 `~/.zshrc` alias 를 원복하면 된다.
