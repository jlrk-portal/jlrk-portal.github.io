-- ============================================================
--  Migration 036 — 월별 부품가격 (part_prices) + 캠페인 검증 보조
--
--  캠페인 정산 검증은 "청구 시점 그 달의 소비자가"로 대조해야 한다.
--  부품가가 매월 바뀌므로 월(ym)별로 적재한다.
--  (2026-09-01 인상 실측: 28LR132077 46,500 → 47,000)
-- ============================================================

create table if not exists part_prices (
  ym          text not null,                    -- 'YYYYMM'
  part_no     text not null,
  brand       text,
  part_name   text,
  retail      numeric,                          -- 소비자가격(부가세포함)
  niv         numeric,                          -- Stock NIV
  part_group  text,
  loaded_at   timestamptz not null default now(),
  primary key (ym, part_no)
);
create index if not exists part_prices_pn_idx on part_prices (part_no);

alter table part_prices enable row level security;
drop policy if exists part_prices_admin on part_prices;
create policy part_prices_admin on part_prices
  for all to authenticated using (is_admin()) with check (is_admin());
-- 리테일러도 자기 청구 검증 근거로 단가를 볼 수 있어야 한다 (읽기만)
drop policy if exists part_prices_read on part_prices;
create policy part_prices_read on part_prices
  for select to authenticated using (true);

-- 적재된 월 목록 (검증 화면에서 "해당 월 파일 없음" 경고에 사용)
create or replace view part_price_months as
  select ym, count(*) as parts, max(loaded_at) as loaded_at
  from part_prices group by ym order by ym desc;
