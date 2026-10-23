-- ============================================================
--  Migration 058 — 겹치는 줄은 건너뛰고 넣을 수 있게
--
--  같은 정산라인이 여러 달 Turn Over 파일에 겹쳐 들어온다. 045 는
--  그걸 막으려고 유니크 인덱스를 걸었는데, 식(coalesce(...)) 으로 만든
--  인덱스라 포털에서 "겹치면 건너뛰기"(on conflict do nothing)를
--  지정할 수가 없다. 그래서 7월을 넣고 8월을 넣으면 겹치는 줄 하나에
--  묶음 전체가 터진다 —
--    duplicate key value violates unique constraint "turnover_lines_uniq"
--  (2026-10-23 실측: 7·8·9월 연속 적재가 여기서 죽었다)
--
--  ⚠ 처음에는 생성열(dedup_key)로 만들려 했으나
--      ERROR 42P17: generation expression is not immutable
--    로 거부당했다. date → text 변환이 DateStyle 에 걸려 immutable 이
--    아니기 때문이다. 그리고 생성열은 테이블을 통째로 다시 쓴다.
--    열을 그대로 쓰는 유니크 인덱스가 더 안전하고 빠르다.
--    NULL 끼리도 같은 값으로 보게 'nulls not distinct' 를 쓴다
--    (coalesce 를 쓰던 이유가 그것이다 — PostgreSQL 15 이상).
--
--  ⚠ 데이터는 한 줄도 안 지운다. 인덱스만 바꿔 낀다.
-- ============================================================

set statement_timeout = '30min';

do $$
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'PostgreSQL 15 이상이 필요합니다 (nulls not distinct). 현재 %',
      current_setting('server_version');
  end if;

  -- ── Turn Over : 045 의 식 인덱스와 같은 조합
  execute $x$
    create unique index if not exists turnover_lines_dedup on turnover_lines
      (stl_no, stl_line, part_no, claim_acct, inv_no, item_type) nulls not distinct
  $x$;

  -- ── Sales Report : 월 + 차대 + 리테일일자
  execute $x$
    create unique index if not exists sales_report_dedup on sales_report_lines
      (ym, vin, retail_date) nulls not distinct
  $x$;
end $$;

-- 새 인덱스가 선 뒤에 옛 식 인덱스를 뺀다 (같은 조합이라 중복은 새로 안 생긴다)
drop index if exists turnover_lines_uniq;
drop index if exists sales_report_uniq;

reset statement_timeout;

-- 확인 — 둘 다 ok 여야 한다
select 'turnover_lines_dedup' as 인덱스,
       case when to_regclass('public.turnover_lines_dedup') is not null then 'ok' else '없음' end as 상태
union all select 'sales_report_dedup',
       case when to_regclass('public.sales_report_dedup') is not null then 'ok' else '없음' end
union all select 'turnover_lines_uniq (빠져야 함)',
       case when to_regclass('public.turnover_lines_uniq') is null then 'ok' else '아직 있음' end
union all select 'sales_report_uniq (빠져야 함)',
       case when to_regclass('public.sales_report_uniq') is null then 'ok' else '아직 있음' end;
