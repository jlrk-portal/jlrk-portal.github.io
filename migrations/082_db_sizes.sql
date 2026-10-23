-- ============================================================
--  Migration 082 — DB 용량을 포털에서 본다
--
--  매니저 설명(2026-10-23): "지금 내가 supabase 무료버전을 쓰고있어서
--  그래. ... 정산이 최종정리되면 포털에는 정말 최종정산된 회차의 구조랑
--  정산금액 숫자만 남겨두고 (이력관리 용도로) 나머지는 첨부파일이나
--  리테일러에서 올린 정산서 등 모든 걸 로컬폴더로 백업시키는게 최종 목표"
--
--  무료 플랜은 DB 500MB · Storage 1GB 다. 어디서 용량을 쓰는지 눈으로
--  봐야 정리할 수 있다. 지금은 추정치로만 보고 있어 정확하지 않다.
-- ============================================================

create or replace function db_sizes()
returns table (
  table_name  text,
  rows        bigint,
  total_bytes bigint,
  table_bytes bigint,
  index_bytes bigint,
  pretty      text
)
language sql
stable
security definer
set search_path = public
as $$
  select c.relname::text,
         c.reltuples::bigint,
         pg_total_relation_size(c.oid),
         pg_table_size(c.oid),
         pg_indexes_size(c.oid),
         pg_size_pretty(pg_total_relation_size(c.oid))
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and is_admin()
   order by pg_total_relation_size(c.oid) desc
$$;

revoke all on function db_sizes() from public;
grant execute on function db_sizes() to authenticated;

-- 전체 합계 (무료 플랜 500MB 대비)
create or replace function db_total_size()
returns table (bytes bigint, pretty text, pct_of_free numeric)
language sql
stable
security definer
set search_path = public
as $$
  select s, pg_size_pretty(s), round(s::numeric / (500 * 1024 * 1024) * 100, 1)
    from (select case when is_admin()
                      then coalesce(sum(pg_total_relation_size(c.oid)), 0)
                      else 0 end as s
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r') t
$$;

revoke all on function db_total_size() from public;
grant execute on function db_total_size() to authenticated;

-- 확인
select pretty as 전체용량, pct_of_free as "무료500MB 대비 %" from db_total_size();
