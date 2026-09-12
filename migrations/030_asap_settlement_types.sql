-- ============================================================
--  Migration 030 — ASAP 정산 유형 2종 신설
-- ============================================================
--
--  ① ASAP 전시차 지원 프로그램 (code: ASAP_SUPPORT)
--     AP · 분기 · 리테일러(법인) 단위 청구 · VAT 10% · GL 700050800
--     리테일러가 청구양식을 올리는 일반 UPLOAD 방식.
--     ⚠️ 청구양식(form_template_path)은 사용자가 정산유형 화면에서 직접 업로드한다.
--
--  ② ASAP Incentive (code: ASAP_INCENTIVE)
--     AP · 분기 · 리테일러(법인) 단위 · VAT 0% · GL 700050800
--     **관리자가 먼저 산정 파일을 올리고, 리테일러가 검토·수정본을 회신하는 방식**
--     → amount_mode = 'ADMIN_UPLOAD' + source_config.preset = 'ASAP_ADMIN_UPLOAD'
--       (리테일러 화면은 settlement_types_public 뷰만 읽어 amount_mode 가 안 보이므로
--        preset 으로 분기한다. 흐름은 index.html 에 구현됐고 스키마 변경은 없다 —
--        claims.detail / file_path / claimed_amount 만 쓴다.)
--     실제 바우처는 Service / Sales 2개 라인으로 나간다(둘 다 GL 700050800).
--
--  두 유형 모두 브랜드 고정배분 JG:LR = 10:90 (실제 바우처와 동일).
--
--  ⚠️ 이미 같은 유형을 만들어 뒀다면 아래 where not exists 가 걸러서 아무 것도 하지
--     않는다(이름에 '전시차' / 'ASAP' 이 들어간 유형이 있으면 생성 생략).
--  ⚠️ 바우처 템플릿은 SQL 로 넣을 수 없다(Storage 파일). 유형 생성 후
--     `정산 유형 관리 → 해당 유형 → 바우처 템플릿 업로드` 에서
--     `AP without PO_FY27 Q1 ASAP Incentive.xlsx` /
--     `AP Voucher_FY27 Q1 ASAP 전시차 프로그램 정산.xlsx` 를 올릴 것.
-- ============================================================

-- ------------------------------------------------------------
-- ① ASAP 전시차 지원 프로그램
-- ------------------------------------------------------------
insert into settlement_types
  (code, name, direction, period, claim_unit, amount_mode, charge_unit,
   vat_included, vat_code, brand_split_mode, brand_jg_ratio,
   budget_category, voucher_lines, due_rule, notify, is_active)
select
  'ASAP_SUPPORT', 'ASAP 전시차 지원 프로그램', 'AP', 'QUARTERLY', 'RETAILER', 'UPLOAD', 'PRIMARY',
  false, 'V1: 10%', 'FIXED', 0.10,
  'VME',
  '[{"gl_code":"700050800","description":"ASAP 전시차 지원 프로그램 정산","cc_lr":"KR02LSU300","cc_jg":"KR02JSU300"}]'::jsonb,
  '{"anchor":"next_month","day":10,"time":"18:00"}'::jsonb,
  'INSTANT', true
where not exists (
  select 1 from settlement_types
  where code = 'ASAP_SUPPORT' or name ilike '%전시차%'
);

-- ------------------------------------------------------------
-- ② ASAP Incentive  (관리자 선업로드 → 리테일러 검토/수정 회신)
-- ------------------------------------------------------------
insert into settlement_types
  (code, name, direction, period, claim_unit, amount_mode, charge_unit,
   vat_included, vat_code, brand_split_mode, brand_jg_ratio,
   budget_category, voucher_lines, source_config, due_rule, notify, is_active)
select
  'ASAP_INCENTIVE', 'ASAP Incentive', 'AP', 'QUARTERLY', 'RETAILER', 'ADMIN_UPLOAD', 'PRIMARY',
  false, 'V0: 0%', 'FIXED', 0.10,
  'VME',
  '[{"gl_code":"700050800","description":"ASAP Incentive_Service","cc_lr":"KR02LSU300","cc_jg":"KR02JSU300"},
    {"gl_code":"700050800","description":"ASAP Incentive _Sales","cc_lr":"KR02LSU300","cc_jg":"KR02JSU300"}]'::jsonb,
  '{"preset":"ASAP_ADMIN_UPLOAD"}'::jsonb,
  '{"anchor":"next_month","day":10,"time":"18:00"}'::jsonb,
  'INSTANT', true
where not exists (
  select 1 from settlement_types
  where code = 'ASAP_INCENTIVE' or name ilike '%ASAP%Incentive%'
);

-- ------------------------------------------------------------
--  확인
-- ------------------------------------------------------------
select code, name, direction, period, claim_unit, amount_mode, vat_code,
       brand_jg_ratio, budget_category,
       coalesce(form_template_path, '(청구양식 미업로드)')    as 청구양식,
       coalesce(voucher_template_path, '(바우처양식 미업로드)') as 바우처양식,
       source_config
from settlement_types
where code like 'ASAP%' or name ilike '%ASAP%' or name ilike '%전시차%'
order by code;
