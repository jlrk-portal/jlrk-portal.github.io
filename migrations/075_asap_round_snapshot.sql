-- ============================================================
--  Migration 075 — 회차에 라인을 저장한다 (매번 턴오버를 다시 돌지 않는다)
--                   + 인센티브는 '차대 단위' 만원 올림
--
--  매니저 지적(2026-10-23)
--   "왜 내 화면에서는 Turn over를 다시 돌려야하는데? ... 회차를 생성하고
--    딱 한번만 내가 설정한 기간기준으로 턴오버 데이터 값만 설정한 로직에
--    따라서 불러오면 된다고 ... 한번 불러오면 그다음부터 턴오버리포트
--    파일자체를 수정하지않는 이상 불러올 필요가 없어."
--   "리테일러에서 ASAP 내역 불러오는데 왜이렇게 시간이 많이걸려?"
--   "한 차대 기준으로 원가 합계의 인센티브 요율을 곱한 금액에 만원단위
--    올림으로 인센티브 지급이야. 지금은 만원단위 인센티브 계산도 안되고
--    있어."
--
--  지금 구조: 화면을 열 때마다 asap_lines() 가 턴오버 전체를 훑는다.
--             관리자는 [계산하기] 를 또 눌러야 하고 리테일러는 한참 기다린다.
--  바꾼 구조: 회차를 만들 때 한 번 계산해 asap_round_lines 에 저장.
--             그 뒤로는 저장된 것만 읽는다. 제외/승인/판매자 정정은 저장된
--             라인 위에 얹히므로 다시 돌 필요가 없다.
--
--  올림 단위도 고친다. 담당자 단위로 올리고 있었는데 차대 단위가 맞다.
-- ============================================================

create table if not exists asap_round_lines (
  round_id     uuid   not null references rounds(id) on delete cascade,
  line_id      bigint not null,
  retailer_id  uuid references retailers(id) on delete set null,  -- 스냅샷 시점 귀속 (RLS 기준)

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
  hard_excluded text,
  flags        text[],
  net_zero     boolean,

  -- 차대를 알아볼 수 있는 것들 (화면은 이것만 쓴다)
  brand        text,
  model        text,
  series       text,
  customer     text,
  retail_date  date,          -- 판매일 (Sales Report)
  raw          json,          -- 턴오버 원본 행 전체 — 엑셀용

  primary key (round_id, line_id)
);

create index if not exists asap_round_lines_rt  on asap_round_lines (round_id, retailer_id);
create index if not exists asap_round_lines_vin on asap_round_lines (round_id, vin);

alter table asap_round_lines enable row level security;
drop policy if exists asap_round_lines_admin on asap_round_lines;
create policy asap_round_lines_admin on asap_round_lines
  for all to authenticated using (is_admin()) with check (is_admin());
-- 리테일러는 자기 것만. 화면이 아니라 여기서 막는다.
drop policy if exists asap_round_lines_rt on asap_round_lines;
create policy asap_round_lines_rt on asap_round_lines
  for select to authenticated using (retailer_id = my_retailer());


-- ── 회차에 한 번 담는다. 다시 부르면 그 회차만 갈아끼운다.
create or replace function asap_snapshot(p_round uuid, p_from date, p_to date)
returns int
language plpgsql
security definer
set search_path = public
set statement_timeout = '170s'
as $$
declare n int;
begin
  if not is_admin() then raise exception '권한이 없습니다'; end if;

  delete from asap_round_lines where round_id = p_round;

  insert into asap_round_lines (
    round_id, line_id, retailer_id, vin, inv_date, part_no, part_name, part_group,
    claim_acct, cost_sum, model_code, is_defender, rate, scope, branch, person,
    hard_excluded, flags, net_zero, brand, model, series, customer, retail_date, raw)
  select p_round, l.line_id,
         asap_branch_retailer(l.scope, l.branch),
         l.vin, l.inv_date, l.part_no, l.part_name, l.part_group,
         l.claim_acct, l.cost_sum, l.model_code, l.is_defender, l.rate,
         l.scope, l.branch, l.person, l.hard_excluded, l.flags, l.net_zero,
         t.brand, t.model, t.series, t.customer, s.retail_date,
         to_json(t)
    from asap_lines(p_from, p_to, null) l
    join turnover_lines t on t.id = l.line_id
    left join lateral (
      select sr.retail_date from sales_report_lines sr
       where sr.vin = l.vin and sr.retail_date <= p_to
       order by sr.retail_date desc limit 1
    ) s on true;

  get diagnostics n = row_count;

  update rounds
     set source_summary = coalesce(source_summary, '{}'::jsonb)
         || jsonb_build_object('snapshot_at', now(), 'snapshot_rows', n,
                               'from', p_from::text, 'to', p_to::text)
   where id = p_round;
  return n;
end
$$;

revoke all on function asap_snapshot(uuid, date, date) from public;
grant execute on function asap_snapshot(uuid, date, date) to authenticated;


-- ── 저장된 라인 + 그 뒤에 쌓인 결정/정정을 합쳐서 돌려준다.
--    턴오버는 더 이상 보지 않는다. 관리자·리테일러 둘 다 이걸 쓴다.
create or replace function asap_saved_lines(p_round uuid)
returns json
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with me as (select my_retailer() as rid, is_admin() as adm)
  select coalesce(json_agg(x order by x.scope, x.branch, x.person, x.vin, x.part_no), '[]'::json)
    from (
      select s.line_id, s.vin, s.inv_date, s.part_no, s.part_name, s.part_group,
             s.claim_acct, s.cost_sum, s.model_code, s.is_defender, s.rate,
             coalesce(o.new_scope,  s.scope)  as scope,
             coalesce(o.new_branch, s.branch) as branch,
             coalesce(o.new_person, s.person) as person,
             s.hard_excluded, s.flags, s.net_zero,
             s.brand, s.model, s.series, s.customer, s.retail_date, s.raw,
             s.retailer_id,
             d.decision, d.reason as decision_reason,
             (o.line_id is not null) as seller_fixed
        from asap_round_lines s
        left join asap_line_decisions d on d.round_id = s.round_id and d.line_id = s.line_id
        left join asap_line_overrides  o on o.round_id = s.round_id and o.line_id = s.line_id
        cross join me
       where s.round_id = p_round
         and (me.adm or s.retailer_id = me.rid)
    ) x
$$;

revoke all on function asap_saved_lines(uuid) from public;
grant execute on function asap_saved_lines(uuid) to authenticated;


-- ── 집계 — 인센티브는 '차대 단위' 로 올린다 (매니저 기준)
--    차대 하나의 원가합계 × 요율 → 만원 올림. 사람 단위로 올리던 것이 틀렸다.
create or replace function asap_saved_summary(p_round uuid)
returns table (
  scope text, branch text, person text,
  lines bigint, vins bigint, cost_sum numeric,
  lines_df bigint, cost_df numeric, lines_etc bigint, cost_etc numeric,
  flagged bigint, amount numeric
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with u as (select coalesce((v #>> '{}')::numeric, 10000) as unit
               from asap_config where k = 'round_unit'),
  l as (
    select * from json_to_recordset(asap_saved_lines(p_round)) as t(
      line_id bigint, vin text, cost_sum numeric, rate numeric, is_defender boolean,
      scope text, branch text, person text, hard_excluded text, flags text[],
      decision text)
     where hard_excluded is null and coalesce(decision,'') <> 'EXCLUDE'
  ),
  per_vin as (
    select scope, branch, person, vin,
           count(*) as lines, sum(cost_sum) as cost_sum,
           count(*) filter (where coalesce(is_defender,false)) as lines_df,
           coalesce(sum(cost_sum) filter (where coalesce(is_defender,false)),0) as cost_df,
           count(*) filter (where not coalesce(is_defender,false)) as lines_etc,
           coalesce(sum(cost_sum) filter (where not coalesce(is_defender,false)),0) as cost_etc,
           count(*) filter (where array_length(flags,1) > 0) as flagged,
           -- ★ 차대 하나가 올림의 단위다
           ceil(sum(cost_sum * rate) / (select unit from u)) * (select unit from u) as amount
      from l group by scope, branch, person, vin
  )
  select scope, branch, person,
         sum(lines)::bigint, count(*)::bigint, sum(cost_sum),
         sum(lines_df)::bigint, sum(cost_df), sum(lines_etc)::bigint, sum(cost_etc),
         sum(flagged)::bigint, sum(amount)
    from per_vin
   group by scope, branch, person
   order by scope, branch, person
$$;

revoke all on function asap_saved_summary(uuid) from public;
grant execute on function asap_saved_summary(uuid) to authenticated;


-- ── 차대 단위 보기 — 포털 화면은 이것만 쓴다 (품번·라인은 엑셀에만)
create or replace function asap_saved_vins(p_round uuid)
returns json
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with u as (select coalesce((v #>> '{}')::numeric, 10000) as unit
               from asap_config where k = 'round_unit'),
  l as (
    select * from json_to_recordset(asap_saved_lines(p_round)) as t(
      line_id bigint, vin text, cost_sum numeric, rate numeric,
      scope text, branch text, person text, hard_excluded text, flags text[],
      decision text, decision_reason text, net_zero boolean, seller_fixed boolean,
      brand text, model text, series text, customer text, retail_date date,
      model_code text, inv_date date)
  )
  select coalesce(json_agg(v order by v.amount desc), '[]'::json) from (
    select vin,
           min(scope) as scope, min(branch) as branch, min(person) as person,
           max(brand) as brand, max(model) as model, max(series) as series,
           max(customer) as customer, max(retail_date) as retail_date,
           max(model_code) as model_code, max(rate) as rate,
           min(inv_date) as first_inv, max(inv_date) as last_inv,
           count(*) as lines,
           count(*) filter (where hard_excluded is not null
                               or coalesce(decision,'') = 'EXCLUDE') as out_lines,
           coalesce(sum(cost_sum) filter (where hard_excluded is null
                      and coalesce(decision,'') <> 'EXCLUDE'), 0) as cost_sum,
           ceil(coalesce(sum(cost_sum * rate) filter (where hard_excluded is null
                      and coalesce(decision,'') <> 'EXCLUDE'), 0)
                / (select unit from u)) * (select unit from u) as amount,
           bool_or(seller_fixed) as seller_fixed,
           (select string_agg(distinct f, ' · ')
              from l l2, unnest(l2.flags) f where l2.vin = l.vin) as flags,
           (select string_agg(distinct coalesce(l3.hard_excluded, l3.decision_reason), ' · ')
              from l l3 where l3.vin = l.vin
               and (l3.hard_excluded is not null or coalesce(l3.decision,'') = 'EXCLUDE')) as out_why
      from l
     group by vin
  ) v
$$;

revoke all on function asap_saved_vins(uuid) from public;
grant execute on function asap_saved_vins(uuid) to authenticated;


-- 확인
select 'asap_round_lines' as 항목,
       case when to_regclass('public.asap_round_lines') is not null then 'ok' else '없음' end as 값
union all select 'asap_snapshot / asap_saved_lines / asap_saved_summary / asap_saved_vins',
       (select count(*)::text from pg_proc
         where proname in ('asap_snapshot','asap_saved_lines','asap_saved_summary','asap_saved_vins'))
union all select '지금 저장된 회차',
       (select coalesce(count(distinct round_id)::text,'0') from asap_round_lines);
