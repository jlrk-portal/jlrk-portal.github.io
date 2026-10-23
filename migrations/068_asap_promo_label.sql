-- ============================================================
--  Migration 068 — '프로모션' 이 아니라 '프로모션 대상 차량'
--
--  매니저 지시(2026-10-23): "프로모션이 아니라 '프로모션 대상 차량' 인거지."
--  그 차대가 프로모션으로 액세서리를 받은 차라는 뜻이지, 이 라인이
--  프로모션이라는 뜻이 아니다. 사유 문구만 바꾼다 — 산출 로직은 그대로.
--
--  제외 사유 보기도 같이 손본다.
-- ============================================================

update asap_config
   set v = '["기본장착 — 전 차종 기본 장착 품목",
             "{분기} 전시차 청구건",
             "{분기} 프로모션 대상 차량",
             "DSS 기본장착 차량",
             "사이드스텝 (PDI)",
             "시승차·커티시카·특수차",
             "중복 청구",
             "원가 오류"]'::jsonb
 where k = 'exclude_reasons';

create or replace function asap_lines(
  p_from  date,
  p_to    date,
  p_round uuid default null
)
returns table (
  line_id      bigint,
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
  hard_excluded text,    -- 규칙상 무조건 빠지는 것 (시승차 · 기본장착)
  flags         text[],  -- 검토 사유 — 빠지지는 않는다
  net_zero      boolean, -- 같은 차대·품번에서 +/- 가 상계되어 합이 0
  decision      text,
  decision_reason text
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
    (select coalesce(v, '[]'::jsonb) from asap_config where k = 'base_fit_parts') as base_fit,
    (select coalesce((v #>> '{}')::int, 6) from asap_config where k = 'showroom_months') as sm
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
show_vin  as (select vin, quarters from asap_showroom_window(p_from, p_to, (select sm from cfg))),
promo_vin as (select vin, kinds, quarters from asap_promo_window()),
base as (
  select t.id as line_id, t.vin, t.inv_date, t.part_no, t.part_name, t.part_group, t.claim_acct,
         coalesce(t.cost_sum, 0) as cost_sum,
         coalesce(
           substring(coalesce(i.vehicle_line, i.model_code, '') from '(L[0-9]{3})'),
           substring(coalesce(t.model, t.series, '')            from '(L[0-9]{3})')
         ) as model_code,
         s.showroom, s.seller, t.workshop, t.sa,
         (s.vin is not null) as is_sales,
         (e.vin is not null) as is_excl_type,
         (t.part_no in (select jsonb_array_elements_text(cfg.base_fit))) as is_base_fit,
         sv.quarters as show_q,
         pv.kinds    as promo_kinds,
         pv.quarters as promo_q
    from turnover_lines t
    cross join cfg
    left join iqm_vehicles i on i.vin = t.vin
    left join sales_win    s on s.vin = t.vin
    left join excl_win     e on e.vin = t.vin
    left join show_vin     sv on sv.vin = t.vin
    left join promo_vin    pv on pv.vin = t.vin
   where t.inv_date between p_from and p_to
     and t.vin is not null
     and t.claim_acct in (select jsonb_array_elements_text(cfg.accounts))
     and (jsonb_array_length(cfg.groups) = 0
          or t.part_group in (select jsonb_array_elements_text(cfg.groups)))
),
-- 같은 차대·같은 품번에서 +/- 가 맞물려 합이 0 이 되는 묶음.
-- 빼지는 않는다 — 봐야 할 게 아니라는 표시만 한다.
nz as (
  select vin, part_no from base
   group by vin, part_no
  having count(*) > 1 and abs(sum(cost_sum)) < 1
)
select
  b.line_id, b.vin, b.inv_date, b.part_no, b.part_name, b.part_group, b.claim_acct, b.cost_sum,
  b.model_code,
  (b.model_code = 'L663') as is_defender,
  case when b.model_code = 'L663'
       then (select (rates->>'L663')::numeric    from cfg)
       else (select (rates->>'DEFAULT')::numeric from cfg) end as rate,
  case when b.is_sales then 'SALES' else 'SERVICE' end         as scope,
  case when b.is_sales then b.showroom else b.workshop end     as branch,
  case when b.is_sales then b.seller   else b.sa       end     as person,
  case when b.is_base_fit  then '기본장착 — 전 차종 기본 장착 품목'
       when b.is_excl_type then '시승차·커티시카·특수차' end   as hard_excluded,
  (select array_remove(array[
     case when b.show_q is not null
          then '전시차 지원 — ' || b.show_q || ' (앞뒤 ' || (select sm from cfg) || '개월)' end,
     case when b.promo_kinds is not null
          then '프로모션 대상 차량 — ' || coalesce(b.promo_q || ' · ', '') || b.promo_kinds end,
     case when b.model_code = 'L460' and substring(b.vin from 6 for 1) = 'B'
          then 'DSS 기본장착 의심 (L460 · 차대 6번째 B)' end
   ], null)) as flags,
  (z.vin is not null) as net_zero,
  d.decision, d.reason as decision_reason
  from base b
  cross join cfg
  left join nz z on z.vin = b.vin and z.part_no = b.part_no
  left join asap_line_decisions d on d.round_id = p_round and d.line_id = b.line_id
$$;

revoke all on function asap_lines(date, date, uuid) from public;
grant execute on function asap_lines(date, date, uuid) to authenticated;

-- 확인
select '프로모션 대상 차량 라인' as 항목,
       (select count(*)::text from asap_lines('2026-07-01','2026-09-30')
         where exists (select 1 from unnest(flags) f where f like '프로모션 대상 차량%')) as 값
union all select '제외 사유', (select v::text from asap_config where k='exclude_reasons');
