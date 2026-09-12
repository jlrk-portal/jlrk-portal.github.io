-- ============================================================
--  Migration 032 — Pick up & Delivery 시드 중복 1회분 제거
-- ============================================================
--
--  2026-09-13 배포 후 점검 결과, `legacy_settlements` 가 952행이었다.
--  기대값은 840행 (Engine Oil 555 + P&D 112 + ASAP 173).
--    · Engine Oil 555행 ✔   · ASAP 173행 ✔
--    · **P&D 224행 = 112행 × 2** (금액도 정확히 2배: 1,906,028,334 = 953,014,167 × 2)
--  → 029 시드가 두 번 실행됐다. 완전히 동일한 행이 2벌 들어간 상태다.
--
--  이 스크립트는 (기간 × 지점) 조합마다 **가장 먼저 들어간 1행만 남기고** 나머지를
--  지운다. P&D 는 설계상 (기간 × 지점) 이 유일하므로 안전하다.
--
--  ⚠️ 실행 전 확인용 select 로 지워질 행 수(112)를 먼저 보고, 맞으면 delete 를 돌린다.
-- ============================================================

-- ① 현재 상태 (실행 전)
select item, count(*) as rows, sum(amount) as 합계
from legacy_settlements
where item = 'PND'
group by item;
-- 기대: 224행 / 1,906,028,334

-- ② 지워질 행 수 미리보기 — 112 가 나와야 한다
with d as (
  select id,
         row_number() over (partition by period_key, workshop_label
                            order by created_at, id) as rn
  from legacy_settlements
  where item = 'PND'
)
select count(*) as 삭제예정 from d where rn > 1;

-- ③ 중복 제거
with d as (
  select id,
         row_number() over (partition by period_key, workshop_label
                            order by created_at, id) as rn
  from legacy_settlements
  where item = 'PND'
)
delete from legacy_settlements l
using d
where d.id = l.id and d.rn > 1;

-- ④ 결과 확인 — 112행 / 953,014,167 이어야 한다
select item, count(*) as rows, sum(amount) as 합계
from legacy_settlements
where item = 'PND'
group by item;

-- ⑤ 전체 최종 확인 — 840행, 유형 6종
select type_code, item, count(*) as rows, sum(amount) as 합계
from legacy_settlements
group by type_code, item
order by type_code, item;

select count(*) as 총행수 from legacy_settlements;
-- 기대: 840
--   Engine Oil Package_SP(ENGINE_OIL_SP/SP)         172행  5,306,801,864
--   Engine Oil Package_RS(ENGINE_OIL_RS/SAVEBACK)   172행  1,819,060,918
--   Engine Oil Package_RS(ENGINE_OIL_RS/SUPPORT)    172행    454,765,229
--   Engine Oil Package_SI(ENGINE_OIL_SI/INCENTIVE)   39행     76,270,000
--   Pick up & Delivery / PND                        112행    953,014,167
--   ASAP_SUPPORT / ASAP_SUPPORT                      36행    191,905,441
--   ASAP_INCENTIVE / ASAP_SVC                        71행     59,100,000
--   ASAP_INCENTIVE / ASAP_SALES                      66행     99,510,000
