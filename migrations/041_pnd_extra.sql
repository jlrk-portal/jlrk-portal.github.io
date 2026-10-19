-- Migration 041 — P&D 원본 엑셀의 나머지 컬럼 보관
--   다운로드 파일에 "리테일러가 올린 원본 필드는 전부" 담아야 한다 (2026-10-19 매니저 지시).
--   PC/OC 여부 · 주유비 · 특이사항 · 비고 · DMS예약번호 · DMS사용목적
alter table pnd_lines add column if not exists extra jsonb;
