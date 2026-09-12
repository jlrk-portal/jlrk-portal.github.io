-- ============================================================
--  Migration 033 — One Care Incentive 정산 유형 신설
-- ============================================================
--
--  One Care Incentive (code: ONE_CARE_INCENTIVE)
--    AP · 분기 · 리테일러(법인) 단위 · VAT 0% · **GL 700030201**
--    브랜드 고정배분 JG:LR = 10:90 (실제 바우처와 동일)
--    바우처는 컴포넌트 2개로 나간다 — Service(SVC) / Sales·SR
--
--  정산 방식은 **ASAP Incentive 와 동일**하다 (사용자 지시):
--    관리자가 먼저 산정해 공유 → 리테일러가 확인 또는 수정본 회신 → 관리자 확정
--    → amount_mode = 'ADMIN_UPLOAD' + source_config.preset = 'ADMIN_UPLOAD'
--    (리테일러 화면은 settlement_types_public 뷰만 읽어 amount_mode 가 안 보이므로
--     preset 으로 분기한다. index.html 의 isAdminUploadType() 이 'ADMIN_UPLOAD' 와
--     기존 'ASAP_ADMIN_UPLOAD' 둘 다 인식한다. 스키마 변경 없음.)
--
--  ⚠️ Recall & Upselling Program 은 이미 유형이 있다(`Recall Upselling Program`,
--     UPLOAD/VAT 10%) — 새로 만들지 않고 034 에서 과거이력만 그 유형에 붙인다.
--  ⚠️ 이미 One Care 유형을 만들어 뒀으면 where not exists 가 걸러서 아무 것도 안 한다.
--  ⚠️ 바우처 템플릿은 Storage 파일이라 SQL 로 못 넣는다 — 유형 생성 후
--     `정산 유형 관리 → One Care Incentive → 바우처 템플릿 업로드` 에서
--     `FY27 Q1 One Care Incentive Voucher.xlsx` 를 올릴 것.
-- ============================================================

insert into settlement_types
  (code, name, direction, period, claim_unit, amount_mode, charge_unit,
   vat_included, vat_code, brand_split_mode, brand_jg_ratio,
   budget_category, voucher_lines, source_config, due_rule, notify, is_active)
select
  'ONE_CARE_INCENTIVE', 'One Care Incentive', 'AP', 'QUARTERLY', 'RETAILER', 'ADMIN_UPLOAD', 'PRIMARY',
  false, 'V0: 0%', 'FIXED', 0.10,
  'VME',
  '[{"gl_code":"700030201","description":"One Care Incentive_Service","cc_lr":"KR02LSU300","cc_jg":"KR02JSU300"},
    {"gl_code":"700030201","description":"One Care Incentive_SR","cc_lr":"KR02LSU300","cc_jg":"KR02JSU300"}]'::jsonb,
  '{"preset":"ADMIN_UPLOAD"}'::jsonb,
  '{"anchor":"next_month","day":10,"time":"18:00"}'::jsonb,
  'INSTANT', true
where not exists (
  select 1 from settlement_types
  where code = 'ONE_CARE_INCENTIVE'
     or name ilike '%one care%incentive%'
     or name ilike '%EW Incentive%'
);

-- 확인
select code, name, direction, period, claim_unit, amount_mode, vat_code,
       brand_jg_ratio, source_config,
       coalesce(voucher_template_path, '(바우처양식 미업로드)') as 바우처양식
from settlement_types
where code = 'ONE_CARE_INCENTIVE' or name ilike '%one care%'
order by code;
