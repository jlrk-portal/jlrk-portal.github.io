-- ============================================================
--  Migration 061 — Turn Over 중복키가 '취소/정정 쌍' 을 지우고 있었다
--
--  ⚠ 데이터 정확성 문제다. 액세서리만이 아니라 Turn Over 를 쓰는
--     모든 검증에 영향을 준다.
--
--  045 의 유니크 조합은
--      (정산번호, 정산라인번호, 품목코드, 청구계정, 인보이스번호, 품목유형)
--  인데, 취소/정정 쌍이 바로 이 여섯 개가 전부 같다. 금액 부호만 다르다.
--
--    정산 CA2606000207 라인 1 품번 28VPLXP0513
--      2026-07-21  원가  +1,242,288
--      2026-07-24  원가  −1,242,288     ← 같은 키로 보고 한쪽을 버렸다
--
--  어느 쪽이 남을지는 적재 순서가 정한다. 음수가 남으면 인센티브가
--  깎이고, 양수가 남으면 취소된 건을 지급한다. 둘 다 틀린다.
--
--  실측 (FY27 Q2 · 액세서리 · 인보이스완료일 2026-07-01~09-30):
--      원시                     2,166행 · 613,532,937원
--      045 키로 적재 후         1,911행 · 588,650,528원  ← 255행 사라짐
--      그중 185행이 음수로 남아 금액을 더 깎고 있었다
--      완전 취소된 정산라인 253개 — 쌍이 다 있어야 0 으로 상쇄된다
--
--  인보이스완료일 · 원가합계 · 수량을 키에 넣으면 쌍이 둘 다 남고,
--  진짜 재수출(같은 줄이 다음 달 파일에 또 나오는 것)은 그대로 걸러진다.
--  실측: 확장 키로 합쳐지는 행 0 — 버려지는 게 없다.
--
--  ⚠ 이미 버려진 행은 되살릴 수 없다. Turn Over 를 다시 올려야 한다.
-- ============================================================

set statement_timeout = '30min';

do $$
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'PostgreSQL 15 이상이 필요합니다 (nulls not distinct).';
  end if;
  execute $x$
    create unique index if not exists turnover_lines_dedup2 on turnover_lines
      (stl_no, stl_line, part_no, claim_acct, inv_no, item_type,
       inv_date, cost_sum, qty) nulls not distinct
  $x$;
end $$;

drop index if exists turnover_lines_dedup;   -- 058 의 좁은 키

reset statement_timeout;

-- 확인
select 'turnover_lines_dedup2' as 인덱스,
       case when to_regclass('public.turnover_lines_dedup2') is not null then 'ok' else '없음' end as 상태
union all select 'turnover_lines_dedup (빠져야 함)',
       case when to_regclass('public.turnover_lines_dedup') is null then 'ok' else '아직 있음' end;

-- 지금 들어 있는 액세서리 행수 — 다시 올리기 전 기준값
select count(*) as 액세서리_현재,
       to_char(sum(coalesce(cost_sum,0)),'FM999,999,999,999') as 원가합계
  from turnover_lines
 where part_group = 'Accessories'
   and inv_date between date '2026-07-01' and date '2026-09-30'
   and vin is not null
   and claim_acct in ('일반','원가장착(ACC)','부품판매(개인)');
