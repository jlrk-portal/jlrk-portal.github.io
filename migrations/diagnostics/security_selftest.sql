-- ============================================================
--  보안 자가진단 — 리테일러 A 로 '가장' 해서 남의 데이터가 보이는지
--
--  매니저가 직접 SQL 편집기에서 돌려 확인하는 용도. 읽기만 하고
--  롤백하므로 데이터는 바뀌지 않는다. 제 말만 믿지 마시고 이걸로 보세요.
--
--  원리: RLS 는 '지금 요청한 사람이 누구냐(auth.uid)' 로 거른다.
--  편집기는 관리자(postgres)라 RLS 를 통과해버리므로, 일부러 역할을
--  authenticated 로 낮추고 JWT 를 리테일러 A 것으로 꽂아 테스트한다.
-- ============================================================

begin;

-- 리테일러 A = 코드 순 첫 번째, B = 두 번째
select set_config('request.jwt.claims',
  json_build_object(
    'sub', (select p.id from profiles p
             where p.role='RETAILER'
               and p.retailer_id = (select id from retailers order by code limit 1)
             limit 1),
    'role','authenticated')::text, true);
set local role authenticated;

-- 이제 '리테일러 A' 로 조회한다. 기대값:
--   · 내 리테일러 = 1 (A 자기 것만)
--   · 남의 리테일러 라인 = 0
select '[claims] 보이는 리테일러 수 (1이어야 정상)' as 검사,
       count(distinct retailer_id)::text as 결과 from claims
union all
select '[invoices] 보이는 리테일러 수 (1)',
       count(distinct retailer_id)::text from invoices
union all
select '[disputes] 보이는 리테일러 수 (0 또는 1)',
       count(distinct retailer_id)::text from disputes
union all
select '[asap_round_lines] 보이는 리테일러 수 (0 또는 1)',
       count(distinct retailer_id)::text from asap_round_lines
union all
select '[engineoil_lines] 보이는 리테일러 수 (0 또는 1)',
       count(distinct retailer_id)::text from engineoil_lines
union all
select '[campaign_lines] 보이는 리테일러 수 (0 또는 1)',
       count(distinct retailer_id)::text from campaign_lines
union all
select '[incentive_sellers] 보이는 리테일러 수 (0 또는 1)',
       count(distinct retailer_id)::text from incentive_sellers
union all
select '[turnover_lines] 보이는 행 (0이어야 — 원본은 관리자만)',
       count(*)::text from turnover_lines
union all
select '[sales_report_lines] 보이는 행 (0 — 관리자만)',
       count(*)::text from sales_report_lines
union all
select '[iqm_vehicles] 보이는 행 (0 — 084 적용 후 관리자만)',
       count(*)::text from iqm_vehicles
union all
select '[part_prices] 보이는 행 (0 — 084 적용 후 관리자만)',
       count(*)::text from part_prices
union all
select '[asap_line_overrides] 보이는 행 (0 — 084 적용 후 관리자만)',
       count(*)::text from asap_line_overrides
union all
select '[settled_records] 보이는 행 (0 — 관리자만)',
       count(*)::text from settled_records
union all
select '[email_outbox] 보이는 행 (0 — 관리자만)',
       count(*)::text from email_outbox
union all
select '[profiles] 보이는 행 (1 — 본인만)',
       count(*)::text from profiles
union all
-- 계산 함수 직접 호출 — 084 적용 후 거부돼야 한다 (에러나면 그게 정상)
select '[asap_lines_admin] 리테일러가 부르면? (관리자만 → 에러가 정상)',
       'RLS/권한으로 막힘이 정상' ;

rollback;
reset role;

-- rollback 뒤 관리자로 돌아와 한 번 더: using(true) 로 남은 민감 SELECT 정책이 없어야
select tablename, policyname, qual as 조건
  from pg_policies
 where schemaname='public' and cmd='SELECT' and (qual='true' or qual is null)
 order by tablename;
