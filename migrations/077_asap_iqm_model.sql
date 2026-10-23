-- ============================================================
--  Migration 077 — 차종은 IQM 에서, 인보이스일·원가·요율을 차대 줄에
--
--  매니저 지적(2026-10-23): "모델명(차종)은 IQM에서 가져온게 아닌거 같은데?
--  다시 확인해보고, 인보이스 일도 하나의 필드로 넣는게 좋겠어. 차량번호가
--  있으면 넣도 좋겠고. 원가총액이 들어가는게 좋겠고 인센티브 옆에.
--  적용 인센티브 요율도 넣어야지 한번에 알아보기 쉽지"
--
--  맞습니다. 스냅샷은 turnover_lines 의 brand/model/series 를 담고 있었다.
--  모델은 IQM 이 기준이라고 해놓고(요율 판정은 IQM 을 쓰면서) 화면에 쓰는
--  차종만 턴오버 값을 쓰고 있었다. IQM 을 먼저 보고, 없을 때만 턴오버.
--
--  ※ 차량번호(번호판)는 지금 가진 어느 원천에도 없다 —
--    IQM · Turn Over · Sales Report 어디에도 열이 없어 담지 못했다.
-- ============================================================

alter table asap_round_lines add column if not exists vehicle_line text;  -- IQM 차종
alter table asap_round_lines add column if not exists model_year   text;
alter table asap_round_lines add column if not exists body_style   text;
alter table asap_round_lines add column if not exists colour       text;

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
    hard_excluded, flags, net_zero, brand, model, series, customer, retail_date, raw,
    vehicle_line, model_year, body_style, colour)
  select p_round, l.line_id,
         asap_branch_retailer(l.scope, l.branch),
         l.vin, l.inv_date, l.part_no, l.part_name, l.part_group,
         l.claim_acct, l.cost_sum, l.model_code, l.is_defender, l.rate,
         l.scope, l.branch, l.person, l.hard_excluded, l.flags, l.net_zero,
         t.brand, t.model, t.series, t.customer, sr.retail_date,
         to_json(t),
         -- 차종은 IQM 이 기준. 없으면 Sales Report, 그래도 없으면 턴오버.
         coalesce(i.vehicle_line, sr.model, t.model, t.series),
         coalesce(i.model_year, sr.model_year::text),
         i.body_style, i.colour
    from asap_lines(p_from, p_to, null) l
    join turnover_lines t on t.id = l.line_id
    left join iqm_vehicles i on i.vin = l.vin
    left join lateral (
      select sr2.retail_date, sr2.model, sr2.model_year from sales_report_lines sr2
       where sr2.vin = l.vin and sr2.retail_date <= p_to
       order by sr2.retail_date desc limit 1
    ) sr on true;

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


-- 저장된 라인에도 새 열을 실어 보낸다
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
             s.vehicle_line, s.model_year, s.body_style, s.colour,
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


-- 차대 줄 — 차종(IQM) · 인보이스완료일 · 원가총액 · 요율까지 한 줄에
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
      model_code text, inv_date date,
      vehicle_line text, model_year text, body_style text, colour text)
  )
  select coalesce(json_agg(v order by v.amount desc), '[]'::json) from (
    select vin,
           min(scope) as scope, min(branch) as branch, min(person) as person,
           max(brand) as brand, max(model) as model, max(series) as series,
           max(vehicle_line) as vehicle_line, max(model_year) as model_year,
           max(body_style) as body_style, max(colour) as colour,
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


-- 확인 — 이 회차를 다시 담아야 새 열이 채워진다
select '차종이 IQM 에서 온 라인' as 항목,
       (select count(*)::text from asap_round_lines s
         join iqm_vehicles i on i.vin = s.vin
        where s.vehicle_line = i.vehicle_line) as 값
union all select '차종이 비어 있는 라인',
       (select count(*)::text from asap_round_lines where vehicle_line is null)
union all select '안내',
       '[원본 다시 읽기] 를 한 번 눌러야 새 열이 채워집니다';
