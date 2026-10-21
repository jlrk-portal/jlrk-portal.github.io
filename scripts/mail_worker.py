#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""JLRK 정산포털 메일 발송 워커 — 맥미니에서 돈다.

왜 맥미니인가
  구글이 Supabase Edge Function 의 서버 IP 에서 오는 SMTP 인증을
  534 WebLoginRequired 로 막는다. 앱 비밀번호를 새로 발급해도 같다.
  클라우드에서 Gmail SMTP 로 붙는 건 뚫어도 또 막힌다. 맥미니는 봇 때문에
  24시간 켜져 있고 한국 IP 라 구글이 막지 않는다.

원칙 — 매니저가 버튼을 눌러야 나간다
  포털이 쌓아둔 PENDING 은 쳐다보지 않는다. 매니저가 「메일 발송 대기함」
  에서 [발송] 을 눌러 QUEUED 가 된 것만 가져간다.

중복 발송 방지
  claim_outbox_email() 이 한 건을 SENDING 으로 바꾸며 돌려준다
  (FOR UPDATE SKIP LOCKED). 워커가 두 개 떠도 같은 메일이 두 번 나가지 않는다.
  보내기 직전에 죽으면 10분 뒤 다시 집어간다 — 그래서 '보내고 죽는' 창을
  최소화하려고 SENT 기록을 SMTP 응답 직후 바로 박는다.

설정 — ~/.config/jlrk-mail/env (chmod 600)
  JLRK_DB_URL=postgresql://postgres:<비번>@<호스트>:5432/postgres
  GMAIL_USER=jlrkccso@gmail.com
  GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx

실행
  python3 scripts/mail_worker.py            # 계속 돈다
  python3 scripts/mail_worker.py --once     # 대기분만 비우고 끝낸다
  python3 scripts/mail_worker.py --check    # 접속·인증만 확인하고 끝낸다
"""
import os
import sys
import ssl
import time
import signal
import smtplib
import logging
import datetime as dt
from email.message import EmailMessage
from email.utils import formataddr, make_msgid

try:
    import psycopg
except ImportError:
    sys.exit('psycopg 가 없습니다:  python3 -m pip install "psycopg[binary]"')

ENV_FILE   = os.path.expanduser('~/.config/jlrk-mail/env')
LOG_FILE   = os.path.expanduser('~/.config/jlrk-mail/worker.log')
FROM_NAME  = 'JLRK 정산 포털'
POLL_SEC   = 5          # 대기 중일 때 DB 를 들여다보는 간격
GAP_SEC    = 1.5        # 연속 발송 간 간격 (구글이 급발송을 싫어한다)
MAX_TRIES  = 3          # 이 횟수를 넘기면 FAILED 로 확정한다
SMTP_HOST  = 'smtp.gmail.com'
SMTP_PORT  = 465

running = True


def load_env():
    """env 파일을 읽어 os.environ 에 올린다. 이미 들어있는 값은 건드리지 않는다."""
    if os.path.exists(ENV_FILE):
        mode = oct(os.stat(ENV_FILE).st_mode)[-3:]
        if mode != '600':
            logging.warning('%s 권한이 %s 입니다. chmod 600 을 권합니다.', ENV_FILE, mode)
        for line in open(ENV_FILE, encoding='utf-8'):
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            os.environ.setdefault(k.strip(), v.strip().strip('\'"'))
    missing = [k for k in ('JLRK_DB_URL', 'GMAIL_USER', 'GMAIL_APP_PASSWORD')
               if not os.environ.get(k)]
    if missing:
        sys.exit(f'설정이 빠졌습니다: {", ".join(missing)}\n  → {ENV_FILE} 를 채워주세요.')
    # 구글이 앱 비밀번호를 4자씩 띄어서 보여준다. 공백이 섞여 들어오는 일이 잦다.
    os.environ['GMAIL_APP_PASSWORD'] = os.environ['GMAIL_APP_PASSWORD'].replace(' ', '')
    for k in ('GMAIL_USER', 'GMAIL_APP_PASSWORD'):
        bad = [c for c in os.environ[k] if ord(c) > 126 or ord(c) < 32]
        if bad:
            sys.exit(f'{k} 에 ASCII 가 아닌 문자가 있습니다 (한/영 키를 확인해주세요).')


def setup_log():
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s  %(levelname)-7s %(message)s',
        datefmt='%m-%d %H:%M:%S',
        handlers=[logging.FileHandler(LOG_FILE, encoding='utf-8'),
                  logging.StreamHandler(sys.stdout)],
    )


def connect_smtp():
    s = smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=30,
                         context=ssl.create_default_context())
    s.ehlo('jlrk-settlement')
    s.login(os.environ['GMAIL_USER'], os.environ['GMAIL_APP_PASSWORD'])
    return s


def build(to_addrs, subject, html):
    """EmailMessage 가 한글 제목·본문을 알아서 안전하게 인코딩한다.

    (Edge Function 때는 denomailer 가 멀티바이트를 깨뜨려 SMTP 대화를 직접
     구현해야 했지만, 파이썬 표준 라이브러리는 그 문제가 없다.)"""
    m = EmailMessage()
    m['From'] = formataddr((FROM_NAME, os.environ['GMAIL_USER']))
    m['To'] = ', '.join(to_addrs)
    m['Subject'] = subject
    m['Date'] = dt.datetime.now(dt.timezone.utc).astimezone().strftime('%a, %d %b %Y %H:%M:%S %z')
    m['Message-ID'] = make_msgid(domain='gmail.com')
    m.set_content('이 메일은 HTML 로 작성되었습니다. HTML 을 지원하는 메일 프로그램에서 열어주세요.')
    m.add_alternative(html, subtype='html')
    return m


def drain(conn, smtp):
    """QUEUED 를 전부 비운다. 보낸 건수를 돌려준다."""
    sent = 0
    while running:
        with conn.cursor() as cur:
            cur.execute('select * from claim_outbox_email()')
            row = cur.fetchone()
        conn.commit()
        if not row:
            return sent, smtp
        mid, to_addrs, subject, html, attempts = row
        to_addrs = [a for a in (to_addrs or []) if a and 'placeholder@example.com' not in a.lower()]
        if not to_addrs:
            mark(conn, mid, 'FAILED', '보낼 수 있는 수신자 주소가 없습니다.')
            logging.warning('%s 수신자 없음 — FAILED', mid)
            continue
        try:
            if smtp is None:
                smtp = connect_smtp()
            smtp.send_message(build(to_addrs, subject, html))
            mark(conn, mid, 'SENT', None)
            sent += 1
            logging.info('보냄  %s  %s  → %s', mid, subject[:48], ', '.join(to_addrs))
            time.sleep(GAP_SEC)
        except (smtplib.SMTPServerDisconnected, smtplib.SMTPConnectError,
                OSError, ssl.SSLError) as e:
            # 연결 문제는 메일 잘못이 아니다. 되돌려놓고 다음 바퀴에 다시 시도한다.
            try:
                smtp.quit()
            except Exception:
                pass
            smtp = None
            if attempts >= MAX_TRIES:
                mark(conn, mid, 'FAILED', f'{MAX_TRIES}회 시도 실패: {e}')
                logging.error('%s %d회 실패 — FAILED: %s', mid, attempts, e)
            else:
                mark(conn, mid, 'QUEUED', None)
                logging.warning('%s 연결 문제(%d회차), 다시 시도합니다: %s', mid, attempts, e)
                time.sleep(5)
            return sent, smtp
        except smtplib.SMTPAuthenticationError as e:
            # 자격증명 문제는 재시도해도 소용없다. 되돌려놓고 사람을 부른다.
            mark(conn, mid, 'QUEUED', None)
            detail = e.smtp_error.decode('utf-8', 'replace')
            logging.error('인증 거부 (%s): %s — 발송을 멈춥니다.', e.smtp_code, detail)
            raise SystemExit(1)
        except Exception as e:
            if attempts >= MAX_TRIES:
                mark(conn, mid, 'FAILED', f'{MAX_TRIES}회 시도 실패: {e}')
                logging.error('%s %d회 실패 — FAILED: %s', mid, attempts, e)
            else:
                mark(conn, mid, 'QUEUED', None)
                logging.warning('%s 실패(%d회차), 다시 시도합니다: %s', mid, attempts, e)
                time.sleep(2)   # 같은 건을 쉬지 않고 두드리지 않는다
    return sent, smtp


def mark(conn, mid, status, error):
    with conn.cursor() as cur:
        if status == 'SENT':
            cur.execute("update email_outbox set status='SENT', sent_at=now(), error=null"
                        ' where id=%s', (mid,))
        else:
            cur.execute('update email_outbox set status=%s, error=%s where id=%s',
                        (status, error, mid))
    conn.commit()


def pending_count(conn):
    with conn.cursor() as cur:
        cur.execute("select count(*) from email_outbox where status in ('QUEUED','SENDING')")
        return cur.fetchone()[0]


def main():
    setup_log()
    load_env()
    once = '--once' in sys.argv

    if '--check' in sys.argv:
        logging.info('Gmail 인증 확인 — %s', os.environ['GMAIL_USER'])
        connect_smtp().quit()
        logging.info('✅ Gmail 인증 성공')
        with psycopg.connect(os.environ['JLRK_DB_URL'], connect_timeout=15) as c:
            logging.info('✅ DB 접속 성공 — 발송 대기 %d건', pending_count(c))
        return

    def stop(*_):
        global running
        running = False
        logging.info('종료 신호를 받았습니다. 보내던 건을 마치고 멈춥니다.')
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    logging.info('메일 워커 시작 — %s, %d초마다 확인%s',
                 os.environ['GMAIL_USER'], POLL_SEC, ' (--once)' if once else '')
    smtp = None
    idle = 0
    try:
        with psycopg.connect(os.environ['JLRK_DB_URL'], connect_timeout=15,
                             autocommit=False) as conn:
            while running:
                try:
                    n, smtp = drain(conn, smtp)
                except psycopg.Error as e:
                    logging.error('DB 오류: %s — 10초 후 다시 붙습니다.', e)
                    conn.rollback()
                    time.sleep(10)
                    continue
                if once:
                    logging.info('--once: %d건 보내고 종료합니다.', n)
                    break
                idle = 0 if n else idle + 1
                # 한가하면 SMTP 연결을 놔준다 (구글이 유휴 연결을 끊는다)
                if smtp is not None and idle >= 12:
                    try:
                        smtp.quit()
                    except Exception:
                        pass
                    smtp = None
                time.sleep(POLL_SEC)
    finally:
        if smtp is not None:
            try:
                smtp.quit()
            except Exception:
                pass
        logging.info('메일 워커 종료')


if __name__ == '__main__':
    main()
