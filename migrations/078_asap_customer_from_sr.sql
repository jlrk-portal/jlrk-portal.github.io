-- ============================================================
--  Migration 078 — 고객명을 Sales Report 로 채운다
--
--  077 로 차종은 IQM 에서 제대로 가져왔는데, 고객명이 555대 중 186대가
--  비어 있었다. 턴오버의 고객명 칸이 비는 경우가 많아서다.
--  Sales Report 에 같은 차대의 고객명이 있으면 그걸 쓴다.
--  ('-' 로 들어온 값은 빈 값으로 본다.)
--
--  ※ 판매일이 없는 296대는 메울 데가 없다 — 적재된 Sales Report 기간
--    밖에서 팔린 차들이라 원천 자체에 기록이 없다.
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
    vehicle_line, model_year, body_style, colour)
  select p_round, l.line_id,
         asap_branch_retailer(l.scope, l.branch),
         l.vin, l.inv_date, l.part_no, l.part_name, l.part_group,
         l.claim_acct, l.cost_sum, l.model_code, l.is_defender, l.rate,
         l.scope, l.branch, l.person, l.hard_excluded, l.flags, l.net_zero,
         t.brand, t.model, t.series,
         -- 고객명은 턴오버에 비어 있는 경우가 많다. Sales Report 로 채운다.
         nullif(coalesce(nullif(trim(t.customer),''), nullif(trim(sr.customer),''), ''), '-'),
         sr.retail_date,
         to_json(t),
         -- 차종은 IQM 이 기준. 없으면 Sales Report, 그래도 없으면 턴오버.
         coalesce(i.vehicle_line, sr.model, t.model, t.series),
         coalesce(i.model_year, sr.model_year::text),
         i.body_style, i.colour
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

-- 확인 — [원본 다시 읽기] 를 한 번 더 눌러야 채워진다
select '안내' as 항목, '[원본 다시 읽기] 를 한 번 눌러주세요' as 값
union all select '지금 고객명 없는 차대',
       (select count(distinct vin)::text from asap_round_lines
         where round_id in (select id from rounds) and coalesce(customer,'') = '');
