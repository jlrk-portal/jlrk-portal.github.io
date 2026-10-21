# 봇 2개 되살리기 — 복구 매뉴얼

> 두 봇 모두 **맥미니에서 돌아가는 Claude Code 세션**이다. 세션이 죽으면 그 봇은 오프라인.
> 이 파일 위치: `~/RESTART-BOTS.md` (어느 세션에서든 `cat ~/RESTART-BOTS.md`).
> jlrk 저장소에도 같은 내용: `~/Desktop/jlrk-settlement/docs/bots-recovery.md`.
> 마지막 점검: 2026-09-12 — 두 봇 다 `Channel notifications registered` 정상. 모델 Opus 5 (1M) 고정 적용.

| 봇 | Discord user ID | 작업폴더 | Discord 설정폴더 | 실행 alias |
|---|---|---|---|---|
| ① 정산/CC 봇 | `1544322582386573332` | `~/Desktop/jlrk-settlement` | `~/.claude/channels/discord` (기본) | `jlrk` |
| ② 비서(PA) 봇 | `1545403936788324425` | `~/pa` | `~/.claude/channels/discord-pa` | `pa` |

둘 다 같은 그룹 채널(`1544475772121645076`)에 있고, **멘션(@봇)** 해야 반응한다.
허용 사용자는 너(`901741686084993025`) 하나.

**핵심 규칙 4개**
1. 각 봇 = Claude Code 세션 1개. 세션 죽으면 봇 오프라인.
2. 실행할 때 `--channels plugin:discord@claude-plugins-official` **반드시** 포함
   (`jlrk`/`pa` alias에 이미 들어있음). 빠지면 Discord 메시지가 조용히 무시됨.
3. PA 봇은 `DISCORD_STATE_DIR`가 `discord-pa`를 가리켜야 한다 (alias에 이미 있음).
   그냥 `claude`로 켜면 안 되고, 반드시 `pa` alias로 켤 것.
4. 한 봇당 세션 1개만. 유령 프로세스 있으면 먼저 정리.
5. 모델은 **Opus 5 (1M)** 고정. alias의 `--model "opus[1m]"` 가 담당하며,
   `~/.claude/settings.json` 의 `"model": "opus[1m]"` 가 백업.
   켤 때마다 `/model` 로 바꿀 필요 없음. (zsh 글롭 때문에 `opus[1m]` 은 반드시 따옴표로 감쌀 것)

---

## 상황 A — 터미널만 꺼지고 `screen` 세션은 살아있는 경우 (가장 흔함)

`screen` 안에서 돌리고 있었다면 터미널·SSH가 끊겨도 `screen`과 그 안의 Claude Code는
**계속 살아있다.** 다시 붙기만 하면 됨.

```
# 맥미니 앞에서, 또는 Termius로 접속한 뒤:
screen -ls                 # 'main' 세션이 (Detached)로 보이는지 확인
screen -DR main            # 재접속  (= alias 'work')
```

붙은 뒤 창 전환으로 각 봇 확인:
- `Ctrl-a` `"` → 창 목록
- `Ctrl-a` `n` / `p` → 다음/이전 창
- 각 창에 Claude Code 프롬프트가 그대로면 정상. 봇도 온라인 유지 중.

**둘 중 하나만 죽어 있으면** 그 창으로 가서 아래 "상황 B" 진행.

---

## 상황 B — 봇 세션이 죽었을 때 (하나 또는 둘 다)

### 1. 유령 프로세스 확인·정리
```
ps ax -o pid,command | grep '[c]laude --channels'
```
- 봇당 프로세스가 **정확히 1개**여야 함.
- 죽었는데 프로세스가 남았거나 2개 이상이면 그 PID 종료:
```
kill <PID>          # 안 죽으면 kill -9 <PID>
```

### 2. 되살리기 — `screen` 안에서 (권장)
```
screen -DR main             # 세션 없으면 자동 생성
```
screen 안에서:

**① 정산/CC 봇 창:**
```
source ~/.zshrc
jlrk --continue            # 직전 대화 이어서. 새로 시작하려면 그냥 'jlrk'
```

**② 비서(PA) 봇 창** — `Ctrl-a` `c` 로 새 창 만든 뒤:
```
source ~/.zshrc
pa --continue              # 직전 대화 이어서. 새로 시작하려면 그냥 'pa'
```

> `jlrk` = `cd ~/Desktop/jlrk-settlement && claude --model "opus[1m]" --channels plugin:discord@claude-plugins-official`
> `pa`   = `cd ~/pa && DISCORD_STATE_DIR="$HOME/.claude/channels/discord-pa" claude --model "opus[1m]" --channels plugin:discord@claude-plugins-official`
> 뒤에 `--continue` = 그 폴더의 **마지막 대화** 이어감. `-r` = 대화 목록에서 고름.

### 3. Discord 연결 확인
```
# ① 정산봇
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-youngjung-Desktop-jlrk-settlement/mcp-logs-plugin-discord-discord/*.jsonl | head -1 | xargs grep -o 'Channel notifications [a-z]*' | tail -1
# ② PA봇
ls -t ~/Library/Caches/claude-cli-nodejs/-Users-youngjung-pa/mcp-logs-plugin-discord-discord/*.jsonl | head -1 | xargs grep -o 'Channel notifications [a-z]*' | tail -1
```
- `Channel notifications registered` → 정상 연결
- `Channel notifications skipped` → `--channels` 빠짐. 세션 종료하고 alias로 다시.

### 4. 최종 확인
채널에서 각 봇을 @멘션해 "핑" → 각 세션(각 창)에 메시지가 들어오면 복구 완료.

---

## 상황 C — 맥미니 재부팅 후 (콜드 스타트)

재부팅되면 SSH·Tailscale은 자동 복구되지만(`autorestart 1`, Tailscale 'Launch at login'),
**`screen`·봇 세션은 안 살아난다.** 처음부터:

```
# 1. (원격이면) Termius로 접속  →  맥미니 Tailscale IP 100.112.86.101, user youngjung
# 2. screen 시작
screen -S main
# 3. 정산봇
source ~/.zshrc && jlrk
# 4. Ctrl-a c 로 새 창 → PA봇
source ~/.zshrc && pa
# 5. Ctrl-a d 로 detach (봇들은 계속 돎)
```

이후엔 상황 A대로 `screen -DR main`으로 재접속.

---

## 상황 D — 메일이 안 나갈 때 (발송 워커)

포털 「메일 발송 대기함」에서 발송을 눌렀는데 **2분이 넘도록 「발송됨」 으로 안 바뀌면**
맥미니 메일 워커가 멈춘 것이다. (화면 위에도 경고가 뜬다.)

> 이건 **봇이 아니다.** Claude 세션도 screen 도 아니고, launchd 가 관리하는
> 파이썬 프로세스다. `screen -DR main` 으로 가도 안 보인다.

```
launchctl list | grep mailworker          # 돌고 있나
tail -20 ~/.config/jlrk-mail/worker.log   # 왜 멈췄나
launchctl load -w ~/Library/LaunchAgents/com.jlrk.mailworker.plist   # 켜기
```

멈춰 있어도 **메일이 잘못 나가지는 않는다.** 워커는 매니저가 [발송] 을 눌러
`QUEUED` 가 된 것만 가져간다. 켜면 밀린 것부터 순서대로 보낸다.

자세한 내용(설정 파일, 왜 맥미니에서 보내는지, 트러블슈팅):
`~/icloud/Claude/jlrk-settlement/docs/mail-worker.md`

---

## 빠른 참조

| 하고 싶은 것 | 명령 |
|---|---|
| screen 재접속 | `screen -DR main` (= `work`) |
| screen 새 창 | `Ctrl-a` `c` |
| 창 이동 / 목록 | `Ctrl-a` `n`·`p` / `Ctrl-a` `"` |
| screen 나가기(봇 유지) | `Ctrl-a` `d` |
| 정산봇 켜기 | `jlrk` (이어서: `jlrk --continue`) |
| PA봇 켜기 | `pa` (이어서: `pa --continue`) |
| 돌아가는 세션 보기 | `ps ax \| grep '[c]laude --channels'` |
| 세션 죽이기 | `kill <PID>` |
| 메일 워커 상태 | `launchctl list \| grep mailworker` |
| 메일 워커 로그 | `tail -f ~/.config/jlrk-mail/worker.log` |
| 메일 워커 켜기 | `launchctl load -w ~/Library/LaunchAgents/com.jlrk.mailworker.plist` |

---

## 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| Discord에서 부른 메시지가 터미널에 안 옴 | `--channels plugin:discord@claude-plugins-official` 없이 실행함. alias로 재시작. |
| 답장은 되는데 수신만 안 됨 | 위와 동일 (아웃바운드는 토큰만으로 동작). |
| 봇이 터미널에선 대답하는데 Discord엔 안 뜸 | 봇이 `reply` 도구를 안 부르고 터미널에만 출력한 것. 터미널 출력은 Discord로 안 감. 세션에 "Discord로 reply 해" 라고 알려주면 됨. |
| `--channels entries must be tagged` 오류 | 옛 문법(`plugin:discord:discord`) 사용. `plugin:discord@claude-plugins-official`로 교체. |
| PA봇이 정산봇처럼 굴거나 토큰 충돌 | `pa`를 alias 없이 켰음 → `DISCORD_STATE_DIR` 누락. 세션 종료하고 `pa` alias로 다시. |
| 로그에 `Channel notifications skipped` | 같은 원인. `--channels` 확인. |
| 두 세션에서 인바운드가 겹침 | 같은 봇을 두 번 켰음. 여분 세션 `kill`. |
| 봇이 그룹 채널에 무반응 | 그룹은 멘션 필수. `@봇` 붙였는지 확인. |
| 봇이 Opus가 아닌 모델로 떠 있음 | alias 없이 그냥 `claude` 로 켰거나 `--model` 이 빠짐. 세션에서 `/model` 로 확인 후 alias로 재시작. |
| `no matches found: opus[1m]` | zsh가 `[1m]` 을 글롭으로 해석. alias 안에서 `--model "opus[1m]"` 처럼 따옴표 필수. |

## 관련 파일

- 토큰: `~/.claude/channels/discord/.env` · `~/.claude/channels/discord-pa/.env` (`DISCORD_BOT_TOKEN`)
- 접근 제어: 각 폴더의 `access.json` — `/discord:access` 스킬로 관리
- 채널 붙이는 원리 상세: `~/Desktop/jlrk-settlement/docs/discord-terminal-setup.md`
- 원격 접속(Termius/Tailscale): `~/Desktop/jlrk-settlement/docs/termius-remote-access.md`
- 메일 발송 워커: `~/icloud/Claude/jlrk-settlement/docs/mail-worker.md` · 설정 `~/.config/jlrk-mail/env`
