-- Migration 042 — 리테일러 '정산 확정' 기한
--   claim_due_at(청구 마감) · invoice_due_at(계산서 마감) 과 별개로,
--   "리테일러가 확정 버튼을 눌러야 하는 기한" 을 따로 둔다.
--   기한이 지나면 리테일러는 더 이상 손대지 못하고, 관리자가 일괄 확정으로 닫는다.
alter table rounds add column if not exists confirm_due_at timestamptz;
