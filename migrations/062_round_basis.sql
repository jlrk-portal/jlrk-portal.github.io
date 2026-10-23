-- ============================================================
--  Migration 062 — 회차에 '기준월' 을 따로 둔다
--
--  매니저 지적(2026-10-23): 같은 10월 정산인데 회차 라벨이 제각각이다.
--    Engine Oil Package_Sales Payment (AR)  →  '2026-09'  (대상 월로 적음)
--    Engine Oil Package_사용반환금/RS        →  '2026-10'  (진행 월로 적음)
--  라벨 하나에 두 가지 뜻이 섞여 있어, 바우처가 'FY27 Q2 ... _202608' 처럼
--  엉뚱한 월로 나왔다. 포털이 '정산월 − 1' 로 추측하던 것도 이 때문이다.
--
--  뜻을 갈라 둔다.
--    정산월 (period_ym / period_label) — 정산을 '진행하는' 월
--    기준월 (basis_label / basis_ym)   — 정산의 '대상이 되는' 기간
--
--  기준월은 월일 수도, 분기일 수도, 분기 여러 개일 수도 있다.
--    엔진오일(월정산)   정산월 2026-10 · 기준월 2026-09
--    리콜 업셀링        정산월 2026-10 · 기준월 FY27 Q2
--    Welcome Back       정산월 2026-10 · 기준월 FY27 Q1, Q2
--  그래서 basis_label 은 자유 입력이고, basis_ym 은 월정산일 때만 채운다.
--
--  ⚠ 지금 값은 건드리지 않는다. 라벨을 그대로 기준월로 복사해 두고,
--     어느 회차가 손봐야 하는지 아래 확인 쿼리로 보여준다.
-- ============================================================

alter table rounds add column if not exists basis_label text;   -- '2026-09' · 'FY27 Q2' · 'FY27 Q1, Q2'
alter table rounds add column if not exists basis_ym    text;   -- 월정산일 때만 'YYYYMM'

alter table rounds drop constraint if exists rounds_basis_ym_chk;
alter table rounds add constraint rounds_basis_ym_chk
  check (basis_ym is null or basis_ym ~ '^20\d{2}(0[1-9]|1[0-2])$');

create index if not exists rounds_basis_ym_idx on rounds (basis_ym);

-- 출발점: 지금 라벨을 그대로 기준월로 둔다. (추측해서 밀어 넣지 않는다 —
-- 라벨이 진행월인 회차와 대상월인 회차가 섞여 있어 어느 쪽도 안전하지 않다)
update rounds set basis_label = period_label where basis_label is null;
update rounds set basis_ym = period_ym
 where basis_ym is null and period_ym is not null;

-- ── 확인 — 손봐야 할 회차. 월정산인데 정산월과 기준월이 같으면 둘 중 하나가 틀렸다.
select t.code as 유형, t.period as 주기,
       r.period_label as 정산_라벨, coalesce(r.period_ym,'—') as 정산월,
       coalesce(r.basis_label,'—') as 기준_라벨, coalesce(r.basis_ym,'—') as 기준월,
       r.status::text as 상태,
       case when t.period = 'MONTHLY' and r.period_ym is not null
                 and r.period_ym = r.basis_ym then '⚠ 확인 필요' else '' end as 비고
  from rounds r join settlement_types t on t.id = r.type_id
 where r.status <> 'ARCHIVED'
 order by t.code, r.created_at desc;
