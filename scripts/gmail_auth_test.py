#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gmail SMTP 인증만 따로 시험한다. 메일은 보내지 않는다.

운영 메일이 534 WebLoginRequired 로 막혔는데, 원인이
  (가) 계정·앱비밀번호 자체가 거부되는 것인지
  (나) Supabase 서버 IP 라서 구글이 막는 것인지
구분이 안 된다. 같은 자격증명으로 이 맥에서 붙여보면 갈린다.

  · 여기서 성공 → 자격증명 정상. 구글이 Supabase IP 를 막는 것이다.
  · 여기서도 실패 → 계정 쪽 문제. 에러 문구로 어느 쪽인지 알 수 있다.

비밀번호는 화면에 찍히지 않고 어디에도 저장되지 않는다.

입력에 한글/특수문자가 섞여 들어오는 일이 잦다(IME 가 켜진 채로 타이핑,
붙여넣기에 보이지 않는 문자 포함). smtplib 는 그걸 ASCII 로 인코딩하다
UnicodeEncodeError 로 죽는데 어디가 문제인지 안 알려준다. 그래서 보내기
전에 직접 검사하고, 비밀번호는 값을 드러내지 않으면서 위치만 짚어준다.
"""
import getpass
import smtplib
import ssl
import sys
import unicodedata

print(__doc__.split('입력에 한글')[0])


def inspect(label, s, secret=False):
    """ASCII 밖 문자가 있으면 어디에 뭐가 있는지 알려주고 True 를 돌려준다."""
    bad = [(i, c) for i, c in enumerate(s) if ord(c) > 126 or ord(c) < 32]
    if not bad:
        return False
    print(f'\n❌ {label} 에 ASCII 가 아닌 문자가 {len(bad)}개 섞여 있습니다.')
    for i, c in bad[:8]:
        try:
            name = unicodedata.name(c)
        except ValueError:
            name = '이름 없는 제어문자'
        shown = '(보이지 않는 문자)' if secret else repr(c)
        print(f'   · {i + 1}번째 글자 {shown}  U+{ord(c):04X}  {name}')
    if len(bad) > 8:
        print(f'   · … 외 {len(bad) - 8}개')
    return True


def clean(s):
    """양끝 공백·따옴표 제거, 내부 공백 제거(구글이 앱비번을 4자씩 띄어 보여준다)."""
    return s.strip().strip('\'"').replace(' ', '').replace(' ', '')


user = clean(input('GMAIL_USER (Supabase 시크릿에 넣은 주소 그대로) : '))
pw = clean(getpass.getpass('앱 비밀번호 16자리 (화면에 안 보입니다) : '))

problem = False
problem |= inspect('주소', user)
problem |= inspect('앱 비밀번호', pw, secret=True)

if problem:
    print('\n원인은 구글이 아니라 입력입니다. 한/영 키가 한글에 가 있거나,')
    print('붙여넣기에 보이지 않는 문자가 딸려 들어온 경우입니다.')
    print('영문 상태로 다시 쳐서 한 번 더 돌려주세요.')
    sys.exit(2)

if '@' not in user:
    print(f'\n❌ 주소 형식이 아닙니다: {user!r}')
    sys.exit(2)
if len(pw) != 16:
    print(f'\n※ 앱 비밀번호는 16자입니다. 지금 {len(pw)}자입니다 — 그대로 시도합니다.')

print(f'\n주소 {user} · 비밀번호 {len(pw)}자 — smtp.gmail.com:465 접속 중...\n')

try:
    with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=20,
                          context=ssl.create_default_context()) as s:
        s.ehlo('jlrk-settlement')
        s.login(user, pw)
        print('✅ 인증 성공 — 이 맥에서는 자격증명이 통합니다.')
        print('   → 운영(Supabase)에서만 막히므로 구글이 서버 IP 를 거부하는 것입니다.')
        print('   → Gmail SMTP 로는 해결되지 않습니다. 보내는 자리를 옮겨야 합니다.')
except smtplib.SMTPAuthenticationError as e:
    detail = e.smtp_error.decode('utf-8', 'replace')
    print(f'❌ 인증 거부 ({e.smtp_code})')
    print('   ' + detail.replace('\n', '\n   '))
    print()
    if 'WebLoginRequired' in detail or '5.7.14' in detail:
        print('   → 구글이 "브라우저로 한 번 로그인하라"고 요구합니다.')
        print('     이 맥에서도 같은 요구를 받는다면 계정 자체가 잠긴 상태입니다.')
    elif '5.7.9' in detail or 'Application-specific' in detail:
        print('   → 앱 비밀번호가 아니라 계정 비밀번호를 넣으셨습니다.')
    elif 'Username and Password not accepted' in detail or '5.7.8' in detail:
        print('   → 주소와 비밀번호가 맞지 않습니다. 앱 비밀번호를 발급한 계정과')
        print('     이 주소가 같은지 확인해주세요.')
    sys.exit(1)
except smtplib.SMTPServerDisconnected as e:
    # 구글은 자격증명이 명백히 틀리면 535 를 주지 않고 연결을 그냥 끊기도 한다
    print(f'❌ 구글이 연결을 끊었습니다: {e}')
    print('   → 보통 주소·비밀번호가 맞지 않을 때 나옵니다.')
    print('     앱 비밀번호를 발급한 계정이 이 주소가 맞는지 확인해주세요.')
    sys.exit(1)
except Exception as e:
    print(f'❌ 접속 실패: {type(e).__name__}: {e}')
    sys.exit(1)
