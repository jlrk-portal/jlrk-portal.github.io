-- Migration 043 — 정산유형별 '리테일러 세금계산서 발행 대상' 여부
--   정산 확정 뒤 리테일러가 JLRK 앞으로 계산서를 끊어야 하는 유형이 있고,
--   (Seasonal Part Promotion · ASAP 전시차 · Pick up & Delivery · Recall Upselling)
--   그렇지 않은 유형이 있다. 화면에서 체크로 관리한다.
alter table settlement_types
  add column if not exists requires_invoice boolean not null default false;

update settlement_types set requires_invoice = true
 where code in ('Seasonal Part Promotion', 'ASAP_SUPPORT',
                'Pick up & Delivery', 'Recall Upselling');

-- 리테일러 화면도 이 값을 알아야 계산서 칸을 열지 말지 판단한다.
-- settlement_types 자체는 리테일러 RLS 로 막혀 있으므로 공개 뷰에 컬럼을 추가한다.
-- 컬럼 순서를 바꾸면 create or replace 가 거부되므로 뒤에 덧붙인다
drop view if exists settlement_types_public;
create view settlement_types_public as
  select id, code, name, direction, claim_unit, form_template_path,
         jsonb_strip_nulls(jsonb_build_object('preset', source_config ->> 'preset')) as source_config,
         requires_invoice
    from settlement_types;
grant select on settlement_types_public to authenticated;
