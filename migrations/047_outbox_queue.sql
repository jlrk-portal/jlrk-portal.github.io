-- ============================================================
--  Migration 047 — 발송 대기함에 QUEUED / SENDING 상태 추가
--
--  구글이 Supabase Edge Function 의 서버 IP 에서 오는 SMTP 인증을
--  534 WebLoginRequired 로 막는다. 앱 비밀번호를 새로 발급해도 같다.
--  클라우드에서 Gmail SMTP 로 붙는 건 뚫어도 또 막히므로, 보내는 자리를
--  맥미니로 옮긴다 (봇 때문에 24시간 켜져 있고 Gmail SMTP 가 통한다).
--
--  흐름
--    PENDING   포털이 쌓아둔 상태. 아직 아무 데도 안 간다
--    QUEUED    매니저가 [발송] 을 눌렀다 — 워커가 가져가도 좋다는 표시
--    SENDING   워커가 집어갔다 (중복 발송 방지용 잠금)
--    SENT      나갔다
--    FAILED    실패. 사유는 error 에
--
--  "매니저가 버튼을 눌러야 나간다" 원칙은 그대로다. 워커는 QUEUED 만
--  가져가고 PENDING 은 쳐다보지 않는다.
-- ============================================================

alter table email_outbox drop constraint if exists email_outbox_status_check;
alter table email_outbox add constraint email_outbox_status_check
  check (status in ('PENDING','QUEUED','SENDING','SENT','CANCELLED','FAILED'));

-- 워커가 집어간 시각. 오래 SENDING 에 머물면 죽은 워커로 보고 되돌린다.
alter table email_outbox add column if not exists claimed_at timestamptz;
alter table email_outbox add column if not exists attempts   int not null default 0;

create index if not exists email_outbox_queued_idx
  on email_outbox (status, created_at) where status in ('QUEUED','SENDING');

-- ── 워커가 한 건을 원자적으로 집어간다 ────────────────────────────
--  두 워커가 동시에 돌아도 같은 메일이 두 번 나가면 안 된다.
--  UPDATE ... WHERE status='QUEUED' 가 행 잠금을 잡으므로 한쪽만 가져간다.
create or replace function claim_outbox_email()
returns table (id uuid, to_addrs text[], subject text, html text, attempts int)
language sql
security definer
set search_path = public
as $$
  update email_outbox o
     set status = 'SENDING', claimed_at = now(), attempts = o.attempts + 1
   where o.id = (
     select o2.id from email_outbox o2
      where o2.status = 'QUEUED'
         -- 10분 넘게 SENDING 이면 워커가 죽은 것이다. 다시 집어간다.
         or (o2.status = 'SENDING' and o2.claimed_at < now() - interval '10 minutes')
      order by o2.created_at
      limit 1
      for update skip locked
   )
  returning o.id, o.to_addrs, o.subject, o.html, o.attempts;
$$;

revoke all on function claim_outbox_email() from public, anon, authenticated;
