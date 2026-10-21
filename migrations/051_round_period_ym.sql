-- ============================================================
--  Migration 051 — 회차에 '정산 월' 추가
--
--  엔진오일 패키지처럼 월단위로 도는 정산은 회계연도·분기만으로는
--  회차를 특정할 수 없다. 기간 라벨도 '2026-09' / 'FY27 Q2 8월' 처럼
--  제각각이라 정렬·집계가 안 된다. 'YYYYMM' 한 칸을 둔다.
--  (마스터 파일의 '정산시기' 와 같은 개념)
--
--  분기 유형에는 비워 둔다 — 기존 회차는 건드리지 않는다.
-- ============================================================
alter table rounds add column if not exists period_ym text;

alter table rounds drop constraint if exists rounds_period_ym_chk;
alter table rounds add constraint rounds_period_ym_chk
  check (period_ym is null or period_ym ~ '^20\d{2}(0[1-9]|1[0-2])$');

create index if not exists rounds_period_ym_idx on rounds (period_ym);
