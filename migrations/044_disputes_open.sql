-- Migration 044 — 접수중(OPEN) 회차에서도 리테일러가 이의를 제출할 수 있게
--   기존 정책은 AR 흐름(PUBLISHED)만 가정했다. P&D 처럼
--   '공지 = 접수중(OPEN)' 인 유형에서는 이의 제출이 RLS 로 막혔다.
--   (실측 2026-10-20: new row violates row-level security policy for table "disputes")
--   기한 가드는 유지하되, P&D 의 '정산 확정 기한'(confirm_due_at)도 함께 본다.
drop policy if exists disputes_retailer_write on disputes;
create policy disputes_retailer_write on disputes for insert to authenticated
  with check (
    retailer_id = my_retailer()
    and exists (
      select 1 from rounds r
       where r.id = disputes.round_id
         and r.status in ('OPEN'::round_status, 'PUBLISHED'::round_status)
         and (r.dispute_due_at  is null or now() < r.dispute_due_at)
         and (r.confirm_due_at  is null or now() < r.confirm_due_at)
    )
  );

drop policy if exists disputes_retailer_update on disputes;
create policy disputes_retailer_update on disputes for update to authenticated
  using (
    retailer_id = my_retailer()
    and status = 'RAISED'::dispute_status
    and exists (
      select 1 from rounds r
       where r.id = disputes.round_id
         and r.status in ('OPEN'::round_status, 'PUBLISHED'::round_status)
         and (r.dispute_due_at  is null or now() < r.dispute_due_at)
         and (r.confirm_due_at  is null or now() < r.confirm_due_at)
    )
  )
  with check (retailer_id = my_retailer());
