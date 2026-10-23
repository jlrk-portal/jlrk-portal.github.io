-- ============================================================
--  Migration 064 — ASAP 인센티브를 '라인별로 보고' 검증한다
--
--  매니저 지시(2026-10-23):
--   "차대가 수십대여가지고 ... 엑셀로 넣어야하거든"
--   "전시차는 ... 지원금 받았던 분기 기준으로 ... 앞뒤 6개월 동안
--    검토필요라고 뜰수있게. 그리고 내가 정산제외 시킬수있게"
--   "프로모션도 ... 차대번호 + 지원일자 + 지원구분 ... 해당 차대에
--    액세서리가 있으면 내가 보고 정산제외할 품목들을 선택"
--   "내가 라인별로 보고 검토할수있게 포털에서 구성해달라고 한거야. 전부다."
--   "제외되는것들도 내가 어떤항목때문에 제외되는 지를 봐야한다고"
--
--  → 차대를 넣으면 자동으로 빼지 않는다. '검토 사유' 를 달아 보여주고,
--     빼는 것은 매니저가 라인 단위로 결정한다. 결정에는 사유가 남는다.
--
--  앞선 설계(asap_round_vins = 넣으면 자동 제외)는 버린다.
-- ============================================================

-- ── 지원 이력 (전시차 · 프로모션) — 엑셀로 올린다. 회차와 무관하게 쌓인다.
create table if not exists asap_support_vins (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('SHOWROOM','PROMO')),
  vin          text not null,
  period_label text,          -- 전시차: 지원받은 분기 'FY27 Q2'
  support_date date,          -- 프로모션: 지원일자
  support_type text,          -- 프로모션: 지원구분
  note         text,
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id) on delete set null
);
create unique index if not exists asap_support_vins_uniq on asap_support_vins
  (kind, vin, coalesce(period_label,''), coalesce(support_date, '1900-01-01'::date));
create index if not exists asap_support_vins_vin on asap_support_vins (vin);

alter table asap_support_vins enable row level security;
drop policy if exists asap_support_vins_admin on asap_support_vins;
create policy asap_support_vins_admin on asap_support_vins
  for all to authenticated using (is_admin()) with check (is_admin());

-- ── 라인별 결정 — 매니저가 뺀 것. 왜 뺐는지 남는다.
create table if not exists asap_line_decisions (
  round_id   uuid not null references rounds(id) on delete cascade,
  line_id    bigint not null,          -- turnover_lines.id
  decision   text not null default 'EXCLUDE' check (decision in ('EXCLUDE','KEEP')),
  reason     text,
  decided_at timestamptz not null default now(),
  decided_by uuid references auth.users(id) on delete set null,
  primary key (round_id, line_id)
);
alter table asap_line_decisions enable row level security;
drop policy if exists asap_line_dec_admin on asap_line_decisions;
create policy asap_line_dec_admin on asap_line_decisions
  for all to authenticated using (is_admin()) with check (is_admin());

-- 과다 인센티브 '검토 필요' 기준
insert into asap_config (k, v, note) values
  ('review_threshold', '{"multiple_of_median": 3, "min_amount": 2000000}'::jsonb,
   '한 사람 인센티브가 중앙값의 N배를 넘고 최소금액 이상이면 ''검토 필요''.'),
  ('showroom_months', '6'::jsonb,
   '전시차 지원 분기 앞뒤로 몇 달까지 검토 대상으로 볼지.')
on conflict (k) do nothing;


-- ── 'FY27 Q2' → 기간. JLR 회계연도는 4월 시작.
create or replace function asap_fy_range(p_label text)
returns table (d_from date, d_to date)
language sql immutable as $$
  with m as (
    select (regexp_match(coalesce(p_label,''), 'FY(\d{2})\s*Q([1-4])', 'i')) as g
  ), p as (
    select (g[1])::int as fy, (g[2])::int as q from m where g is not null
  )
  select make_date(case when q <= 3 then 2000 + fy - 1 else 2000 + fy end,
                   case when q <= 3 then 4 + (q-1)*3 else 1 end, 1) as d_from,
         (make_date(case when q <= 3 then 2000 + fy - 1 else 2000 + fy end,
                    case when q <= 3 then 4 + (q-1)*3 else 1 end, 1)
          + interval '3 months - 1 day')::date as d_to
    from p
$$;


-- ── 라인 산출 — 이제 '제외' 와 '검토 사유' 를 따로 돌려준다
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
  hard_excluded text,     -- 규칙상 무조건 빠지는 것 (시승차 등)
  flags         text[],   -- 검토 사유 — 빠지지는 않는다
  decision      text,     -- 매니저가 뺀 것 (EXCLUDE) / 살린 것 (KEEP)
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
-- 전시차: 지원 분기 앞뒤 N개월이 이 회차 기간과 겹치면 검토 대상
show_vin as (
  -- 손으로 올린 것 + 전시차 지원 프로그램 정산서 이력 (065). 함수가 없으면 앞엣것만.
  select vin from asap_showroom_window(p_from, p_to, (select sm from cfg))
),
promo_vin as (
  select vin, string_agg(distinct coalesce(support_type,'프로모션'), ', ') as kinds
    from asap_support_vins where kind = 'PROMO' group by vin
),
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
         (sv.vin is not null) as is_show,
         pv.kinds as promo_kinds
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
  -- 규칙상 무조건 빠지는 것 (매니저 판단이 필요 없다)
  case when b.is_excl_type then '시승차·커티시카·특수차' else null end as hard_excluded,
  -- 검토 사유 — 보여만 주고, 빼는 건 매니저가 정한다
  (select array_remove(array[
     case when b.is_show then '전시차 지원 (앞뒤 ' || (select sm from cfg) || '개월)' end,
     case when b.promo_kinds is not null then '프로모션 — ' || b.promo_kinds end,
     case when b.model_code = 'L460' and substring(b.vin from 6 for 1) = 'B'
          then 'DSS 기본장착 의심 (L460 · 차대 6번째 B)' end
   ], null)) as flags,
  d.decision, d.reason as decision_reason
  from base b
  cross join cfg
  left join asap_line_decisions d on d.round_id = p_round and d.line_id = b.line_id
$$;

revoke all on function asap_lines(date, date, uuid) from public;
grant execute on function asap_lines(date, date, uuid) to authenticated;


-- ── 라인을 한 번에 받기 위한 JSON 꾸러미
--  PostgREST 는 행을 1,000개까지만 준다. 한 분기가 2,000줄이 넘어서
--  행으로 받으면 잘린다. 한 덩어리 JSON 으로 돌려준다. (2026-10-23)
create or replace function asap_lines_json(
  p_from  date,
  p_to    date,
  p_round uuid default null
)
returns json
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  select coalesce(json_agg(x), '[]'::json) from asap_lines(p_from, p_to, p_round) x
$$;

revoke all on function asap_lines_json(date, date, uuid) from public;
grant execute on function asap_lines_json(date, date, uuid) to authenticated;

-- ── 집계 — 규칙 제외 + 매니저가 뺀 것은 빼고 센다
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
  flagged   bigint,
  amount    numeric
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with l as (
    select * from asap_lines(p_from, p_to, p_round)
     where hard_excluded is null and coalesce(decision,'') <> 'EXCLUDE'
  ),
  u as (select (v #>> '{}')::numeric as unit from asap_config where k = 'round_unit')
  select l.scope, l.branch, l.person,
         count(*) as lines, count(distinct l.vin) as vins, sum(l.cost_sum) as cost_sum,
         count(*) filter (where l.is_defender) as lines_df,
         coalesce(sum(l.cost_sum) filter (where l.is_defender), 0) as cost_df,
         count(*) filter (where not l.is_defender) as lines_etc,
         coalesce(sum(l.cost_sum) filter (where not l.is_defender), 0) as cost_etc,
         count(*) filter (where array_length(l.flags, 1) > 0) as flagged,
         ceil(sum(l.cost_sum * l.rate) / (select unit from u)) * (select unit from u) as amount
    from l
   group by l.scope, l.branch, l.person
   order by l.scope, l.branch, l.person
$$;

revoke all on function asap_summary(date, date, uuid) from public;
grant execute on function asap_summary(date, date, uuid) to authenticated;

-- 앞선 설계(넣으면 자동 제외)는 쓰지 않는다
drop table if exists asap_round_vins;

-- 확인
select 'asap_support_vins' as 항목,
       case when to_regclass('public.asap_support_vins') is not null then 'ok' else '없음' end as 상태
union all select 'asap_line_decisions',
       case when to_regclass('public.asap_line_decisions') is not null then 'ok' else '없음' end
union all select 'asap_fy_range(FY27 Q2)',
       (select d_from::text || ' ~ ' || d_to::text from asap_fy_range('FY27 Q2'))
union all select 'asap_round_vins (빠져야 함)',
       case when to_regclass('public.asap_round_vins') is null then 'ok' else '아직 있음' end;
