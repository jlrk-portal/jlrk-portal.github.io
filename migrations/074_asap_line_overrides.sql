-- ============================================================
--  Migration 074 — 판매자 정정이 실제로 금액에 반영되게
--
--  매니저 지시(2026-10-23): "만약에 실제판매자가 다른 경우 실제 판매자를
--  입력할 수 있게 해줘야해. 예를 들어 서비스의 000직원이 판매자로
--  되어있는데 000전시장의 000일수도 있으니깐 이렇게 수정해서 나한테
--  재 청구할수있게 하던가"
--
--  리테일러 신청(asap_line_requests)을 매니저가 받아들이면 여기 한 줄이
--  쌓이고, asap_lines 가 그 줄의 구분·지점·담당자를 바꿔서 계산한다.
--  턴오버 원본은 건드리지 않는다 — 원본은 원본대로 남아야 한다.
-- ============================================================

create table if not exists asap_line_overrides (
  round_id    uuid not null references rounds(id) on delete cascade,
  line_id     bigint not null,
  new_scope   text check (new_scope in ('SALES','SERVICE')),
  new_branch  text,
  new_person  text,
  source_req  bigint references asap_line_requests(id) on delete set null,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  primary key (round_id, line_id)
);

alter table asap_line_overrides enable row level security;
drop policy if exists asap_line_ovr_admin on asap_line_overrides;
create policy asap_line_ovr_admin on asap_line_overrides
  for all to authenticated using (is_admin()) with check (is_admin());
-- 리테일러는 자기 라인에 걸린 정정 결과를 읽기만 한다 (asap_my_lines 로도 보인다)
drop policy if exists asap_line_ovr_read on asap_line_overrides;
create policy asap_line_ovr_read on asap_line_overrides
  for select to authenticated using (true);

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
    (select coalesce(v, '{}'::jsonb) from asap_config where k = 'base_fit_parts') as base_fit,
    (select coalesce((v #>> '{}')::int, 6) from asap_config where k = 'showroom_months') as sm
),
sales_win as (
  select distinct on (vin) vin, showroom, seller, retail_date
    from sales_report_lines
   where vin is not null
     and retail_date between (date_trunc('month', p_from) - interval '1 month')::date and p_to
   order by vin, retail_date desc
),
-- 어떤 유형이라 빠지는지 같이 들고 온다 (가장 최근 건 기준)
excl_win as (
  select distinct on (s.vin) s.vin, s.order_type
    from sales_report_lines s, cfg
   where s.vin is not null
     and s.retail_date between (p_to - interval '1 year')::date and p_to
     and upper(s.order_type) in
         (select upper(t2) from jsonb_array_elements_text(cfg.ex_types) t2)
   order by s.vin, s.retail_date desc
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
         e.order_type as excl_type,
         jsonb_exists(cfg.base_fit, t.part_no) as is_base_fit,
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
-- +/- 가 맞물려 서로 지워지는 '줄' 을 짝지어 찾는다.
-- 품번 단위 합계로 보면 안 된다 — 같은 품번이 +8,791 / +8,791 / -8,791
-- 처럼 세 줄이면 합이 0 이 아니라 아무것도 안 잡히고, 실제로는 한 쌍만
-- 상계되고 한 줄은 남는다. (매니저 지적 2026-10-23)
-- 같은 차대 · 같은 품번 · 같은 금액끼리 +와 -를 수만큼 짝지운다.
nz as (
  select line_id from (
    select b.line_id,
           row_number() over (partition by b.vin, b.part_no, abs(b.cost_sum), (b.cost_sum < 0)
                              order by b.inv_date, b.line_id) as rn,
           count(*) filter (where b.cost_sum < 0)
             over (partition by b.vin, b.part_no, abs(b.cost_sum)) as n_neg,
           count(*) filter (where b.cost_sum > 0)
             over (partition by b.vin, b.part_no, abs(b.cost_sum)) as n_pos
      from base b
     where b.cost_sum <> 0
  ) t
  where t.rn <= least(t.n_neg, t.n_pos)
)
select
  b.line_id, b.vin, b.inv_date, b.part_no, b.part_name, b.part_group, b.claim_acct, b.cost_sum,
  b.model_code,
  (b.model_code = 'L663') as is_defender,
  case when b.model_code = 'L663'
       then (select (rates->>'L663')::numeric    from cfg)
       else (select (rates->>'DEFAULT')::numeric from cfg) end as rate,
  -- 리테일러가 올린 '실제 판매자' 정정을 매니저가 받아들이면 여기서 바뀐다
  coalesce(o.new_scope,
           case when b.is_sales then 'SALES' else 'SERVICE' end)      as scope,
  coalesce(o.new_branch,
           case when b.is_sales then b.showroom else b.workshop end)  as branch,
  coalesce(o.new_person,
           case when b.is_sales then b.seller   else b.sa       end)  as person,
  case
    when b.is_base_fit then
      coalesce((select cfg2.base_fit ->> b.part_no from cfg cfg2), '기본장착')
      || ' 기본장착 품목 — 판매 전 차량에 기본 장착 (' || b.part_no || ')'
    when b.excl_type is not null then
      case upper(b.excl_type)
        when 'DM'   then '시승차 (Demonstrator · DM) — 이 차대는 시승차입니다'
        when 'DEMO' then '시승차 (Demonstrator · Demo) — 이 차대는 시승차입니다'
        when 'LC'   then '커티시카 (Loan Car · LC) — 이 차대는 커티시카입니다'
        when 'OUV'  then '업무용 차량 (Own Use Vehicle · OUV) — 리테일러 업무용입니다'
        when 'MC'   then '마케팅 차량 (Marketing Car · MC)'
        else '정산 대상이 아닌 차량 (' || b.excl_type || ')'
      end
  end as hard_excluded,
  (select array_remove(array[
     case when b.show_q is not null
          then '전시차 지원 — ' || b.show_q || ' (앞뒤 ' || (select sm from cfg) || '개월)' end,
     case when b.promo_kinds is not null
          then '프로모션 대상 차량 — ' || coalesce(b.promo_q || ' · ', '') || b.promo_kinds end,
     case when b.model_code = 'L460' and substring(b.vin from 6 for 1) = 'B'
               and coalesce(b.part_name, '') ilike '%step%'
          then 'DSS 기본장착 의심 (L460 · 차대 6번째 B · STEP 품목)' end
   ], null)) as flags,
  (z.line_id is not null) as net_zero,
  d.decision, d.reason as decision_reason
  from base b
  cross join cfg
  left join nz z on z.line_id = b.line_id
  left join asap_line_decisions d on d.round_id = p_round and d.line_id = b.line_id
  left join asap_line_overrides  o on o.round_id = p_round and o.line_id = b.line_id
$$;

revoke all on function asap_lines(date, date, uuid) from public;
grant execute on function asap_lines(date, date, uuid) to authenticated;

-- 확인
select 'asap_line_overrides' as 항목,
       case when to_regclass('public.asap_line_overrides') is not null then 'ok' else '없음' end as 값
union all select '지금 걸린 정정', (select count(*)::text from asap_line_overrides)
union all select '리테일러 신청 (대기)',
       (select count(*)::text from asap_line_requests where status = 'OPEN');
