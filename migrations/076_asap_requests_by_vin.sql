-- ============================================================
--  Migration 076 — 신청도 '차대 단위'
--
--  매니저 지시(2026-10-23): "그리고 실제 판매자 수정 버튼도 차대기준이라고
--  차대." / "펼치기를 만들필요도 없어. 해당 차대에 들어간 총 금액 기준으로
--  인센티브 계산이 되니깐"
--
--  판매자가 바뀌면 그 차대에 붙은 라인이 전부 같이 옮겨가야 한다.
--  라인마다 신청을 올리면 매니저 화면이 같은 내용으로 도배된다.
--  신청은 차대 하나에 한 건, 받아들일 때 그 차대의 모든 라인에 펼친다.
-- ============================================================

alter table asap_line_requests add column if not exists vin text;
alter table asap_line_requests alter column line_id drop not null;

-- 예전에 올라온 라인 단위 신청에 차대를 채워 둔다
update asap_line_requests q
   set vin = t.vin
  from turnover_lines t
 where q.vin is null and t.id = q.line_id;

-- 차대 단위로 한 종류 한 건. 예전 라인 단위 인덱스는 걷어낸다.
drop index if exists asap_line_req_uniq;
create unique index if not exists asap_req_vin_uniq
  on asap_line_requests (round_id, vin, kind) where vin is not null;
create unique index if not exists asap_req_line_uniq
  on asap_line_requests (round_id, line_id, kind) where vin is null;

-- 관리자 뷰도 차대 기준으로 (라인이 없을 수 있다)
create or replace view asap_requests_admin as
  select q.*, r.code as retailer_code, r.name as retailer_name,
         coalesce(t.vin, q.vin)              as line_vin,
         s.brand, s.model, s.customer, s.retail_date,
         s.scope  as cur_scope,
         s.branch as cur_branch,
         s.person as cur_person,
         s.lines  as vin_lines,
         s.cost   as vin_cost
    from asap_line_requests q
    join retailers r on r.id = q.retailer_id
    left join turnover_lines t on t.id = q.line_id
    left join lateral (
      select min(x.scope) as scope, min(x.branch) as branch, min(x.person) as person,
             max(x.brand) as brand, max(x.model) as model, max(x.customer) as customer,
             max(x.retail_date) as retail_date,
             count(*) as lines, sum(x.cost_sum) as cost
        from asap_round_lines x
       where x.round_id = q.round_id and x.vin = coalesce(q.vin, t.vin)
    ) s on true;


-- ── 신청을 받아들이면 그 차대의 모든 라인에 정정을 건다
create or replace function asap_accept_request(p_req bigint)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare q asap_line_requests%rowtype; n int := 0;
begin
  if not is_admin() then raise exception '권한이 없습니다'; end if;
  select * into q from asap_line_requests where id = p_req;
  if not found then raise exception '신청을 찾을 수 없습니다'; end if;

  if q.kind = 'SELLER' then
    insert into asap_line_overrides (round_id, line_id, new_scope, new_branch, new_person,
                                     source_req, note, created_by)
    select q.round_id, s.line_id, q.new_scope, q.new_branch, q.new_person,
           q.id, q.reason, auth.uid()
      from asap_round_lines s
     where s.round_id = q.round_id
       and s.vin = coalesce(q.vin, (select vin from turnover_lines where id = q.line_id))
    on conflict (round_id, line_id) do update
      set new_scope = excluded.new_scope, new_branch = excluded.new_branch,
          new_person = excluded.new_person, source_req = excluded.source_req;
    get diagnostics n = row_count;
  else
    -- 이의신청을 받으면 그 차대에서 매니저가 뺀 것을 푼다 (규칙 제외는 그대로)
    delete from asap_line_decisions d
     using asap_round_lines s
     where d.round_id = q.round_id and d.line_id = s.line_id
       and s.round_id = q.round_id
       and s.vin = coalesce(q.vin, (select vin from turnover_lines where id = q.line_id))
       and d.decision = 'EXCLUDE';
    get diagnostics n = row_count;
  end if;

  update asap_line_requests
     set status = 'ACCEPTED', admin_note = null,
         resolved_at = now(), resolved_by = auth.uid()
   where id = p_req;
  return n;
end
$$;

revoke all on function asap_accept_request(bigint) from public;
grant execute on function asap_accept_request(bigint) to authenticated;


-- ── 되돌리기
create or replace function asap_undo_request(p_req bigint)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare q asap_line_requests%rowtype; n int := 0;
begin
  if not is_admin() then raise exception '권한이 없습니다'; end if;
  select * into q from asap_line_requests where id = p_req;
  if not found then raise exception '신청을 찾을 수 없습니다'; end if;

  delete from asap_line_overrides where source_req = q.id;
  get diagnostics n = row_count;

  update asap_line_requests
     set status = 'OPEN', admin_note = null, resolved_at = null, resolved_by = null
   where id = p_req;
  return n;
end
$$;

revoke all on function asap_undo_request(bigint) from public;
grant execute on function asap_undo_request(bigint) to authenticated;


-- 확인
select 'asap_line_requests.vin' as 항목,
       case when exists (select 1 from information_schema.columns
                          where table_name='asap_line_requests' and column_name='vin')
            then 'ok' else '없음' end as 값
union all select 'asap_accept_request / asap_undo_request',
       (select count(*)::text from pg_proc
         where proname in ('asap_accept_request','asap_undo_request'))
union all select '지금 신청', (select count(*)::text from asap_line_requests);
