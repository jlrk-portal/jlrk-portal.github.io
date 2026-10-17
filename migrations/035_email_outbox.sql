-- ============================================================
--  Migration 035 — 이메일 발송 대기함 (email_outbox)
--
--  포털에서 자동으로 나가던 모든 메일을 "발송 대기"로 쌓아두고,
--  관리자가 포털에서 [발송] 버튼을 눌러야 실제로 나가게 한다.
--  (2026-10-17 유영중 매니저 지시 — 실수로 리테일러에게 나가는 것을 막기 위함)
--
--  index.html 의 sendEmail() 이 send-email Edge Function 을 직접 호출하지 않고
--  이 테이블에 PENDING 으로 넣는다. 「발송 대기함」 화면에서 발송한다.
-- ============================================================

create table if not exists email_outbox (
  id          uuid primary key default gen_random_uuid(),
  to_addrs    text[] not null,
  subject     text not null,
  html        text not null,
  context     jsonb,                       -- {kind, round_id, retailer_code, ...} 추적용
  status      text not null default 'PENDING'
                check (status in ('PENDING','SENT','CANCELLED','FAILED')),
  error       text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  sent_at     timestamptz,
  sent_by     uuid references auth.users(id) on delete set null
);

create index if not exists email_outbox_status_idx on email_outbox (status, created_at desc);

alter table email_outbox enable row level security;

-- 관리자 전용. 리테일러는 자기 앞으로 가는 메일도 볼 수 없다(발송 전 내용이므로).
drop policy if exists email_outbox_admin on email_outbox;
create policy email_outbox_admin on email_outbox
  for all to authenticated
  using (is_admin()) with check (is_admin());

-- 리테일러 화면에서도 sendEmail() 이 호출되는 경로가 있다(이의제기 접수 알림 등).
-- 본인이 만든 건만 넣을 수 있게 허용하고, 조회·발송은 관리자만 하도록 둔다.
drop policy if exists email_outbox_insert_self on email_outbox;
create policy email_outbox_insert_self on email_outbox
  for insert to authenticated
  with check (created_by = auth.uid());
