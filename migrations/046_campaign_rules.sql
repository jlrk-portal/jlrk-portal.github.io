-- ============================================================
--  Migration 046 — 캠페인 검증 조건 (포털에서 설정)
--
--  지금까지 검증 규칙은 파이썬 스크립트 안에 박혀 있었다
--  (하계: 2021-01-01 기준 30/20%, 정가 100만원, 캠페인DC 계정).
--  캠페인마다 규칙이 다르므로 매니저가 포털에서 직접 쌓게 한다.
--  조건 하나 = 검토 화면 대조표 한 줄.
-- ============================================================

create table if not exists campaign_rules (
  id          uuid primary key default gen_random_uuid(),
  type_id     uuid references settlement_types(id) on delete cascade,
  round_id    uuid references rounds(id) on delete cascade,   -- null = 유형 기본값
  name        text,

  -- 기준일 : 어떤 날짜로 캠페인 기간을 판정할지
  basis       text not null default 'in_date'
                check (basis in ('in_date','ro_date','inv_date')),
  period_from date,
  period_to   date,
  grace       date,                       -- 청구 유예 (입고는 기간 내, 마감은 이 날까지)

  price_ym    text,                       -- 소비자가 대조에 쓸 부품가격 월 'YYYYMM'
  share_jlrk  numeric not null default 50,  -- JLRK 분담율 (%)

  conditions  jsonb not null default '[]'::jsonb,
  -- [{ "type":"REG_DATE_RATE", "cut":"2021-01-01", "before":30, "after":20, "level":"ng" }, ...]
  --  type  : REG_DATE_RATE | FIXED_RATE | PART_RETAIL_MIN | PART_PRICE_MATCH
  --          | PART_IN_MASTER | PART_NO | PART_GROUP | VIN_LIST | RECALL_CODE
  --          | CLAIM_ACCOUNT | SHARE_BALANCE | NO_DUP_CLAIM | MODEL | BRAND
  --  level : ng(실패) | wn(확인필요)

  is_active   boolean not null default true,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null
);
create index if not exists campaign_rules_type_idx  on campaign_rules (type_id);
create index if not exists campaign_rules_round_idx on campaign_rules (round_id);

-- ── 대상 차대 / 리콜 대상 목록 (엑셀 업로드) ────────────────────
create table if not exists campaign_vin_lists (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  type_id     uuid references settlement_types(id) on delete cascade,
  round_id    uuid references rounds(id) on delete cascade,
  kind        text not null default 'VIN' check (kind in ('VIN','RECALL')),
  n           int  not null default 0,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null
);

create table if not exists campaign_vin_rows (
  list_id uuid not null references campaign_vin_lists(id) on delete cascade,
  vin     text not null,
  code    text,                            -- 리콜코드 등
  note    text,
  primary key (list_id, vin)
);
create index if not exists campaign_vin_rows_vin on campaign_vin_rows (vin);

alter table campaign_rules     enable row level security;
alter table campaign_vin_lists enable row level security;
alter table campaign_vin_rows  enable row level security;

drop policy if exists campaign_rules_admin on campaign_rules;
create policy campaign_rules_admin on campaign_rules
  for all to authenticated using (is_admin()) with check (is_admin());
-- 리테일러도 자기에게 적용되는 조건은 볼 수 있어야 한다 (읽기만)
drop policy if exists campaign_rules_read on campaign_rules;
create policy campaign_rules_read on campaign_rules
  for select to authenticated using (true);

drop policy if exists campaign_vin_lists_admin on campaign_vin_lists;
create policy campaign_vin_lists_admin on campaign_vin_lists
  for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists campaign_vin_rows_admin on campaign_vin_rows;
create policy campaign_vin_rows_admin on campaign_vin_rows
  for all to authenticated using (is_admin()) with check (is_admin());
