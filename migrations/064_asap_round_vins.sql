-- ============================================================
--  Migration 064 — ASAP 인센티브를 포털 안에서 검증한다
--
--  매니저 지시(2026-10-23): "이건 검증이 아니잖아. 내가 포털 시스템 상에서
--  검증할수있게 만들어줘야 하고. 특히나 이슈가 있는 전시차, DSS, 프로모션
--  등을 여기서 내가 차대정보를 넣을 수 있도록 해야하고."
--
--  회차마다 빼야 할 차대를 종류별로 넣는다. 종류를 남겨야 '왜 빠졌는지' 가
--  엑셀과 화면에 그대로 보인다.
-- ============================================================

create table if not exists asap_round_vins (
  id         uuid primary key default gen_random_uuid(),
  round_id   uuid not null references rounds(id) on delete cascade,
  kind       text not null check (kind in ('SHOWROOM','DSS','PROMO')),
                       -- 전시차 · DSS 기본장착 · 프로모션
  vin        text not null,
  note       text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);
create unique index if not exists asap_round_vins_uniq
  on asap_round_vins (round_id, kind, vin);
create index if not exists asap_round_vins_vin on asap_round_vins (vin);

alter table asap_round_vins enable row level security;
drop policy if exists asap_round_vins_admin on asap_round_vins;
create policy asap_round_vins_admin on asap_round_vins
  for all to authenticated using (is_admin()) with check (is_admin());

-- 과다 인센티브 '검토 필요' 기준 — 화면에서 고칠 수 있게 설정으로 둔다
insert into asap_config (k, v, note) values
  ('review_threshold',
   '{"multiple_of_median": 3, "min_amount": 2000000}'::jsonb,
   '한 사람 인센티브가 중앙값의 N배를 넘고 최소금액 이상이면 ''검토 필요''. '
   '둘 다 만족해야 표시한다 — 작은 금액이 배수만 커서 걸리는 걸 막는다.')
on conflict (k) do nothing;


-- ── 엔진에 회차별 제외 차대를 반영 ─────────────────────────────
--  반환 열이 늘어나므로 먼저 내리고 다시 만든다 (42P13)
drop function if exists asap_lines(date, date, uuid);

create function asap_lines(
  p_from  date,
  p_to    date,
  p_round uuid default null      -- 이 회차에 등록된 제외 차대를 적용한다
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
-- 회차에 등록된 제외 차대 (전시차 · DSS · 프로모션)
round_vins as (
  select vin, kind from asap_round_vins where p_round is not null and round_id = p_round
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
         (select string_agg(distinct rv.kind, ',') from round_vins rv where rv.vin = t.vin) as rv_kind
    from turnover_lines t
    cross join cfg
    left join iqm_vehicles i on i.vin = t.vin
    left join sales_win    s on s.vin = t.vin
    left join excl_win     e on e.vin = t.vin
   where t.inv_date between p_from and p_to
     and t.vin is not null
     and t.claim_acct in (select jsonb_array_elements_text(cfg.accounts))
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
    when b.rv_kind like '%SHOWROOM%' then '전시차 (등록)'
    when b.rv_kind like '%PROMO%'    then '프로모션 (등록)'
    when b.rv_kind like '%DSS%'      then 'DSS (등록)'
    when b.is_excl_type then '시승차·커티시카·특수차'
    when b.model_code = 'L460' and substring(b.vin from 6 for 1) = 'B'
         and b.part_no in (select jsonb_array_elements_text(cfg.dss))
         then 'DSS 기본장착'
    else null
  end as excluded
  from base b cross join cfg
$$;

revoke all on function asap_lines(date, date, uuid) from public;
grant execute on function asap_lines(date, date, uuid) to authenticated;

-- ── 집계에 디펜더 구분을 더한다 ────────────────────────────────
--  매니저 지시(2026-10-23): 펼쳐본 화면에 디펜더 / 디펜더 외가 갈려 있어야 한다.
--  금액 올림은 사람 단위로 한 번만 한다 — 나눠서 올리면 합이 달라진다.
drop function if exists asap_summary(date, date, uuid);

create function asap_summary(
  p_from  date,
  p_to    date,
  p_round uuid default null
)
returns table (
  scope     text,
  branch    text,
  person    text,
  lines     bigint,
  vins      bigint,
  cost_sum  numeric,
  lines_df  bigint,
  cost_df   numeric,
  lines_etc bigint,
  cost_etc  numeric,
  amount    numeric
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with l as (
    select * from asap_lines(p_from, p_to, p_round) where excluded is null
  ),
  u as (select (v #>> '{}')::numeric as unit from asap_config where k = 'round_unit')
  select l.scope, l.branch, l.person,
         count(*)                                              as lines,
         count(distinct l.vin)                                 as vins,
         sum(l.cost_sum)                                       as cost_sum,
         count(*) filter (where l.is_defender)                 as lines_df,
         coalesce(sum(l.cost_sum) filter (where l.is_defender), 0)       as cost_df,
         count(*) filter (where not l.is_defender)             as lines_etc,
         coalesce(sum(l.cost_sum) filter (where not l.is_defender), 0)   as cost_etc,
         ceil(sum(l.cost_sum * l.rate) / (select unit from u)) * (select unit from u) as amount
    from l
   group by l.scope, l.branch, l.person
   order by l.scope, l.branch, l.person
$$;

revoke all on function asap_summary(date, date, uuid) from public;
grant execute on function asap_summary(date, date, uuid) to authenticated;

-- 확인
select 'asap_round_vins' as 표,
       case when to_regclass('public.asap_round_vins') is not null then 'ok' else '없음' end as 상태
union all select 'review_threshold',
       case when exists (select 1 from asap_config where k='review_threshold') then 'ok' else '없음' end
union all select 'asap_lines(p_round)',
       case when exists (select 1 from pg_proc where proname='asap_lines') then 'ok' else '없음' end;
