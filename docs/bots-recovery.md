# 봇 2개 되살리기 — 복구 매뉴얼

두 봇 모두 **맥미니에서 돌아가는 Claude Code 세션**이다. 각각:

| 봇 | 채널에서 보이는 이름 | 작업폴더 | Discord 설정폴더 | 실행 alias |
|---|---|---|---|---|
| ① 정산/CC 봇 | Client Care & Digital Analyst | `~/Desktop/jlrk-settlement` | `~/.claude/channels/discord` (기본) | `jlrk` |
| ② 비서(PA) 봇 | (새 봇 이름) | `~/pa` | `~/.claude/channels/discord-pa` | `pa` |

**핵심 규칙 3개**
1. 각 봇 = Claude Code 세션 1개. 세션이 죽으면 봇이 오프라인.
2. 실행할 때 **`--channels plugin:discord@claude-plugins-official` 반드시** 포함 (`jlrk`/`pa` alias에 이미 들어있음). 이거 빠지면 Discord 메시지가 조용히 무시됨.
3. 한 봇당 세션은 **1개만**. 유령 프로세스 있으면 먼저 정리.

---

## 상황 A — 터미널만 꺼졌고 `screen` 세션은 살아있는 경우 (가장 흔함)

`screen` 안에서 돌리고 있었다면, 터미널/SSH가 끊겨도 `screen` 세션과 그 안의 Claude Code는 **계속 살아있다**. 그냥 다시 붙으면 됨.

맥미니 터미널(또는 Termius로 접속) 후 — **한 줄씩**:

```
screen -ls
```
```
screen -DR main
```

`screen -ls` 에 `main` 세션이 `(Detached)` 로 보이면 정상, `screen -DR main` 으로 재접속(= alias `work`).

> ⚠️ **명령어 뒤에 `# 주석`을 같이 붙여넣지 말 것.** zsh 대화형 셸은 `#`을 주석으로 보지 않아서
> `zsh: unknown file attribute: ^` 파싱 에러가 나고 **명령이 아예 실행되지 않는다.**
> 이 문서의 코드블록에 주석을 넣지 않은 이유다.

붙으면 창 전환으로 각 봇 확인:
- `Ctrl-a` 누르고 `"` → 창 목록
- `Ctrl-a` `n` / `p` → 다음/이전 창
- 각 창에 Claude Code 프롬프트가 그대로 있으면 정상. 봇도 온라인 유지 중.

**둘 중 하나만 죽어 있으면** → 그 창으로 가서 아래 "상황 B" 진행.

---

## 상황 B — 봇 세션이 죽었을 때 (한 개 또는 둘 다)

### 1. 유령 프로세스 확인·정리
```
ps ax | grep '[c]laude --channels'
```
- 각 봇당 프로세스가 **정확히 1개**여야 함.
- 죽었는데 프로세스가 남아있거나, 2개 이상이면 그 PID 종료:
```
kill <PID>
```

안 죽으면 `kill -9 <PID>`.

### 2. 되살리기 — `screen` 안에서 (권장)
```
screen -DR main
```

(세션이 없으면 자동 생성된다.)

screen 안에서:

**① 정산/CC 봇 창:**
```
source ~/.zshrc
```
```
jlrk --continue
```

`--continue` 는 직전 대화를 이어간다. 새로 시작하려면 `jlrk` 만.

**② 비서(PA) 봇 창** — `Ctrl-a` `c` 로 새 창 만든 뒤:
```
source ~/.zshrc
```
```
pa --continue
```

`--continue` 는 직전 대화를 이어간다. 새로 시작하려면 `pa` 만.
⚠️ 정산봇 Claude Code가 돌고 있는 창에 타이핑하면 안 된다. 반드시 `Ctrl-a` `c` 로 만든 **새 창**에서.

> `jlrk` = `cd ~/Desktop/jlrk-settlement && claude --channels plugin:discord@claude-plugins-official`
> `pa`   = `cd ~/pa && DISCORD_STATE_DIR="$HOME/.claude/channels/discord-pa" claude --channels plugin:discord@claude-plugins-official`
> 뒤에 `--continue` 붙이면 그 폴더의 **마지막 대화**를 이어감. `-r` 붙이면 대화 목록에서 고름.

### 3. 살아있는지 확인 — 프로세스 수로 본다

```
ps ax | grep '[c]laude --channels' | wc -l
```

- `2` → 두 봇 다 온라인
- `1` → 한쪽만 떠 있음 (어느 쪽인지는 아래 `ps` 로 cwd 확인)
- `0` → 둘 다 죽음

```
ps ax -o pid,etime,command | grep '[c]laude --channels'
```

> ⚠️ **MCP 로그 grep으로 생존 확인하지 말 것.**
> `mcp-logs-plugin-discord-discord/*.jsonl` 은 세션 시작 시 만들어져 계속 append되므로,
> 세션이 죽어도 과거의 `Channel notifications registered` 가 그대로 남는다.
> (2026-09-12: 9/4에 생성된 PA 로그를 보고 켜진 줄 알았지만 실제로는 꺼져 있었다.)
> 로그는 "그 세션이 **켜질 때** 채널이 붙었는지"(`registered` vs `skipped`) 판정용으로만 쓴다.

### 4. 최종 확인
채널에서 각 봇을 @멘션해서 "핑" → 각 세션(각 창)에 메시지 들어오면 복구 완료.

---

## 상황 C — 맥미니 재부팅 후 (콜드 스타트)

재부팅되면 SSH 서버·Tailscale은 자동 복구되지만(`autorestart 1`, Tailscale 'Launch at login'), **`screen` 세션과 봇 세션은 안 살아난다.** 처음부터:

1. (원격이면) Termius로 접속
2. screen 시작

```
screen -S main
```

3. 정산봇

```
source ~/.zshrc && jlrk
```

4. `Ctrl-a` `c` 로 새 창 → PA봇

```
source ~/.zshrc && pa
```

5. `Ctrl-a` `d` 로 detach (봇들은 계속 돎)

이후엔 상황 A대로 `screen -DR main` 으로 재접속.

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
| 두 봇 다 살아있나 | `ps ax \| grep '[c]laude --channels' \| wc -l` → `2` |
| 세션 죽이기 | `kill <PID>` |
