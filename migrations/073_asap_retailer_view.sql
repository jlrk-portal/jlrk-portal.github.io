-- ============================================================
--  Migration 073 — 리테일러가 자기 내역을 라인까지 보고, 고쳐서
--                   다시 올리고, 제외된 건에 이의신청할 수 있게
--
--  매니저 지시(2026-10-23):
--   "리테일러에서는 내가 계산한 내역을 하나씩 볼수있게, 지점별, 전시장,
--    서비스별, 직원별로 볼수있게 하고, 엑셀파일로 내려받아서 턴오버리포트
--    기준 필드는 당연히 들어가야하고 인센티브 계산된 금액을 확인할수
--    있어야하고, 만약에 실제판매자가 다른 경우 실제 판매자를 입력할 수
--    있게 해줘야해 ... 이렇게 수정해서 나한테 재 청구할수있게 하던가,
--    내가 제외시킨걸 사유를 적어서 이의신청을 할수있게도 해야해"
--
--  ⚠ 리테일러 격리는 화면이 아니라 DB 가 한다 (하우스룰).
--     asap_lines 는 security definer 라 그대로 열어주면 남의 지점까지
--     다 보인다. 리테일러용은 my_retailer() 로 잘라 주는 별도 함수를 쓴다.
-- ============================================================

-- ── 1. 지점/전시장 → 리테일러. 화면(JS)에만 있던 규칙을 DB 로 옮긴다.
--      SERVICE: 'OO 서비스센터' 에서 꼬리를 떼고 공백을 지워 workshops.name 과 맞춘다.
--               못 찾으면 branch_alias 로 한 번 더 (예: 부산센텀 → HS-BC).
--      SALES  : 전시장 코드가 리테일러 코드로 시작한다 (KCCB → KCC). 긴 코드 우선.
create or replace function asap_branch_retailer(p_scope text, p_branch text)
returns uuid
language sql stable
security definer
set search_path = public
as $$
  with k as (
    select replace(regexp_replace(coalesce(p_branch,''), '서비스센터\s*$', ''), ' ', '') as nm,
           upper(coalesce(p_branch,'')) as up
  ),
  alias as (
    select coalesce((select v from asap_config where k = 'branch_alias'), '{}'::jsonb) as m
  )
  select case when p_scope = 'SERVICE' then (
      select w.retailer_id from workshops w, k
       where w.is_active
         and (replace(w.name, ' ', '') = k.nm
              or replace(w.code, ' ', '') = (select m ->> k.nm from alias))
       limit 1)
    else (
      select r.id from retailers r, k
       where k.up like upper(r.code) || '%'
       order by length(r.code) desc
       limit 1)
  end
$$;

revoke all on function asap_branch_retailer(text, text) from public;
grant execute on function asap_branch_retailer(text, text) to authenticated;


-- ── 2. 리테일러용 라인 — 자기 것만. 턴오버 원본 열을 통째로 같이 준다.
create or replace function asap_my_lines(p_round uuid)
returns json
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with me as (select my_retailer() as rid),
  r as (
    select (source_summary ->> 'from')::date as d_from,
           (source_summary ->> 'to')::date   as d_to
      from rounds where id = p_round
  ),
  l as (
    select * from asap_lines((select d_from from r), (select d_to from r), p_round)
  )
  select coalesce(json_agg(x order by x.scope, x.branch, x.person, x.vin, x.part_no), '[]'::json)
    from (
      select l.*,
             t.ro_no, t.svc_type, t.in_date, t.ro_date, t.stl_no, t.stl_line,
             t.claim_type, t.inv_no, t.inv_status, t.item_type,
             t.qty, t.retail, t.retail_sum, t.sale_sum, t.split, t.disc_code,
             t.cost, t.reg_date, t.brand, t.model, t.series,
             t.dealer, t.workshop, t.sa, t.tech, t.customer, t.ym,
             round(l.cost_sum * l.rate) as incentive
        from l
        join turnover_lines t on t.id = l.line_id
       where (select rid from me) is not null
         and asap_branch_retailer(l.scope, l.branch) = (select rid from me)
    ) x
$$;

revoke all on function asap_my_lines(uuid) from public;
grant execute on function asap_my_lines(uuid) to authenticated;


-- ── 3. 리테일러가 올리는 수정/이의 신청
create table if not exists asap_line_requests (
  id          bigserial primary key,
  round_id    uuid not null references rounds(id) on delete cascade,
  line_id     bigint not null,                 -- turnover_lines.id
  retailer_id uuid not null references retailers(id) on delete cascade,
  kind        text not null check (kind in ('SELLER','APPEAL')),
  --  SELLER : 실제 판매자가 다르다 (전시장/담당자를 바로잡아 재청구)
  --  APPEAL : 제외된 건에 대한 이의신청
  new_scope   text check (new_scope in ('SALES','SERVICE')),
  new_branch  text,
  new_person  text,
  reason      text,
  status      text not null default 'OPEN' check (status in ('OPEN','ACCEPTED','REJECTED')),
  admin_note  text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null
);

-- 한 회차의 한 라인에 대해 한 종류는 한 번만 (다시 올리면 덮어쓴다)
create unique index if not exists asap_line_req_uniq
  on asap_line_requests (round_id, line_id, kind);
create index if not exists asap_line_req_round on asap_line_requests (round_id, status);
create index if not exists asap_line_req_rt    on asap_line_requests (retailer_id);

alter table asap_line_requests enable row level security;

drop policy if exists asap_line_req_admin on asap_line_requests;
create policy asap_line_req_admin on asap_line_requests
  for all to authenticated using (is_admin()) with check (is_admin());

-- 리테일러는 자기 것만 보고, 자기 것만 올린다. 처리된 건은 못 고친다.
drop policy if exists asap_line_req_rt_read on asap_line_requests;
create policy asap_line_req_rt_read on asap_line_requests
  for select to authenticated using (retailer_id = my_retailer());

drop policy if exists asap_line_req_rt_write on asap_line_requests;
create policy asap_line_req_rt_write on asap_line_requests
  for insert to authenticated with check (retailer_id = my_retailer());

drop policy if exists asap_line_req_rt_update on asap_line_requests;
create policy asap_line_req_rt_update on asap_line_requests
  for update to authenticated
  using (retailer_id = my_retailer() and status = 'OPEN')
  with check (retailer_id = my_retailer() and status = 'OPEN');

drop policy if exists asap_line_req_rt_del on asap_line_requests;
create policy asap_line_req_rt_del on asap_line_requests
  for delete to authenticated
  using (retailer_id = my_retailer() and status = 'OPEN');


-- ── 4. 관리자용 — 들어온 신청을 라인 정보와 같이 본다
create or replace view asap_requests_admin as
  select q.*, r.code as retailer_code, r.name as retailer_name,
         t.vin, t.part_no, t.part_name, t.inv_date, t.cost_sum,
         t.workshop, t.sa
    from asap_line_requests q
    join retailers r on r.id = q.retailer_id
    left join turnover_lines t on t.id = q.line_id;


-- 확인
select 'asap_line_requests' as 항목,
       case when to_regclass('public.asap_line_requests') is not null then 'ok' else '없음' end as 상태
union all select 'asap_branch_retailer(SALES, KCCB)',
       coalesce((select code from retailers
                  where id = asap_branch_retailer('SALES','KCCB')), '못 찾음')
union all select 'asap_branch_retailer(SERVICE, 성남 서비스센터)',
       coalesce((select code from retailers
                  where id = asap_branch_retailer('SERVICE','성남 서비스센터')), '못 찾음')
union all select 'asap_my_lines (관리자 호출이면 0)',
       (select json_array_length(asap_my_lines(
          (select id from rounds order by created_at desc limit 1)))::text);
