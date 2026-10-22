-- ============================================================
--  Migration 056 — Turn Over 에 ASAP 인센티브용 열 추가
--
--  045 는 소매가 쪽만 담았다. ASAP 인센티브는 '품목원가합계' 로 내고
--  실적은 '담당SA'(Service) 또는 영업사원(Sales) 에 붙는다. 그 세 열이
--  빠져 있어 지금 적재분으로는 인센티브를 낼 수 없다.
--
--  (예전 27열 추출본에는 품목원가가 없어서 "Turn Over 로는 안 된다" 고
--   잘못 판단했었다. 64열 원본에는 전부 들어 있다.)
--
--  열만 추가한다 — 기존 행은 NULL 로 남고 아무것도 안 바뀐다.
--  채우려면 해당 월 Turn Over 를 다시 올리면 된다.
-- ============================================================

alter table turnover_lines add column if not exists cost      numeric;  -- 품목원가
alter table turnover_lines add column if not exists cost_sum  numeric;  -- 품목원가합계 ★ 인센티브 기준
alter table turnover_lines add column if not exists sa        text;     -- 담당SA   ★ Service 실적 귀속
alter table turnover_lines add column if not exists tech      text;     -- 작업자
alter table turnover_lines add column if not exists series    text;     -- 시리즈

-- 인센티브 집계는 '월 + 청구계정 + 차대번호 있음' 으로 훑는다
create index if not exists turnover_asap_idx on turnover_lines (ym, claim_acct)
  where vin is not null;

-- 확인 — 열이 생겼는지, 지금 몇 달치가 원가합계를 갖고 있는지
select ym,
       count(*)                                  as 행,
       count(*) filter (where cost_sum is not null) as 원가합계있음,
       count(*) filter (where sa is not null)       as 담당SA있음
  from turnover_lines group by ym order by ym desc;
