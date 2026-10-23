-- ============================================================
--  Migration 079 — 부품판매(개인)은 고객명을 담지 않는다
--
--  매니저 지시(2026-10-23): "차라리 부품판매(개인)은 고객명을 제외하는
--  로직으로 설정해줘."
--
--  배경: 고객명에 'OOO (영업직원)' 처럼 직원 이름이 들어온 건이 있었다.
--  턴오버에는 고객명이 비어 있고 Sales Report 의 고객명 칸에서 온 값인데,
--  원본 파일에 그렇게 적혀 있다. 카운터 부품판매는 '고객'이 직원일 수 있고
--  정산 판단에 쓸 값이 아니므로 아예 담지 않는다.
--
--  어느 청구계정을 가릴지는 설정값으로 둔다 — 나중에 늘릴 수 있게.
-- ============================================================

insert into asap_config (k, v, note) values
  ('hide_customer_accounts', '["부품판매(개인)"]'::jsonb,
   '이 청구계정의 라인은 고객명을 담지 않는다. 카운터 부품판매라 고객명이 직원 이름인 경우가 있다.')
on conflict (k) do update set v = excluded.v, note = excluded.note;

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

-- 확인 — [원본 다시 읽기] 를 한 번 눌러야 반영된다
select '가릴 청구계정' as 항목,
       (select v::text from asap_config where k = 'hide_customer_accounts') as 값
union all select '지금 부품판매(개인) 라인 중 고객명이 남은 것',
       (select count(*)::text from asap_round_lines
         where claim_acct = '부품판매(개인)' and coalesce(customer,'') <> '')
union all select '안내', '[원본 다시 읽기] 를 눌러주세요';
