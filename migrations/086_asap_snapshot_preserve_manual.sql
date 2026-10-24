-- ============================================================
--  Migration 086 — 재스냅샷이 '수동 추가 라인' 을 지우지 않게 (보존)
--
--  매니저 지시(2026-10-24): "이렇게 유형을 실수로 잘못마감하는 경우가 종종
--  있어서 보존로직을 만들어놓는게 좋을것같아."
--
--  asap_snapshot 은 [원본 읽어 회차에 담기] 때 회차 라인을 전부 지우고
--  턴오버에서 다시 만든다. 그러면 사람이 손으로 넣은 '누락분 반영' 라인
--  (line_id < 0, 턴오버에 없음)이 지워졌다. 이제 line_id >= 0 (턴오버에서
--  온 것) 만 지우고, 수동 라인은 그대로 둔다. 그 라인의 결정(승인/제외)도
--  line_id 로 묶여 있어 같이 보존된다.
--
--  함수 본문은 081 과 동일, delete 한 줄만 바뀜.
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

  -- ★ 수동 추가 라인(line_id < 0)은 지우지 않는다.
  --   누락분 반영 등 사람이 손으로 넣은 줄은 턴오버에 없어서, 원본을 다시 읽어도
  --   살아남아야 한다. 실수로 회차를 다시 마감/재적재해도 보존된다.
  --   (매니저 지시 2026-10-24: "유형을 실수로 잘못마감하는 경우가 종종 있어서")
  delete from asap_round_lines where round_id = p_round and line_id >= 0;

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
revoke all on function asap_snapshot(uuid, date, date) from public, anon;

-- 확인 — 음수 line_id(수동) 라인 수가 재적재 후에도 유지돼야 한다
select '수동 추가 라인(line_id<0)' as 항목, count(*)::text as 값
  from asap_round_lines where line_id < 0;
