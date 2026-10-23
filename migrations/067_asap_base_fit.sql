-- ============================================================
--  Migration 067 — 기본장착 품번 · 분기가 들어간 제외 사유 · 상계 라인
--
--  매니저 지시(2026-10-23)
--   "28VPLKV0134 Camera - Driver Aid System 이거는 판매되는 모든 차량
--    기본 장착되는 대쉬캠이야. 어떠한 경우에도 인센티브 대상에서 제외
--    되어야해. '기본장착'으로 구분해서 빼줘."
--   "제외사유도 명확하게 써줘. 00분기 전시차 청구건, 00분기 프로모션
--    청구건 이런식으로 나중에 리테일러에서 확인하기 쉽게"
--   "+ - 가 있어서 상계처리되서 0 되는 값은 결국 의미 없으니깐
--    흐릿하게 해서 라인 하단쪽으로 정렬하던가"
--   "tactical 오타 수정하고"
--
--  실측 (FY27 Q2): 대쉬캠 65줄 · 65대 · 원가 27,425,271 · 인센티브 2,695,963원.
--                  상계되어 0 이 되는 묶음 91개 · 218줄.
-- ============================================================

-- ── 1. 원본 오타. raw 는 열 순서를 지켜야 해서 jsonb 로 돌리지 않고
--       텍스트에서 바로 바꾼다.
update asap_promo_support set program2 = 'Tactical' where program2 = 'Tacitcal';
update asap_promo_support set raw = replace(raw::text, '"Tacitcal"', '"Tactical"')::json
 where raw::text like '%"Tacitcal"%';


-- ── 2. 전 차종 기본 장착 품번 — 어떤 경우에도 인센티브 대상이 아니다
insert into asap_config (k, v, note) values
  ('base_fit_parts', '["28VPLKV0134"]'::jsonb,
   '판매되는 모든 차량에 기본 장착되는 품목. 규칙상 무조건 제외한다. 28VPLKV0134 = 대쉬캠(Camera - Driver Aid System).')
on conflict (k) do update set v = excluded.v, note = excluded.note;

-- ── 3. 제외 사유 — 타이핑 대신 고르게 한다. {분기} 는 화면에서 채운다.
insert into asap_config (k, v, note) values
  ('exclude_reasons',
   '["기본장착 — 전 차종 기본 장착 품목",
     "{분기} 전시차 청구건",
     "{분기} 프로모션 청구건",
     "DSS 기본장착 차량",
     "사이드스텝 (PDI)",
     "시승차·커티시카·특수차",
     "중복 청구",
     "원가 오류"]'::jsonb,
   '라인 제외 사유 보기. 리테일러가 그대로 보므로 분기를 넣어 명확하게 쓴다.')
on conflict (k) do update set v = excluded.v, note = excluded.note;


-- ── 4. 'YYMM' → JLR 회계분기 ('2604' → 'FY27 Q1')
create or replace function asap_ym_fy(p_ym text)
returns text language sql immutable as $$
  select case when coalesce(p_ym,'') ~ '^\d{4}$' then
    'FY' || lpad((case when substring(p_ym,3,2)::int >= 4
                       then substring(p_ym,1,2)::int + 1
                       else substring(p_ym,1,2)::int end)::text, 2, '0')
    || ' Q' || (case when substring(p_ym,3,2)::int between 4  and 6  then 1
                     when substring(p_ym,3,2)::int between 7  and 9  then 2
                     when substring(p_ym,3,2)::int between 10 and 12 then 3
                     else 4 end)::text
  end
$$;


-- ── 5. 창(窓) 함수들이 '어느 분기 건인지' 를 같이 돌려준다
drop function if exists asap_showroom_window(date, date, int);
create function asap_showroom_window(p_from date, p_to date, p_months int)
returns table (vin text, quarters text)
language sql stable as $$
  with hits as (
    select s.vin, s.period_label as q
      from asap_support_vins s, lateral asap_fy_range(s.period_label) r
     where s.kind = 'SHOWROOM' and r.d_from is not null
       and (r.d_from - make_interval(months => p_months))::date <= p_to
       and (r.d_to   + make_interval(months => p_months))::date >= p_from
    union
    select h.vin, h.fy_label
      from asap_showroom_support h, lateral asap_fy_range(h.fy_label) r
     where r.d_from is not null
       and (r.d_from - make_interval(months => p_months))::date <= p_to
       and (r.d_to   + make_interval(months => p_months))::date >= p_from
  )
  select vin, string_agg(distinct q, ', ' order by q) from hits group by vin
$$;

drop function if exists asap_promo_window();
create function asap_promo_window()
returns table (vin text, kinds text, quarters text)
language sql stable as $$
  with hits as (
    select v.vin, coalesce(v.support_type, '프로모션') as kind, v.period_label as q
      from asap_support_vins v where v.kind = 'PROMO'
    union all
    select p.vin, coalesce(nullif(p.program2,''), p.program, '프로모션'), asap_ym_fy(p.month_ym)
      from asap_promo_support p
  )
  select vin,
         string_agg(distinct kind, ', ')            as kinds,
         string_agg(distinct q,    ', ' order by q) as quarters
    from hits group by vin
$$;


-- ── 6. 라인 산출 — 기본장착 제외 · 사유에 분기 표기 · 상계 라인 표시
drop function if exists asap_lines(date, date, uuid);

create function asap_lines(
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
          then '프로모션 — ' || coalesce(b.promo_q || ' · ', '') || b.promo_kinds end,
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


-- ── 확인
select '오타 남은 행' as 항목, (select count(*)::text from asap_promo_support
         where program2 = 'Tacitcal' or raw::text like '%Tacitcal%') as 값
union all select 'asap_ym_fy(2604)', asap_ym_fy('2604')
union all select 'asap_ym_fy(2601)', asap_ym_fy('2601')
union all select '기본장착 품번', (select v::text from asap_config where k = 'base_fit_parts')
union all select '제외 사유 개수', (select jsonb_array_length(v)::text from asap_config where k = 'exclude_reasons')
union all select 'FY27 Q2 기본장착 제외',
       (select count(*)::text from asap_lines('2026-07-01','2026-09-30')
         where hard_excluded like '기본장착%')
union all select 'FY27 Q2 상계(0원) 라인',
       (select count(*)::text from asap_lines('2026-07-01','2026-09-30') where net_zero);
