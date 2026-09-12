-- ============================================================
--  Migration 027 — 포털 도입 전 청구이력 (legacy_settlements)
-- ============================================================
--
--  포털을 쓰기 전, 엑셀 + 메일로 처리했던 정산 내역을 보관하는 테이블.
--  rounds / claims 와 섞지 않는다 — 워크플로(제출·검토·확정)가 없는
--  "이미 끝난 기록"이라서 상태 컬럼도 없고, 수정도 하지 않는다(읽기 전용 이력).
--
--  구조: 1행 = (기간 × 지점 × 항목) 의 금액.
--    item = 'SP'        판매대금 (AR, 리테일러 → JLRK 입금)
--         = 'SAVEBACK'  사용반환금 (AP, 고객 부담분)
--         = 'SUPPORT'   JLRK 기여금 = VME + Castrol (AP, Retailer Support)
--         = 'INCENTIVE' Sales Incentive (AP, 분기)
--  항목을 행으로 눕힌 long 포맷이라 새 정산 유형이 생겨도 컬럼을 안 늘린다.
--  세부 내역(건수 / VME·Castrol 분해 / 사업자번호 등)은 detail jsonb.
--
--  지점/리테일러는 코드(text)로 먼저 넣고 FK 를 나중에 붙인다.
--  포털에 등록되지 않은 지점(예: 천안 'CH CA', 폐업한 브리티시 'BA PC')도
--  이력에는 남아야 하므로 FK 는 nullable.
-- ============================================================

create table if not exists legacy_settlements (
  id             uuid primary key default gen_random_uuid(),

  -- 어떤 정산인지
  type_code      text not null,                  -- 'ENGINE_OIL_SP' / 'ENGINE_OIL_RS' / 'ENGINE_OIL_SI'
  item           text not null,                  -- 'SP' | 'SAVEBACK' | 'SUPPORT' | 'INCENTIVE'
  direction      text not null check (direction in ('AP','AR')),

  -- 기간
  fiscal_year    text not null,                  -- 'FY26' / 'FY27'
  quarter        text,                           -- 'Q1'~'Q4'
  period_key     text not null,                  -- '2601' / 'FY26Q3' / 'FY27Q1-SI'  (정렬·그룹 키)
  period_label   text not null,                  -- 'FY26 Q4 1월'
  data_month     text,                           -- 'YYYY-MM' (원본 데이터 월, 분기 정산은 null)
  settle_month   text,                           -- 'YYYYMM'  (정산/계산서 발행 시점)

  -- 대상
  retailer_code  text not null,
  retailer_id    uuid references retailers(id) on delete restrict,
  workshop_label text not null,                  -- 원본 표기 그대로 ('AJ HN')
  workshop_code  text,                           -- 포털 코드 ('AJ-HN'), 미등록 지점은 null
  workshop_id    uuid references workshops(id) on delete restrict,
  vendor_code    text,                           -- AP 거래처 코드 (KRJD*)
  customer_code  text,                           -- AR 거래처 코드 (KR*MIS)

  -- 금액
  amount         numeric(18,2) not null default 0,
  amount_jg      numeric(18,2),
  amount_lr      numeric(18,2),

  detail         jsonb,
  source_file    text,                           -- 어느 원본에서 왔는지 (추적용)
  created_at     timestamptz not null default now()
);

create index if not exists legacy_settlements_period_idx   on legacy_settlements (period_key, item);
create index if not exists legacy_settlements_retailer_idx on legacy_settlements (retailer_id);
create index if not exists legacy_settlements_type_idx     on legacy_settlements (type_code, item);

-- ------------------------------------------------------------
--  RLS — 관리자 전체, 리테일러는 자기 법인 행만. 익명은 차단.
--  (migration 022 의 원칙 그대로: to authenticated 로만 정책을 건다)
-- ------------------------------------------------------------
alter table legacy_settlements enable row level security;

drop policy if exists legacy_read on legacy_settlements;
create policy legacy_read on legacy_settlements
  for select
  to authenticated
  using (is_admin() or retailer_id = my_retailer());

-- 쓰기는 관리자만 (시드는 SQL Editor = service_role 이라 정책과 무관하게 통과)
drop policy if exists legacy_write on legacy_settlements;
create policy legacy_write on legacy_settlements
  for all
  to authenticated
  using (is_admin())
  with check (is_admin());

revoke all on legacy_settlements from anon;
grant select on legacy_settlements to authenticated;

-- 확인용
-- select count(*) from legacy_settlements;
