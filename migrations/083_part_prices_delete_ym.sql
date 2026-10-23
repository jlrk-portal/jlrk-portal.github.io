-- ============================================================
--  Migration 083 — 부품가격 마스터도 나눠서 지운다
--
--  무료 플랜 500MB 에서 part_prices 가 308MB 를 쓰고 있다 (1,317,494행).
--  한 달이 50만 행이라 한 번에 지우면 statement timeout 이 난다.
--  턴오버·Sales Report 와 같은 방식(057)으로 나눠 지운다.
--
--  ⚠ 함께 고친 것: 화면에서 part_prices 를 지우라고 하면
--    sales_report_delete_ym 이 불리고 있었다 (표 이름 분기가 2갈래뿐이었다).
--    엉뚱한 표가 지워질 수 있었다.
-- ============================================================

create or replace function part_prices_delete_ym(p_ym text, p_limit int default 20000)
returns int
language plpgsql
security definer
set search_path = public
set statement_timeout = '110s'
as $$
declare n int;
begin
  if not is_admin() then raise exception '권한이 없습니다'; end if;
  with doomed as (
    select ctid from part_prices where ym = p_ym limit p_limit
  )
  delete from part_prices p using doomed d where p.ctid = d.ctid;
  get diagnostics n = row_count;
  return n;
end
$$;

revoke all on function part_prices_delete_ym(text, int) from public;
grant execute on function part_prices_delete_ym(text, int) to authenticated;

-- 확인
select '부품가격 월별' as 항목, string_agg(ym || ' ' || parts::text, ' · ' order by ym desc) as 값
  from part_price_months;
