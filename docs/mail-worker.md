# 메일 발송 워커 (맥미니)

> 정산포털의 메일을 **맥미니에서** 보낸다. 2026-10-21 전환.
> 설정 파일 `~/.config/jlrk-mail/env` · 로그 `~/.config/jlrk-mail/worker.log`

## 왜 옮겼나

메일은 원래 Supabase Edge Function(`send-email`)이 Gmail SMTP 로 보냈다. 그런데
구글이 **서버 IP 에서 오는 SMTP 인증을 막는다**:

```
SMTP AUTH pass 실패 (534): 534-5.7.14 ... WebLoginRequired
```

`534 WebLoginRequired` 는 "브라우저로 한 번 로그인해서 본인 확인을 하라"는 뜻이다.
Edge Function 에는 브라우저가 없고, 실행 IP 도 매번 바뀐다. **앱 비밀번호를 새로
발급해도 똑같이 막혔다** — 자격증명 문제가 아니라 접속 위치 문제라는 뜻이다.

클라우드에서 Gmail SMTP 로 붙는 건 한 번 뚫어도 또 막힌다. 그래서 보내는 자리를
맥미니로 옮겼다. 맥미니는

- 봇 2개 때문에 **이미 24시간 켜져 있고**
- **한국 가정/사무실 IP** 라 구글이 막지 않으며
- 도메인 인증도, IT 승인도, 외부 서비스 가입도 필요 없다

## 흐름 — "매니저가 버튼을 눌러야 나간다" 는 그대로

```
포털이 메일을 만든다        → PENDING    아직 아무 데도 안 간다
매니저가 [발송] 을 누른다    → QUEUED     워커가 가져가도 좋다는 표시
워커가 집어간다             → SENDING    (중복 발송 방지 잠금)
보냈다                     → SENT
실패                       → FAILED + 사유
```

**워커는 QUEUED 만 가져간다. PENDING 은 쳐다보지 않는다.** 매니저가 누르지 않은
메일은 워커가 돌든 말든 절대 나가지 않는다.

## 중복 발송을 어떻게 막나

메일이 두 번 나가면 리테일러에게 치명적이다. `claim_outbox_email()` 이 한 건을
`SENDING` 으로 바꾸면서 돌려준다 — `FOR UPDATE SKIP LOCKED` 라 워커가 두 개 떠도
한쪽만 가져간다. 10분 넘게 `SENDING` 에 머문 건은 워커가 죽은 것으로 보고 다시
집어간다.

## 설치 (이미 돼 있음 — 참고용)

```
~/.local/jlrk-mail/venv/          전용 가상환경 (psycopg)   ※ iCloud 밖
~/.local/jlrk-mail/mail_worker.py 실행본
~/.config/jlrk-mail/env           설정 (chmod 600)
~/Library/LaunchAgents/com.jlrk.mailworker.plist
```

가상환경을 iCloud 밖에 둔 이유 — iCloud 가 파일을 내려버리면 24시간 도는
프로세스가 중간에 깨진다.

### 설정 채우기

`~/.config/jlrk-mail/env` 를 열어 세 줄을 채운다:

```
JLRK_DB_URL=postgresql://postgres:<비번>@db.<ref>.supabase.co:5432/postgres
GMAIL_USER=jlrkccso@gmail.com
GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx
```

- `JLRK_DB_URL` — Supabase → Project Settings → Database → Connection string → **URI**
- `GMAIL_APP_PASSWORD` — 구글 계정 → 보안 → 2단계 인증 → 앱 비밀번호.
  구글이 4자씩 띄어 보여주는데 **공백은 빼고** 넣는다 (워커가 지우기도 한다).

### 확인

```
~/.local/jlrk-mail/venv/bin/python ~/.local/jlrk-mail/mail_worker.py --check
```

Gmail 인증과 DB 접속만 해보고 끝낸다. 메일은 안 나간다.

### 켜기

```
launchctl load -w ~/Library/LaunchAgents/com.jlrk.mailworker.plist
```

재부팅해도 자동으로 뜨고, 죽으면 10초 뒤 알아서 살아난다.

## 운영

| 하고 싶은 것 | 명령 |
|---|---|
| 돌고 있나 확인 | `launchctl list \| grep mailworker` |
| 로그 보기 | `tail -f ~/.config/jlrk-mail/worker.log` |
| 멈추기 | `launchctl unload ~/Library/LaunchAgents/com.jlrk.mailworker.plist` |
| 다시 켜기 | `launchctl load -w ~/Library/LaunchAgents/com.jlrk.mailworker.plist` |
| 설정 바꾼 뒤 | unload → load (설정은 시작할 때만 읽는다) |
| 대기분만 비우고 끝내기 | `… mail_worker.py --once` |
| 인증·접속만 확인 | `… mail_worker.py --check` |

**워커가 멈춰 있으면 포털이 알려준다.** 「메일 발송 대기함」 에서 발송 요청한 메일이
2분 넘게 안 나가면 화면 위에 경고가 뜬다.

## 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| 포털에 "2분 넘게 안 나가고 있습니다" 경고 | 워커가 죽었다. `launchctl list \| grep mailworker` 확인 후 load. |
| 로그에 `인증 거부 (534)` | 맥미니에서도 구글이 막는 상태. 계정에 브라우저로 로그인해 확인 절차를 밟는다. |
| 로그에 `인증 거부 (535)` | 주소와 앱 비밀번호가 안 맞는다. 앱 비밀번호를 발급한 계정이 `GMAIL_USER` 와 같은지 확인. |
| `ASCII 가 아닌 문자가 있습니다` | env 파일에 한글이 섞였다. 한/영 키 확인. |
| `설정이 빠졌습니다` | `~/.config/jlrk-mail/env` 의 세 줄 중 비어 있는 게 있다. |
| 메일이 스팸함에 들어감 | 개인 Gmail 발신이라 어쩔 수 없는 면이 있다. 장기적으로는 회사 도메인 메일 서비스로 가야 한다. |
| 하루에 많이 보내야 할 때 | Gmail 은 하루 약 500통 제한이다. 리테일러 9개사 기준으로는 여유 있지만, 대량 발송 전에는 나눠 보낼 것. |

## 남은 과제

개인 Gmail(`jlrkccso@gmail.com`) 발신이라 **수신 측에서 스팸으로 분류될 여지**가 있고,
맥미니가 꺼지면 발송도 멈춘다. 제대로 하려면 회사 도메인(`jaguarlandrover.com`)에
SPF/DKIM 을 걸고 Resend 같은 메일 서비스를 쓰는 것이 정석이다. 그건 IT 승인이
필요해서 시간이 걸리므로, 그때까지는 이 구조로 간다.

관련: `migrations/047_outbox_queue.sql` · `scripts/mail_worker.py` ·
`scripts/gmail_auth_test.py` · `~/RESTART-BOTS.md`
