-- ============================================================
--  Migration 070 — 모델을 모르는 라인이 Defender / 그 외 어디에도
--                   안 잡히던 것
--
--  2단계 금액을 라인에서 바로 다시 세는 기능을 붙이면서 SQL 집계와
--  한 줄씩 대조하다 찾았다.
--
--  asap_summary 는
--      count(*) filter (where l.is_defender)        -- Defender
--      count(*) filter (where not l.is_defender)    -- 그 외
--  로 나눈다. is_defender 는 (model_code = 'L663') 인데, IQM 에도
--  Turn Over 에도 모델이 없으면 model_code 가 NULL 이라 is_defender 가
--  NULL 이 된다. SQL 에서 NULL 은 두 filter 조건 모두 거짓이 아니라
--  '알 수 없음' 이라, 그 줄은 Defender 에도 그 외에도 안 들어갔다.
--
--  실측 (FY27 Q2): 2,166줄 중 73줄 · 원가 16,361,316원 이 양쪽에서 빠져
--  [지점·판매자별 펼쳐보기] 의 'Defender 건 + 그 외 건' 이 '합계 건' 과
--  맞지 않았다. 인센티브 금액 자체는 영향 없다 — 요율 7% 가 그대로
--  적용돼 합계에는 제대로 들어가 있었다. 나뉘는 칸만 틀렸다.
--
--  모델을 모르면 요율도 DEFAULT(7%) 를 쓰므로 '그 외' 로 센다.
-- ============================================================

create or replace function asap_summary(
  p_from  date,
  p_to    date,
  p_round uuid default null
)
returns table (
  scope     text,
  branch    text,
  person    text,
  lines     bigint,
  vins      bigint,
  cost_sum  numeric,
  lines_df  bigint,
  cost_df   numeric,
  lines_etc bigint,
  cost_etc  numeric,
  flagged   bigint,
  amount    numeric
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
  with l as (
    select * from asap_lines(p_from, p_to, p_round)
     where hard_excluded is null and coalesce(decision,'') <> 'EXCLUDE'
  ),
  u as (select (v #>> '{}')::numeric as unit from asap_config where k = 'round_unit')
  select l.scope, l.branch, l.person,
         count(*) as lines, count(distinct l.vin) as vins, sum(l.cost_sum) as cost_sum,
         -- 모델 미상은 '그 외'. coalesce 가 없으면 NULL 이라 양쪽 다 빠진다.
         count(*) filter (where coalesce(l.is_defender, false)) as lines_df,
         coalesce(sum(l.cost_sum) filter (where coalesce(l.is_defender, false)), 0) as cost_df,
         count(*) filter (where not coalesce(l.is_defender, false)) as lines_etc,
         coalesce(sum(l.cost_sum) filter (where not coalesce(l.is_defender, false)), 0) as cost_etc,
         count(*) filter (where array_length(l.flags, 1) > 0) as flagged,
         ceil(sum(l.cost_sum * l.rate) / (select unit from u)) * (select unit from u) as amount
    from l
   group by l.scope, l.branch, l.person
   order by l.scope, l.branch, l.person
$$;

revoke all on function asap_summary(date, date, uuid) from public;
grant execute on function asap_summary(date, date, uuid) to authenticated;

-- 확인 — 이제 Defender + 그 외 = 합계 여야 한다
select '합계 ≠ Defender+그외 인 사람' as 항목,
       count(*)::text as 값
  from asap_summary('2026-07-01','2026-09-30')
 where lines <> lines_df + lines_etc
union all
select '모델 미상 라인',
       (select count(*)::text from asap_lines('2026-07-01','2026-09-30')
         where model_code is null);
