-- ============================================================
--  Migration 085 — One Care Incentive (연장보증/EW) 기반
--
--  매니저 지시(2026-10-24): 업체가 수기로 계산해 보내던 One Care 인센티브를
--  로우데이터만 올리면 자동 계산되게. ASAP 과 동일한 흐름(전시장/서비스
--  구분 · 판매자 수정 · 확정 · 바우처).
--
--  로직 (DMS 엑셀 분석):
--   · 가입 1건 = 1행. (리테일러·지점·구분[서비스/전시장]·판매자) 로 묶어 count.
--   · 환불 중 '차감 대상' 만 판매자 count 에서 뺀다.
--   · 최종 개수 × 단가(200,000) = 인센티브. 서비스·전시장 단가 동일.
--   · 환불 차감 여부 / 퇴직 처리는 포털에서 매니저가 라인 단위로 결정
--     (ASAP 의 제외/승인과 동일) — 하드코딩 규칙 없음.
--
--  이 마이그레이션은 '뼈대' 다 — 유형 + 원천 3개 표. 엔진·화면·바우처는 뒤에.
--  원천은 열을 버리지 않는다(raw json). ASAP·턴오버에서 쓴 원칙 그대로.
-- ============================================================

-- ── 1. 유형 — 시스템 산출 AP, 세금계산서 미발행(인센티브)
--     운영에는 ADMIN_UPLOAD 버전이 이미 있으니, 검증서버엔 SYSTEM 으로 새로 만든다.
insert into settlement_types (code, name, direction, period, claim_unit,
    amount_mode, source_config, vat_code, requires_invoice, budget_category,
    brand_jg_ratio, unit_price, is_active)
values ('ONE_CARE_EW', 'One Care Incentive (EW)', 'AP', 'QUARTERLY', 'RETAILER',
    'SYSTEM', '{"preset":"ONECARE_EW"}'::jsonb, 'V0: 0%', false, 'VME',
    0.10, 200000, true)
on conflict (code) do update set
    amount_mode='SYSTEM', source_config='{"preset":"ONECARE_EW"}'::jsonb,
    unit_price=200000, requires_invoice=false, is_active=true;

-- 단가는 설정값으로도 둔다 (유형 unit_price 와 별개로 엔진이 읽기 쉽게)
create table if not exists onecare_config (
  k text primary key, v jsonb not null, note text,
  updated_at timestamptz not null default now()
);
insert into onecare_config (k, v, note) values
  ('unit_price', '200000'::jsonb, '가입 1건당 인센티브 (서비스·전시장 동일)')
on conflict (k) do nothing;


-- ── 2. 가입 (DMS 가입 내역) — 분기별. 1행 = EW 가입 1건.
create table if not exists onecare_enroll (
  id          bigserial primary key,
  round_id    uuid references rounds(id) on delete cascade,
  src_file    text, src_row int,
  vin         text,
  brand       text,
  model       text,
  delivery_date date,          -- 출고일자
  enroll_date date,            -- 서비스가입일 (분기 판정 기준)
  retailer_code text,          -- Retailer
  branch      text,            -- 지점
  scope       text,            -- 구분: 서비스 / 전시장
  seller      text,            -- 판매자
  sap_code    text,            -- SAP code (바우처 거래처 매핑용)
  raw         json,            -- 원본 행 전체
  loaded_at   timestamptz not null default now()
);
create index if not exists onecare_enroll_round on onecare_enroll (round_id);
create index if not exists onecare_enroll_vin   on onecare_enroll (vin);
alter table onecare_enroll enable row level security;
drop policy if exists onecare_enroll_admin on onecare_enroll;
create policy onecare_enroll_admin on onecare_enroll for all to authenticated
  using (is_admin()) with check (is_admin());


-- ── 3. 환불 (DMS 해지/환불 내역) — 분기별.
create table if not exists onecare_refund (
  id          bigserial primary key,
  round_id    uuid references rounds(id) on delete cascade,
  src_file    text, src_row int,
  insurer     text,            -- 보험사
  vin         text,
  model       text,
  month_ym    text,            -- Month (2607 …)
  cancel_req_date date,        -- 해지요청
  sell_branch text,            -- 판매지점
  seller      text,            -- 판매자
  reason      text,            -- 사유 (고객변심 · 차량매각 …)
  employed    text,            -- 재직여부 (O/X)
  retailer_code text,
  raw         json,
  loaded_at   timestamptz not null default now()
);
create index if not exists onecare_refund_round on onecare_refund (round_id);
alter table onecare_refund enable row level security;
drop policy if exists onecare_refund_admin on onecare_refund;
create policy onecare_refund_admin on onecare_refund for all to authenticated
  using (is_admin()) with check (is_admin());


-- ── 4. 재직 명단 (분기말 기준)
create table if not exists onecare_roster (
  id          bigserial primary key,
  round_id    uuid references rounds(id) on delete cascade,
  src_file    text, src_row int,
  retailer_code text,
  branch      text,
  scope       text,            -- 서비스 / 전시장
  name        text,            -- 판매자 이름
  status      text,            -- 재직 / 퇴직
  raw         json,
  loaded_at   timestamptz not null default now()
);
create index if not exists onecare_roster_round on onecare_roster (round_id);
alter table onecare_roster enable row level security;
drop policy if exists onecare_roster_admin on onecare_roster;
create policy onecare_roster_admin on onecare_roster for all to authenticated
  using (is_admin()) with check (is_admin());


-- 확인
select 'onecare_enroll' as 표,
       case when to_regclass('public.onecare_enroll') is not null then 'ok' else '없음' end as 상태
union all select 'onecare_refund',
       case when to_regclass('public.onecare_refund') is not null then 'ok' else '없음' end
union all select 'onecare_roster',
       case when to_regclass('public.onecare_roster') is not null then 'ok' else '없음' end
union all select 'One Care 유형(EW)', (select code from settlement_types where code='ONE_CARE_EW')
union all select '단가', (select v::text from onecare_config where k='unit_price');
