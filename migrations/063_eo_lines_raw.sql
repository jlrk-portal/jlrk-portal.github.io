-- ============================================================
--  Migration 063 — 엔진오일 원본 행을 '열 하나도 빼지 않고' 담는다
--
--  매니저 지시(2026-10-23): "내가 필드 전부 그대로 두라고했지. 너맘대로
--  빼지말라고. 원본 그대로 모든 필드 전부 업로드 시켰다가 그대로
--  내려받을수있게하라고."
--
--  지금은 파서가 쓸 열만 골라 담고 있어서, 리테일러가 받는 엑셀의 열이
--  올린 원본과 다르다. 원본 행을 통째로 같이 담는다.
--
--  ⚠ jsonb 가 아니라 json 이다. jsonb 는 키 순서를 흐트러뜨려서
--     원본 열 순서가 깨진다. json 은 넣은 그대로 보관한다.
-- ============================================================

alter table engineoil_lines add column if not exists raw json;

comment on column engineoil_lines.raw is
  '올린 원본 행 전체 {헤더: 값}. 열 순서를 지켜야 해서 jsonb 가 아니라 json.';

-- 확인
select count(*) as 전체,
       count(*) filter (where raw is not null) as 원본있음
  from engineoil_lines;
