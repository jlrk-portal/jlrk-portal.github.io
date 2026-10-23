-- ============================================================
--  Migration 081 — 차량번호를 ASAP 까지 실어 보낸다
--
--  매니저 질문(2026-10-23): "차량번호가 있으면 넣도 좋겠고"
--  아까는 "어느 원천에도 없다" 고 답했는데 틀렸다. Turn Over 50번째 열이
--  '차량번호' 이고 값도 들어 있다 (Q1 원본 1,681행 중 893행 = 53%).
--  제가 적재 매핑에서 그 열을 빼먹고 있었다 — 080 에서 담기 시작한다.
--
--  ⚠ 이 번호가 채워지려면 Turn Over 를 다시 올려야 한다.
--    기존에 쌓인 3개월분에는 차량번호가 없다.
-- ============================================================

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
    vehicle_line, model_year, body_style, colour, car_no)
  select p_round, l.line_id,
         asap_branch_retailer(l.scope, l.branch),
         l.vin, l.inv_date, l.part_no, l.part_name, l.part_group,
         l.claim_acct, l.cost_sum, l.model_code, l.is_defender, l.rate,
         l.scope, l.branch, l.person, l.hard_excluded, l.flags, l.net_zero,
         t.brand, t.model, t.series,
         -- 고객명: 턴오버에 비면 Sales Report 로 채운다.
         -- 단, 설정에 적힌 청구계정(부품판매(개인) 등)은 고객명을 담지 않는다 —
         -- 카운터 부품판매라 '고객'이 직원인 경우가 있고, 정산 판단에 쓸 값이 아니다.
         case when t.claim_acct in (
                select jsonb_array_elements_text(
                  coalesce((select v from asap_config where k = 'hide_customer_accounts'),
                           '[]'::jsonb)))
              then null
              else nullif(coalesce(nullif(trim(t.customer),''),
                                   nullif(trim(sr.customer),''), ''), '-')
         end,
         sr.retail_date,
         to_json(t),
         -- 차종은 IQM 이 기준. 없으면 Sales Report, 그래도 없으면 턴오버.
         coalesce(i.vehicle_line, sr.model, t.model, t.series),
         coalesce(i.model_year, sr.model_year::text),
         i.body_style, i.colour, t.car_no
    from asap_lines(p_from, p_to, null) l
    join turnover_lines t on t.id = l.line_id
    left join iqm_vehicles i on i.vin = l.vin
    left join lateral (
      select sr2.retail_date, sr2.model, sr2.model_year, sr2.customer from sales_report_lines sr2
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
             s.vehicle_line, s.model_year, s.body_style, s.colour, s.car_no,
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
      vehicle_line text, model_year text, body_style text, colour text, car_no text)
  )
  select coalesce(json_agg(v order by v.amount desc), '[]'::json) from (
    select vin,
           min(scope) as scope, min(branch) as branch, min(person) as person,
           max(brand) as brand, max(model) as model, max(series) as series,
           max(vehicle_line) as vehicle_line, max(model_year) as model_year,
           max(car_no) as car_no,
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

-- 확인
select '턴오버 차량번호 있는 행' as 항목,
       (select count(*)::text from turnover_lines where coalesce(car_no,'') <> '') as 값
union all select '안내',
       'Turn Over 를 다시 올린 뒤 [원본 다시 읽기] 를 눌러야 채워집니다';
