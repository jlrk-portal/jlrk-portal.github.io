-- ============================================================
--  Migration 059 — ASAP 액세서리 인센티브 산출 엔진
--
--  매니저 목적: 회차를 만들면 그 분기 Turn Over 로 자동 계산.
--  한 분기가 35만 행이라 브라우저로는 못 끌어온다. DB 에서 센다.
--
--  규칙은 FY27 Q1 실파일(1,528행)로 전부 대조해 확인한 것이다.
--    · 대상   : 청구계정 ∈ {일반, 원가장착(ACC), 부품판매(개인)} AND 차대번호 있음
--    · 판매구분: VIN 이 [전분기 마지막월 1일 ~ 당분기말] Sales Report 에
--               있으면 Sales(전시장·영업사원), 아니면 Service(AS지점·담당SA)
--    · 요율   : L663(Defender) 15% · 그 외 7%
--               모델은 IQM 이 우선. IQM 에 없으면 Turn Over 기록값.
--    · 제외   : Sales Report Order Type DM(시승차)·LC(커티시카)·OUV(특수차)
--               — 분기말 기준 1년 전까지 본다
--               L460 + 차대 6번째 자리 B → DSS 기본장착 (지정 품번만)
--               관리자가 올린 전시차 VIN 목록
--    · 금액   : 올림(원가합계 × 요율 ÷ 10,000) × 10,000
--
--  분기는 '인보이스완료일(inv_date)' 로 자른다. 적재월(ym)로 자르면
--  달을 넘나드는 중복이 먼저 적재된 달에 남아 빠진다. (058 참고)
-- ============================================================

-- ── 설정: 대상 청구계정 · 요율 · DSS 품번. 바뀌면 여기만 고친다.
create table if not exists asap_config (
  k text primary key,
  v jsonb not null,
  note text,
  updated_at timestamptz not null default now()
);

insert into asap_config (k, v, note) values
  ('claim_accounts',
   '["일반","원가장착(ACC)","부품판매(개인)"]'::jsonb,
   '집계 대상 청구계정. 차대번호가 있는 라인만 센다.'),
  ('rates',
   '{"L663": 0.15, "DEFAULT": 0.07}'::jsonb,
   'L663(Defender) 15%, 그 외 7%.'),
  ('exclude_order_types',
   '["DM","LC","OUV"]'::jsonb,
   'Sales Report Order Type — 시승차·커티시카·특수차.'),
  ('dss_parts',
   '[]'::jsonb,
   'L460 LWB 기본장착(DSS) 품번. 비우면 DSS 제외를 걸지 않는다. '
   '⚠ 차 전체를 빼면 안 된다 — 휠커버·매트 같은 정상 유상 건이 같이 걸린다.'),
  ('round_unit',
   '10000'::jsonb,
   '올림 단위.')
on conflict (k) do nothing;

alter table asap_config enable row level security;
drop policy if exists asap_config_admin on asap_config;
create policy asap_config_admin on asap_config
  for all to authenticated using (is_admin()) with check (is_admin());


-- ============================================================
--  라인 단위 산출 — 한 줄이 왜 그렇게 잡혔는지까지 돌려준다
-- ============================================================
create or replace function asap_lines(
  p_from        date,
  p_to          date,
  p_showroom_list uuid default null   -- 이번 분기 전시차 VIN 목록 (campaign_vin_lists.id)
)
returns table (
  vin          text,
  inv_date     date,
  part_no      text,
  part_name    text,
  claim_acct   text,
  cost_sum     numeric,
  model_code   text,
  is_defender  boolean,
  rate         numeric,
  scope        text,     -- SALES | SERVICE
  branch       text,
  person       text,
  excluded     text      -- null 이면 집계 대상
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
with cfg as (
  select
    (select v from asap_config where k = 'claim_accounts')      as accounts,
    (select v from asap_config where k = 'rates')               as rates,
    (select v from asap_config where k = 'exclude_order_types') as ex_types,
    (select v from asap_config where k = 'dss_parts')           as dss
),
-- 판매구분 판정 창: 전분기 마지막 월 1일 ~ 당분기말
sales_win as (
  select distinct on (vin)
         vin, showroom, seller, retail_date
    from sales_report_lines
   where vin is not null
     and retail_date between (date_trunc('month', p_from) - interval '1 month')::date and p_to
   order by vin, retail_date desc
),
-- 제외 판정 창: 분기말 기준 1년 전까지
excl_win as (
  select distinct vin
    from sales_report_lines, cfg
   where vin is not null
     and retail_date between (p_to - interval '1 year')::date and p_to
     and order_type = any (select jsonb_array_elements_text(cfg.ex_types))
),
showroom_vins as (
  select vin from campaign_vin_rows where p_showroom_list is not null and list_id = p_showroom_list
),
base as (
  select t.vin, t.inv_date, t.part_no, t.part_name, t.claim_acct,
         coalesce(t.cost_sum, 0)                        as cost_sum,
         -- 모델은 IQM 이 우선. 없으면 Turn Over 기록값에서 코드를 긁는다.
         coalesce(
           substring(coalesce(i.vehicle_line, i.model_code, '') from '(L[0-9]{3})'),
           substring(coalesce(t.model, t.series, '')     from '(L[0-9]{3})')
         )                                              as model_code,
         s.showroom, s.seller,
         t.workshop, t.sa,
         (s.vin is not null)                            as is_sales,
         (e.vin is not null)                            as is_excl_type,
         (v.vin is not null)                            as is_showroom
    from turnover_lines t
    cross join cfg
    left join iqm_vehicles   i on i.vin = t.vin
    left join sales_win      s on s.vin = t.vin
    left join excl_win       e on e.vin = t.vin
    left join showroom_vins  v on v.vin = t.vin
   where t.inv_date between p_from and p_to
     and t.vin is not null
     and t.claim_acct = any (select jsonb_array_elements_text(cfg.accounts))
)
select
  b.vin, b.inv_date, b.part_no, b.part_name, b.claim_acct, b.cost_sum,
  b.model_code,
  (b.model_code = 'L663')                                        as is_defender,
  case when b.model_code = 'L663'
       then (select (rates->>'L663')::numeric    from cfg)
       else (select (rates->>'DEFAULT')::numeric from cfg) end   as rate,
  case when b.is_sales then 'SALES' else 'SERVICE' end           as scope,
  case when b.is_sales then b.showroom else b.workshop end       as branch,
  case when b.is_sales then b.seller   else b.sa       end       as person,
  case
    when b.is_excl_type then '시승차·커티시카·특수차'
    when b.is_showroom  then '전시차'
    when b.model_code = 'L460' and substring(b.vin from 6 for 1) = 'B'
         and b.part_no in (select jsonb_array_elements_text(cfg.dss))
         then 'DSS 기본장착'
    -- 원가 0 인 줄은 빼지 않는다. 금액이 0 이라 결과는 같은데, 빼버리면
    -- 매니저 파일의 행수와 안 맞아 대조가 어려워진다.
    else null
  end                                                            as excluded
  from base b cross join cfg
$$;

revoke all on function asap_lines(date, date, uuid) from public;
grant execute on function asap_lines(date, date, uuid) to authenticated;


-- ============================================================
--  지점·판매자별 집계 — 화면과 정산에 쓰는 값
-- ============================================================
create or replace function asap_summary(
  p_from date,
  p_to   date,
  p_showroom_list uuid default null
)
returns table (
  scope     text,
  branch    text,
  person    text,
  lines     bigint,
  vins      bigint,
  cost_sum  numeric,
  amount    numeric
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with l as (
    select * from asap_lines(p_from, p_to, p_showroom_list) where excluded is null
  ),
  u as (select (v #>> '{}')::numeric as unit from asap_config where k = 'round_unit')
  select l.scope, l.branch, l.person,
         count(*)                       as lines,
         count(distinct l.vin)          as vins,
         sum(l.cost_sum)                as cost_sum,
         -- 올림(원가합계 × 요율 ÷ 단위) × 단위. 요율이 섞이므로 라인별로 곱해 더한다.
         ceil(sum(l.cost_sum * l.rate) / (select unit from u)) * (select unit from u) as amount
    from l
   group by l.scope, l.branch, l.person
   order by l.scope, l.branch, l.person
$$;

revoke all on function asap_summary(date, date, uuid) from public;
grant execute on function asap_summary(date, date, uuid) to authenticated;


-- ============================================================
--  확인 — FY27 Q2 (2026-07-01 ~ 2026-09-30)
-- ============================================================

-- ① 그 분기에 어떤 청구계정이 있고 대상이 몇 줄인지 (대상 계정 문자열 확인용)
select claim_acct as 청구계정, count(*) as 행,
       count(*) filter (where vin is not null) as 차대있음,
       to_char(sum(coalesce(cost_sum,0)),'FM999,999,999,999') as 원가합계
  from turnover_lines
 where inv_date between date '2026-07-01' and date '2026-09-30'
 group by claim_acct order by 차대있음 desc limit 15;

-- ② 집계 결과 요약
select scope as 구분, count(*) as 인원,
       sum(lines) as 라인, sum(vins) as 차량,
       to_char(sum(cost_sum),'FM999,999,999,999') as 원가합계,
       to_char(sum(amount),'FM999,999,999,999') as 인센티브
  from asap_summary(date '2026-07-01', date '2026-09-30')
 group by scope order by scope;

-- ③ 제외 사유별 몇 줄이 빠졌는지
select coalesce(excluded,'(집계 대상)') as 사유, count(*) as 행,
       to_char(sum(cost_sum),'FM999,999,999,999') as 원가합계
  from asap_lines(date '2026-07-01', date '2026-09-30')
 group by 1 order by 행 desc;

-- ④ 대조용 — 대상 라인의 품목유형·요율 구성
select case when is_defender then 'L663 15%' else '그 외 7%' end as 요율,
       coalesce(model_code,'(모델없음)') as 모델, count(*) as 행,
       to_char(sum(cost_sum),'FM999,999,999,999') as 원가합계
  from asap_lines(date '2026-07-01', date '2026-09-30')
 where excluded is null
 group by 1,2 order by 행 desc limit 20;
