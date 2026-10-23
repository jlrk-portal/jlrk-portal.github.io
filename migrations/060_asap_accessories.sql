-- ============================================================
--  Migration 060 — ASAP 는 '액세서리' 만 센다 (부품그룹)
--
--  059 로 FY27 Q2 를 돌렸더니 49,744행 · 2.8억이 나왔다. Q1 실파일은
--  1,528행이다. 32배 — 필터가 하나 빠진 것이다.
--
--  Turn Over 원본을 직접 세어 찾았다 (2026-09 기준):
--    청구계정 3종 + 차대번호 있음            16,959행
--    거기에 부품그룹 = 'Accessories'            616행   ← 이것
--  3개월 합: 2,166행 · 원가합계 613,532,937원. Q1 1,528행과 같은 자릿수다.
--
--  그 '부품그룹'(Turn Over 44번째 열)을 045 가 저장하지 않고 있었다.
--  열을 추가하고, 엔진에 대상 부품그룹 조건을 넣는다.
--
--  ⚠ 열을 채우려면 Turn Over 를 다시 올려야 한다. 한 번만 더.
--     이번엔 나중에 또 올리는 일이 없도록 쓸 만한 열을 같이 담는다.
-- ============================================================

alter table turnover_lines add column if not exists group_code text;  -- 그룹코드
alter table turnover_lines add column if not exists sale_no    text;  -- 부품판매번호
alter table turnover_lines add column if not exists part_group text;  -- 부품그룹 ★ Accessories
alter table turnover_lines add column if not exists part_class text;  -- 부품 클래스 코드
alter table turnover_lines add column if not exists recall_tc  text;  -- Recall/TC적용
alter table turnover_lines add column if not exists recall_no  text;  -- Recall/TC번호
alter table turnover_lines add column if not exists coupon_use text;  -- 쿠폰적용
alter table turnover_lines add column if not exists coupon_code text; -- 쿠폰코드
alter table turnover_lines add column if not exists odo        numeric; -- 주행거리
alter table turnover_lines add column if not exists out_date   date;    -- 차량출고일

create index if not exists turnover_group_idx on turnover_lines (part_group)
  where part_group is not null;

-- 대상 부품그룹을 설정으로 둔다 (이름이 바뀌어도 SQL 을 안 고치게)
insert into asap_config (k, v, note) values
  ('part_groups', '["Accessories"]'::jsonb,
   'ASAP 인센티브 대상 부품그룹. 비우면 부품그룹을 보지 않는다(= 전부).')
on conflict (k) do nothing;


-- ── 엔진에 부품그룹 조건 추가 ─────────────────────────────────
create or replace function asap_lines(
  p_from        date,
  p_to          date,
  p_showroom_list uuid default null
)
returns table (
  vin          text,
  inv_date     date,
  part_no      text,
  part_name    text,
  part_group   text,
  claim_acct   text,
  cost_sum     numeric,
  model_code   text,
  is_defender  boolean,
  rate         numeric,
  scope        text,
  branch       text,
  person       text,
  excluded     text
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
    (select v from asap_config where k = 'part_groups')         as groups,
    (select v from asap_config where k = 'rates')               as rates,
    (select v from asap_config where k = 'exclude_order_types') as ex_types,
    (select v from asap_config where k = 'dss_parts')           as dss
),
sales_win as (
  select distinct on (vin) vin, showroom, seller, retail_date
    from sales_report_lines
   where vin is not null
     and retail_date between (date_trunc('month', p_from) - interval '1 month')::date and p_to
   order by vin, retail_date desc
),
excl_win as (
  select distinct vin
    from sales_report_lines, cfg
   where vin is not null
     and retail_date between (p_to - interval '1 year')::date and p_to
     and order_type in (select jsonb_array_elements_text(cfg.ex_types))
),
showroom_vins as (
  select vin from campaign_vin_rows where p_showroom_list is not null and list_id = p_showroom_list
),
base as (
  select t.vin, t.inv_date, t.part_no, t.part_name, t.part_group, t.claim_acct,
         coalesce(t.cost_sum, 0) as cost_sum,
         coalesce(
           substring(coalesce(i.vehicle_line, i.model_code, '') from '(L[0-9]{3})'),
           substring(coalesce(t.model, t.series, '')            from '(L[0-9]{3})')
         ) as model_code,
         s.showroom, s.seller, t.workshop, t.sa,
         (s.vin is not null) as is_sales,
         (e.vin is not null) as is_excl_type,
         (v.vin is not null) as is_showroom
    from turnover_lines t
    cross join cfg
    left join iqm_vehicles  i on i.vin = t.vin
    left join sales_win     s on s.vin = t.vin
    left join excl_win      e on e.vin = t.vin
    left join showroom_vins v on v.vin = t.vin
   where t.inv_date between p_from and p_to
     and t.vin is not null
     and t.claim_acct in (select jsonb_array_elements_text(cfg.accounts))
     -- ★ 액세서리만. 설정이 비어 있으면 부품그룹을 보지 않는다.
     and (jsonb_array_length(cfg.groups) = 0
          or t.part_group in (select jsonb_array_elements_text(cfg.groups)))
)
select
  b.vin, b.inv_date, b.part_no, b.part_name, b.part_group, b.claim_acct, b.cost_sum,
  b.model_code,
  (b.model_code = 'L663') as is_defender,
  case when b.model_code = 'L663'
       then (select (rates->>'L663')::numeric    from cfg)
       else (select (rates->>'DEFAULT')::numeric from cfg) end as rate,
  case when b.is_sales then 'SALES' else 'SERVICE' end         as scope,
  case when b.is_sales then b.showroom else b.workshop end     as branch,
  case when b.is_sales then b.seller   else b.sa       end     as person,
  case
    when b.is_excl_type then '시승차·커티시카·특수차'
    when b.is_showroom  then '전시차'
    when b.model_code = 'L460' and substring(b.vin from 6 for 1) = 'B'
         and b.part_no in (select jsonb_array_elements_text(cfg.dss))
         then 'DSS 기본장착'
    else null
  end as excluded
  from base b cross join cfg
$$;

revoke all on function asap_lines(date, date, uuid) from public;
grant execute on function asap_lines(date, date, uuid) to authenticated;

-- 확인 — 열이 생겼는지 / 지금 몇 줄이 부품그룹을 갖고 있는지
select ym, count(*) as 행,
       count(*) filter (where part_group is not null)        as 부품그룹있음,
       count(*) filter (where part_group = 'Accessories')    as 액세서리
  from turnover_lines group by ym order by ym desc;
