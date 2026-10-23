-- ============================================================
--  Migration 057 — 기준 데이터 월 삭제를 나눠서 (statement timeout)
--
--  Turn Over 를 다시 올릴 때 그 달을 먼저 지운다. 그런데 한 달이
--  10~14만 행이고 인덱스가 여섯 개라, 한 번에 지우면
--  'canceling statement due to statement timeout' 으로 죽는다.
--  (2026-10-23 실측 — 재적재가 아예 안 됐다)
--
--  한 번에 정해진 만큼만 지우고 몇 줄 지웠는지 돌려준다.
--  포털이 0 이 나올 때까지 돌리며 진행률을 보여준다.
-- ============================================================

create or replace function turnover_delete_ym(p_ym text, p_limit int default 20000)
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '110s'
as $$
declare n integer;
begin
  if not is_admin() then raise exception '관리자만 삭제할 수 있습니다.'; end if;
  if p_ym is null or p_ym !~ '^20\d{4}$' then raise exception '적재 월이 올바르지 않습니다: %', p_ym; end if;
  with doomed as (
    select id from turnover_lines where ym = p_ym limit greatest(p_limit, 1)
  )
  delete from turnover_lines t using doomed d where t.id = d.id;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function turnover_delete_ym(text, int) from public;
grant execute on function turnover_delete_ym(text, int) to authenticated;

create or replace function sales_report_delete_ym(p_ym text, p_limit int default 20000)
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '110s'
as $$
declare n integer;
begin
  if not is_admin() then raise exception '관리자만 삭제할 수 있습니다.'; end if;
  if p_ym is null or p_ym !~ '^20\d{4}$' then raise exception '적재 월이 올바르지 않습니다: %', p_ym; end if;
  with doomed as (
    select id from sales_report_lines where ym = p_ym limit greatest(p_limit, 1)
  )
  delete from sales_report_lines t using doomed d where t.id = d.id;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function sales_report_delete_ym(text, int) from public;
grant execute on function sales_report_delete_ym(text, int) to authenticated;

-- 월 삭제가 인덱스를 타도록 (045 의 turnover_ym_idx 가 있지만 명시해 둔다)
create index if not exists turnover_ym_id_idx on turnover_lines (ym, id);

-- 확인
select proname as 함수, pg_get_function_identity_arguments(oid) as 인자
  from pg_proc where proname in ('turnover_delete_ym','sales_report_delete_ym')
 order by proname;
