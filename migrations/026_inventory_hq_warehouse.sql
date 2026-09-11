-- 026_inventory_hq_warehouse.sql
-- 재고 관리: 창고에 '본사'(HQ) 추가 — 기존 PDC · 지하창고(BASEMENT) 2곳에서 3곳으로.

alter table public.mkt_txns drop constraint if exists mkt_txns_warehouse_check;
alter table public.mkt_txns add constraint mkt_txns_warehouse_check
  check (warehouse in ('PDC','BASEMENT','HQ'));

alter table public.mkt_txns drop constraint if exists mkt_txns_to_warehouse_check;
alter table public.mkt_txns add constraint mkt_txns_to_warehouse_check
  check (to_warehouse in ('PDC','BASEMENT','HQ'));
