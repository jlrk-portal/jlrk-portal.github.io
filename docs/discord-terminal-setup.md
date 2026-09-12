# 터미널에서 디스코드 완전 연동 — 런북

> Claude Code를 터미널에서 실행할 때 디스코드 채널(인바운드 + 아웃바운드)을
> 붙이는 절차. **핵심은 실행 플래그 `--channels plugin:discord@claude-plugins-official` 하나.**
>
> ⚠️ 문법 변경(2026-09): `--channels` 항목은 이제 태그가 필수다.
> 플러그인 채널은 `plugin:<플러그인>@<마켓플레이스>`, 수동 MCP 서버는 `server:<이름>`.
> 예전 `plugin:discord:discord`는 `--channels entries must be tagged` 오류가 난다.

## 왜 필요한가 (원인)

- 디스코드 연동은 `discord@claude-plugins-official` 플러그인의 MCP 서버(내부 식별자 `plugin:discord:discord`)가 담당.
- 봇 토큰만 있으면 **아웃바운드**(답장, 메시지 조회)는 항상 동작한다.
- **인바운드**(디스코드에서 봇을 부르면 → 터미널 세션으로 전달)는 세션이
  `--channels` 목록에 그 서버를 포함한 채로 시작됐을 때만 동작한다.
- `--channels` 없이 그냥 `claude`로 켜면 MCP 서버는 메시지를 받지만 Claude Code가
  `Channel notifications skipped: server plugin:discord:discord not in --channels list for this session`
  로 **조용히 버린다**. (2026-09-03 연결 끊김 사고의 실제 원인)
- 채널은 **세션 시작 시점에만** 붙일 수 있다. 실행 중에는 추가 불가.

## 0. 사전 점검 (최초 1회, 현재 모두 정상 — 확인만)

봇 토큰 설정 여부:

```bash
sed 's/=.*/=<설정됨>/' ~/.claude/channels/discord/.env
```

접근 정책 (allowlist + 그룹 멘션 규칙):

```bash
cat ~/.claude/channels/discord/access.json
```

디스코드 플러그인 활성 여부:

```bash
grep -A2 enabledPlugins ~/.claude/settings.json
```

기대값:
- 토큰: `DISCORD_BOT_TOKEN=<설정됨>`
- access.json: `"dmPolicy": "allowlist"`, `allowFrom`에 사용자 ID 1개,
  `groups`에 그룹 채널 1개(`"requireMention": true`)
- settings.json: `"discord@claude-plugins-official": true`

셋 다 이미 설정돼 있으므로 손댈 것 없음. 토큰·access.json은
`~/.claude/channels/discord/`에 **전역** 저장 → 어느 폴더에서 켜든 동일 적용.

## 1. 기존 세션 정리 (꼬였을 때만)

지금 떠 있는 claude 세션:

```bash
ps ax -o pid,etime,command | grep -E '[c]laude'
```

디스코드 채널 소유 락 — 인바운드는 한 세션만 받을 수 있다.
PID가 죽어 있으면 새 세션이 자동 인수하므로 무시해도 된다.

```bash
cat ~/.claude/plugins/cache/claude-plugins-official/discord/0.0.4/.in_use/* 2>/dev/null
```

보통은 기존 `claude` 창을 `Ctrl-C`로 종료만 하면 충분.

## 2. 디스코드 채널을 붙여서 실행 ← 핵심

```bash
cd ~/Desktop/jlrk-settlement
claude --channels plugin:discord@claude-plugins-official
```

- 이전 대화를 이어서: `claude --continue --channels plugin:discord@claude-plugins-official`
- 채널이 여러 개면 공백으로 나열:
  `claude --channels plugin:discord@claude-plugins-official server:slack`

## 3. 연동 확인

새 세션이 뜨면 디스코드 그룹 채널에서 봇을 멘션:

```
@봇이름  테스트
```

이 메시지가 터미널 세션으로 들어오면 성공.

로그로도 확인:

```bash
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-youngjung-Desktop-jlrk-settlement/mcp-logs-plugin-discord-discord/*.jsonl \
  | head -1 | xargs grep -o 'Channel notifications [a-z]*' | tail -1
```

- `Channel notifications registered` → 정상 연동됨
- `Channel notifications skipped` → `--channels` 빠졌음. 2번 다시.

⚠️ 이 로그는 **그 세션이 켜질 때 채널이 붙었는지**만 말해준다. 세션이 죽어도 파일은 남으므로
"지금 봇이 살아있는지"의 근거로 쓰면 안 된다 (아래 '붙여넣기 함정' 2번 참고).

## 4. 두 번째 봇(PA/비서) 켜기

봇이 2개다. **봇 1개 = Claude Code 세션 1개**이고, 플러그인은 같은 걸 쓰지만
`DISCORD_STATE_DIR`로 설정 폴더만 분리한다(토큰·access.json·inbox가 각각 따로).

| 봇 | 작업폴더 | Discord 설정폴더 | alias |
|---|---|---|---|
| ① 정산/CC 봇 | `~/Desktop/jlrk-settlement` | `~/.claude/channels/discord` (기본) | `jlrk` |
| ② 비서(PA) 봇 | `~/pa` | `~/.claude/channels/discord-pa` | `pa` |

**터미널을 새로 켤 필요 없다.** 이미 `screen`에 붙어 있으면 창만 하나 더 만들면 된다.

1. screen에 붙기 (이미 붙어 있으면 생략)

```bash
screen -DR main
```

2. `Ctrl-a` 누르고 떼고 `c` → **새 창** 만들기
   ⚠️ 정산봇 Claude Code가 돌고 있는 창에 타이핑하면 안 된다. 반드시 새 창에서.

3. 새 창에서 한 줄씩

```bash
source ~/.zshrc
```

```bash
pa --continue
```

`--continue`는 그 폴더의 마지막 대화를 이어간다(세션 파일이 크면 수 초 걸림).
에러가 나거나 새로 시작하려면 `pa` 만.

4. Claude Code 프롬프트가 뜨면 성공 → `Ctrl-a` `d` 로 detach. 창을 닫아도 봇은 계속 돈다.

**살아있는지 확인 — 프로세스 수로 본다:**

```bash
ps ax | grep '[c]laude --channels' | wc -l
```

`2`면 두 봇 다 온라인. 최종 확인은 채널에서 각 봇을 @멘션.

자세한 복구 절차(유령 프로세스 정리, 재부팅 콜드 스타트)는 `docs/bots-recovery.md`.

### 모델 기본값 (두 봇 공통)

모델은 **세션마다 고를 필요가 없다.** `~/.claude/settings.json` 의 최상단 한 줄이 두 봇 모두의
기본값이고, `jlrk`/`pa` alias에는 `--model` 플래그가 없어서 이 값을 그대로 따른다.

```json
"model": "opus[1m]"
```

- `opus[1m]` = Opus + 1M 컨텍스트. 새로 띄우는 세션은 자동으로 Opus로 시작한다.
- 설정 폴더(`DISCORD_STATE_DIR`)만 분리돼 있고 **settings.json·플러그인·구독은 두 봇이 공유**한다
  → 한 번 바꾸면 둘 다 적용.
- 확인: 각 세션에서 `/status` (또는 `/model`).
- **세션 도중 Sonnet으로 내려가 있으면** 설정 문제가 아니라 Opus 사용량 한도에 걸려
  자동 전환된 것이다. 한도 창이 리셋되면 다시 Opus로 뜬다.
- ⚠️ 세션 안에서 `/model` 로 다른 모델을 고르면 이 파일의 기본값까지 바뀔 수 있다.
  임시로 바꿨다면 되돌려 둘 것. 기본값이 이상하면 항상 이 파일을 먼저 확인.

## ⚠️ 붙여넣기 함정 2개 (2026-09-12 실제로 걸림)

1. **명령어 뒤에 `# 주석`을 같이 붙여넣지 말 것.**
   zsh 대화형 셸은 기본값(`INTERACTIVE_COMMENTS` off)에서 `#`을 주석으로 보지 않는다.
   주석에 괄호가 있으면 glob 조건으로 해석돼 `zsh: unknown file attribute: ^` 파싱 에러가 나고
   **명령 자체가 실행되지 않는다.** (`pa --continue   # 어제 대화 이어서 (…)` 를 붙여넣어 실패한 사례.)
   → 명령을 안내할 때도 **같은 줄에 주석을 쓰지 말 것.** 설명은 코드블록 밖에.

2. **MCP 로그 grep은 "지금 살아있음"의 증거가 아니다.**
   `mcp-logs-plugin-discord-discord/*.jsonl`은 세션 시작 시 만들어져 계속 append되므로,
   세션이 죽어도 과거의 `Channel notifications registered` 가 그대로 남는다.
   (2026-09-12: 9/4에 생성된 로그를 보고 PA가 켜진 줄 알았지만 실제로는 꺼져 있었다.)
   → 생존 확인은 **프로세스 수**(위 `ps … | wc -l`), 로그는 "그 세션이 켜질 때 채널이 붙었는지"
   판정용으로만 쓴다.

## 앞으로 매번 하는 일 (요약)

```bash
cd ~/Desktop/jlrk-settlement && claude --channels plugin:discord@claude-plugins-official
```

alias 등록:

```bash
echo "alias jlrk='cd ~/Desktop/jlrk-settlement && claude --channels plugin:discord@claude-plugins-official'" >> ~/.zshrc
source ~/.zshrc
```

다음부터는 `jlrk` 한 단어로 실행. PA 봇은 `pa` (4번 절).

> 이 문서의 코드블록에는 **일부러 `#` 주석을 넣지 않았다** — 그대로 복사해 붙여도 zsh에서 깨지지 않게.

## 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| 디스코드에서 부른 메시지가 터미널에 안 옴 | `--channels plugin:discord@claude-plugins-official` 없이 실행함. 세션 재시작. |
| 답장은 되는데 수신만 안 됨 | 위와 동일 (아웃바운드는 토큰만으로 동작). |
| `--channels entries must be tagged` 오류 | 옛 문법(`plugin:discord:discord`) 사용함. `plugin:discord@claude-plugins-official`로 교체. |
| `--channels`에서 "org policy" / "not enabled" 오류 | `~/.claude/settings.json`에 `"channelsEnabled": true` 추가. (개인 Pro 계정은 기본 on이라 보통 불필요) |
| 로그에 `Channel notifications skipped` | 같은 원인. `--channels` 확인. |
| 여러 세션에서 인바운드가 겹침 | `.in_use/<pid>` 락은 한 세션만 유효. 나머지 세션 종료. |
| 봇이 그룹 채널 메시지에 무반응 | 그룹은 `requireMention: true` → 반드시 봇 멘션 필요. DM은 `allowFrom`에 있는 사용자만. |
| `zsh: unknown file attribute: ^` | 명령어 뒤 `# 주석`을 같이 붙여넣음. zsh 대화형 셸은 `#`을 주석으로 안 본다 → 명령이 실행되지 않았다. 주석 떼고 다시. |
| PA 봇만 무반응 | `~/pa` 세션이 죽은 것. `ps ax \| grep '[c]laude --channels' \| wc -l` 이 `1`이면 4번 절대로 `pa --continue`. |
| PA 봇이 정산봇 설정을 씀 | `pa` alias 없이 맨 `claude`로 띄웠음. `DISCORD_STATE_DIR`가 빠지면 기본 폴더(`discord`)를 쓴다. alias로 다시. |

## 관련 파일 / 개념

- 토큰: `~/.claude/channels/discord/.env` (`DISCORD_BOT_TOKEN`)
- 접근 제어: `~/.claude/channels/discord/access.json` — `/discord:access` 스킬로 관리
- 첨부 수신함: `~/.claude/channels/discord/inbox/`
- 채널 소유 락: `~/.claude/plugins/cache/claude-plugins-official/discord/0.0.4/.in_use/<pid>`
- MCP 서버 소스: 같은 경로의 `server.ts` (discord.js 게이트웨이 + MCP stdio)
- MCP 로그: `~/Library/Caches/claude-cli-nodejs/-Users-youngjung-Desktop-jlrk-settlement/mcp-logs-plugin-discord-discord/*.jsonl`
- PA 봇 설정폴더: `~/.claude/channels/discord-pa/` (`.env`, `access.json`, `inbox/`) — `DISCORD_STATE_DIR`로 지정
- PA 봇 작업폴더 / MCP 로그: `~/pa` / `~/Library/Caches/claude-cli-nodejs/-Users-youngjung-pa/mcp-logs-plugin-discord-discord/*.jsonl`
