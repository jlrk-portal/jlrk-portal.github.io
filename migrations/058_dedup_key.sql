-- ============================================================
--  Migration 058 — 겹치는 줄은 건너뛰고 넣을 수 있게 (dedup_key)
--
--  같은 정산라인이 여러 달 Turn Over 파일에 겹쳐 들어온다. 045 는
--  그걸 막으려고 유니크 인덱스를 걸었는데, 식(coalesce(...)) 으로 만든
--  인덱스라 포털에서 "겹치면 건너뛰기"(on conflict do nothing)를
--  지정할 수가 없다. 그래서 7월을 넣고 8월을 넣으면 겹치는 줄 하나에
--  묶음 전체가 터진다 —
--    duplicate key value violates unique constraint "turnover_lines_uniq"
--  (2026-10-23 실측: 7·8·9월 연속 적재가 여기서 죽었다)
--
--  같은 값을 '열 하나'로 만들어 두면 포털이 그 열을 집어 건너뛸 수 있다.
--
--  ⚠ 데이터는 안 지운다. 열 하나를 만들고 인덱스를 바꿔 끼운다.
--     행이 많으면 몇 분 걸릴 수 있다.
-- ============================================================

set statement_timeout = '30min';

-- ── Turn Over
alter table turnover_lines add column if not exists dedup_key text
  generated always as (
    coalesce(stl_no,'')     || '|' || coalesce(stl_line::text,'') || '|' ||
    coalesce(part_no,'')    || '|' || coalesce(claim_acct,'')     || '|' ||
    coalesce(inv_no,'')     || '|' || coalesce(item_type,'')
  ) stored;

create unique index if not exists turnover_lines_dedup on turnover_lines (dedup_key);
drop index if exists turnover_lines_uniq;       -- 같은 조합을 막던 옛 식 인덱스

-- ── Sales Report (적재 재시도 때 같은 문제가 난다)
alter table sales_report_lines add column if not exists dedup_key text
  generated always as (
    ym || '|' || coalesce(vin,'') || '|' || coalesce(retail_date::text,'')
  ) stored;

create unique index if not exists sales_report_dedup on sales_report_lines (dedup_key);
drop index if exists sales_report_uniq;

reset statement_timeout;

-- 확인
select 'turnover_lines.dedup_key' as 항목,
       case when exists (select 1 from information_schema.columns
             where table_name='turnover_lines' and column_name='dedup_key') then 'ok' else '없음' end as 상태
union all select 'sales_report_lines.dedup_key',
       case when exists (select 1 from information_schema.columns
             where table_name='sales_report_lines' and column_name='dedup_key') then 'ok' else '없음' end
union all select 'turnover_lines_dedup(index)',
       case when to_regclass('public.turnover_lines_dedup') is not null then 'ok' else '없음' end
union all select 'sales_report_dedup(index)',
       case when to_regclass('public.sales_report_dedup') is not null then 'ok' else '없음' end;
