-- Migration 039 — 캠페인 RO 상세를 '부품 단위'로 보여주기 위한 스냅샷
--   기존 close_lines 는 Turn Over 줄을 그대로 담아 한 RO 에 70줄씩 쌓였다.
--   검토자는 공임을 볼 필요가 없고, 품번으로 묶어 계정별 분할율과
--   청구↔마감 차이를 한 줄에서 봐야 한다. part_rows 가 그 표다.
alter table campaign_ro add column if not exists part_rows jsonb;
alter table campaign_ro add column if not exists labour_lines int not null default 0;
-- 대표 사유 — 수백 건을 같은 성격끼리 묶어 일괄 처리하기 위한 분류
alter table campaign_ro add column if not exists reason text;
create index if not exists campaign_ro_reason_idx on campaign_ro (round_id, reason);
