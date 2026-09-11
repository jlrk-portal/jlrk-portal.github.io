-- 025_inventory.sql
-- 마케팅 제작물 / 기프트 재고 관리 (관리자 전용)
--
-- 개념
--   - 품목 = 품목군(name) + 브랜드(brand). 예: 우산 · Defender / 우산 · Range Rover.
--     brand 가 NULL 이면 공용 단일 품목(골프백, 리플렛 등).
--   - 창고는 PDC · 지하창고(BASEMENT) 2곳만. 보관위치(bin_location)는 자유 입력 텍스트.
--   - 리테일러별 재고는 추적하지 않는다. 배부(OUT)는 창고에서 차감만 하고,
--     회수(RETURN)한 수량만 다시 창고 재고로 잡힌다.
--   - 소모품(recoverable = false: 쿠폰·리플렛 등)은 회수/미회수 집계 대상이 아니다.
--
-- 의존: public.is_admin()  (migration 022/023 에서 사용 중)

-- ── 품목 ─────────────────────────────────────────────
create table if not exists public.mkt_items (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,                       -- 품목군 (예: '우산')
  brand         text,                                -- 브랜드/변형 (예: 'Defender'); NULL = 공용
  category      text not null default '기타',        -- 굿즈 / 인쇄물 / 상품권·쿠폰 / 기타
  unit          text not null default 'EA',
  reorder_point integer not null default 0,          -- 재주문점 (합계가 이 값 미만이면 '부족')
  recoverable   boolean not null default true,       -- false = 소모품 (미회수 집계 제외)
  bin_location  text,                                -- 보관위치 (자유 입력)
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid default auth.uid()
);
create unique index if not exists mkt_items_name_brand_uq
  on public.mkt_items (name, coalesce(brand, ''));

-- ── 입출고 거래 ──────────────────────────────────────
create table if not exists public.mkt_txns (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.mkt_items(id) on delete cascade,
  txn_type     text not null check (txn_type in ('IN','OUT','RETURN','MOVE','ADJ')),
  -- IN 입고 · OUT 배부 · RETURN 회수 · MOVE 창고이동 · ADJ 실사조정
  qty          numeric not null,                     -- ADJ 는 음수 허용, 그 외 양수
  warehouse    text not null check (warehouse in ('PDC','BASEMENT')),
  to_warehouse text check (to_warehouse in ('PDC','BASEMENT')),  -- MOVE 전용 (도착 창고)
  txn_date     date not null default current_date,
  counterpart  text,                                 -- 배부 대상 / 회수 출처
  reason       text,
  memo         text,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid()
);
create index if not exists mkt_txns_item_idx on public.mkt_txns (item_id);
create index if not exists mkt_txns_date_idx on public.mkt_txns (txn_date);

-- ── 창고별 현재고 뷰 (프론트는 자체 계산하지만 조회용으로 둠) ──
create or replace view public.mkt_stock as
with signed as (
  select item_id, warehouse,
    case txn_type
      when 'IN'     then qty
      when 'RETURN' then qty
      when 'ADJ'    then qty
      when 'OUT'    then -qty
      when 'MOVE'   then -qty
    end as delta
  from public.mkt_txns
  union all
  select item_id, to_warehouse as warehouse, qty as delta
  from public.mkt_txns
  where txn_type = 'MOVE' and to_warehouse is not null
)
select item_id, warehouse, coalesce(sum(delta), 0)::numeric as on_hand
from signed
where warehouse is not null
group by item_id, warehouse;

alter view public.mkt_stock set (security_invoker = true);

-- ── RLS: 관리자 전용 ─────────────────────────────────
alter table public.mkt_items enable row level security;
alter table public.mkt_txns  enable row level security;

drop policy if exists mkt_items_admin on public.mkt_items;
create policy mkt_items_admin on public.mkt_items
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists mkt_txns_admin on public.mkt_txns;
create policy mkt_txns_admin on public.mkt_txns
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

grant select, insert, update, delete on public.mkt_items to authenticated;
grant select, insert, update, delete on public.mkt_txns  to authenticated;
grant select on public.mkt_stock to authenticated;

revoke all on public.mkt_items from anon;
revoke all on public.mkt_txns  from anon;
revoke all on public.mkt_stock from anon;
