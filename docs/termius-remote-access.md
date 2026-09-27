# 맥미니 원격 접속 세팅 (Termius) — 세부 런북

> 목표: 밖에서(폰·노트북 Termius) `영중의 Mac mini` 에 SSH로 붙고,
> 접속이 끊겨도 Claude Code 세션이 살아있게 한다.
>
> 진행 상태 (2026-09-04):
> - 사용자명: `youngjung`  ·  LocalHostName: `yeongjung-ui-Macmini`
> - LAN IP: `192.168.0.33`(유선 en0) / `192.168.0.54`(Wi-Fi en1)
> - Phase 1 ✅ SSH 서버 On (시스템 설정 토글로 켬 — 터미널 명령은 Full Disk Access 필요해서 실패)
> - Phase 2 ✅ pmset: sleep 0 / disksleep 0 / womp 1 / autorestart 1 / powernap 1
> - Phase 3 ✅ Tailscale 연결됨. **맥미니 Tailscale IP = `100.112.86.101`** (tailnet: youngjung.yu@)
>   ('Launch Tailscale at login' 체크 권장. 옛 기기 ipad153=100.77.149.52 오프라인)
> - `screen`: 내장 (`/usr/bin/screen`) → 세션 유지에 사용. brew 불필요
> - Phase 4 ✅ Termius Ed25519 공개키 `~/.ssh/authorized_keys` 등록 (fp SHA256:kIchCicfRK6cszRAZ+jcMxwK1ZFFqpG29iYwBZ0P2xA)
>   ⚠️ 이 키쌍은 개인키가 채팅에 한 번 노출됨 → 여유될 때 Termius에서 재생성 후 교체 권장 (Tailscale-only라 급하진 않음)

---

## Phase 1 — SSH 서버 켜기 (맥미니에서)

터미널에서:

```bash
sudo systemsetup -setremotelogin on
sudo systemsetup -getremotelogin        # → "Remote Login: On" 확인
```

`sudo` 비밀번호(맥 로그인 암호) 입력.

접근 계정 제한(권장) — 시스템 설정에서:
`시스템 설정 → 일반 → 공유 → 원격 로그인` 켠 뒤, "다음 사용자만 접근 허용" 에 **youngjung** 만 남긴다.

확인:
```bash
launchctl print system/com.openssh.sshd >/dev/null 2>&1 && echo "sshd 실행중" || echo "안 됨"
```

---

## Phase 2 — 잠들지 않게 + 정전 후 자동 부팅 (맥미니에서)

```bash
sudo pmset -a sleep 0 disksleep 0 powernap 1 womp 1 autorestart 1
pmset -g | grep -E "^ *(sleep|disksleep|womp|autorestart|powernap) "
```

기대값: `sleep 0`, `disksleep 0`, `womp 1`, `autorestart 1`, `powernap 1`.

- `sleep 0` : 시스템 슬립 안 함 (SSH가 항상 살아있음)
- `womp 1`  : 네트워크 매직패킷으로 깨우기 (유선)
- `autorestart 1` : 정전 복구 시 자동 부팅

자동 로그인(선택, screen 자동복구에 편함):
`시스템 설정 → 사용자 및 그룹 → 자동 로그인 → youngjung`

---

## Phase 3 — Tailscale 연결 (집 밖에서 붙는 경로)

포트포워딩 없이 어디서든 붙는 방법. 맥미니엔 이미 설치돼 있고 중지 상태다.

**맥미니:**
1. Spotlight(`⌘Space`) → "Tailscale" 실행 → 메뉴바 아이콘 클릭 → **Log in** → 브라우저에서 계정 로그인(구글/깃허브 등)
2. 로그인되면 메뉴바에서 연결 상태 확인. CLI로도:
   ```bash
   /Applications/Tailscale.app/Contents/MacOS/Tailscale status
   /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4      # ← 이 100.x.x.x 를 Termius에 넣는다
   ```
3. (선택) Tailscale 메뉴 → Preferences → **Run unattended** / "Start on login" 체크 → 재부팅해도 자동 연결

**폰/노트북(접속하는 기기):**
- App Store / tailscale.com 에서 Tailscale 설치 → **같은 계정**으로 로그인
- 그러면 맥미니의 `100.x.x.x` 로 어디서든 접근 가능

> 대안(포트포워딩): 공유기에서 외부포트(예 52200) → `192.168.0.33:22` 포워딩 + 맥미니 IP 고정(DHCP 예약) + 유동공인IP면 DDNS. Tailscale 쓰면 다 불필요하므로 여기선 생략.

---

## Phase 4 — SSH 키 등록

**Termius에서 키 생성** (권장):
Termius → Keychain → **+ → Generate Key** (Ed25519) → 이름 지정 → 생성 →
그 키 항목에서 **Copy Public Key**.

**맥미니에 공개키 붙여넣기:**
```bash
# 아래 'ssh-ed25519 AAAA... 이름' 자리에 복사한 공개키를 그대로
echo "ssh-ed25519 AAAA...복사한공개키... termius" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
cat ~/.ssh/authorized_keys      # 한 줄로 잘 들어갔는지 확인
```

(비밀번호 로그인으로 먼저 붙는 것도 가능. 키를 넣으면 그 뒤부터 키로 접속.)

키만 쓰도록 강제(선택, 키 접속 확인 후):
```bash
sudo sed -i '' 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo launchctl kickstart -k system/com.openssh.sshd
```

---

## Phase 5 — 세션 유지 (`screen`)

`screen` 은 맥에 내장돼 있어 바로 쓴다. 접속이 끊겨도 `screen` 세션은 서버에 남는다.

`~/.zshrc` 맨 아래에 추가:
```bash
# --- 원격 작업용 ---
alias work='screen -DR main'
alias jlrk='cd ~/icloud/Claude/jlrk-settlement && claude --channels plugin:discord@claude-plugins-official'
alias pa='cd ~/icloud/Claude/pa && DISCORD_STATE_DIR="$HOME/.claude/channels/discord-pa" claude --channels plugin:discord@claude-plugins-official'
```
적용: `source ~/.zshrc`

**쓰는 법:**
- 접속 후 `work` → `screen` 안으로 들어감 → 그 안에서 `jlrk` 로 Claude Code 실행
- 끊겨도 세션 유지. 다시 SSH 붙어서 `work` 하면 그 화면 그대로
- `screen` 안에서 detach: `Ctrl-a` 누르고 `d`

> 업그레이드(선택): Homebrew 설치 후 `brew install tmux mosh`.
> - `tmux` : screen보다 최신·편리 (`alias work='tmux attach -t main || tmux new -s main'`)
> - `mosh` : 회선이 끊겨도/IP가 바뀌어도 세션 유지. Termius 호스트 설정에서 Mosh 토글.
> Homebrew: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

---

## Phase 6 — Termius 호스트 등록

Termius → **New Host**:
| 항목 | 값 |
|---|---|
| Label | Mac mini |
| Address | `100.x.x.x` (Phase 3의 tailscale ip) |
| Port | `22` |
| Username | `youngjung` |
| Key | Phase 4에서 만든 키 선택 |

**Startup snippet** (호스트 설정 하단, 접속하자마자 실행):
```
screen -DR main
```
→ 접속하면 바로 `main` 세션으로 들어감.

---

> 진행: Phase 5 ✅ `~/.zshrc` 에 `alias work='screen -DR main'` / `alias jlrk=...` 추가됨.
> Phase 6 ✅ Termius 호스트 `MacMini` = `100.112.86.101:22` user `youngjung` + 키.
> **접속 성공 확인** (맥미니에서 `100.64.236.35` tailnet IP로 SSH ESTABLISHED).
> 남은 것: Startup snippet `screen -DR main` 설정(선택) + 세션유지 테스트 + 키 교체.

## Phase 7 — 테스트 & 일상 사용

1. Termius에서 Mac mini 호스트 탭 → 접속되면 `screen` 세션(빈 셸 또는 이전 화면) 뜸
2. 처음이면 `jlrk` 실행 → Claude Code + Discord 연동
3. 폰 덮거나 회선 끊김 → 나중에 Termius 다시 열고 호스트 탭 → `screen -DR main` (startup snippet이 자동 실행) → 원래 화면 복구. Claude Code는 그동안 계속 돌아감

**연결 확인 체크리스트:**
```bash
# 맥미니에서
sudo systemsetup -getremotelogin          # Remote Login: On
/Applications/Tailscale.app/Contents/MacOS/Tailscale status   # 연결됨
pmset -g | grep " sleep "                  # sleep 0
```

---

## 문제 해결

| 증상 | 조치 |
|---|---|
| Termius 접속 timeout | Tailscale 양쪽 다 켜져 있나? `tailscale status` 에 맥미니 이름 보이나? |
| `Permission denied (publickey)` | 공개키가 `~/.ssh/authorized_keys` 에 한 줄로 정확히 들어갔나. `chmod 600` 했나 |
| `Connection refused` | SSH 서버 꺼짐. `sudo systemsetup -setremotelogin on` |
| 재부팅하니 Tailscale 끊김 | Tailscale Preferences → Run unattended / Start on login |
| screen 세션이 안 남음 | detach는 `Ctrl-a d`. `screen -ls` 로 세션 목록 확인 |
| 맥미니가 자다 깨서 안 붙음 | `sudo pmset -a sleep 0` 재확인 |
