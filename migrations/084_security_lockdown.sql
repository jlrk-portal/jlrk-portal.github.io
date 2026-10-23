-- ============================================================
--  Migration 084 — 보안: 계산용 함수를 '누구나 실행' 에서 막는다
--
--  매니저 지시(2026-10-23): "서로다른 리테일러가 절대 다른 리테일러꺼를
--  볼수없고 ... 해킹시도등을 통해서도 보면 안되. 보안테스트를 자체적으로
--  강력하게 진행해서 뚤리는지 한번 해보고 ... 보안설계 진행해"
--
--  자체 침투 테스트 결과(2026-10-23, 검증서버):
--    로그인하지 않은 익명 클라이언트로 RPC 를 직접 호출했더니 —
--      asap_lines_json → 전 리테일러 라인 노출 (차대·원가·품번)
--      asap_summary    → 전 리테일러 지점·담당자·금액 노출
--    PostgreSQL 은 함수를 만들 때 EXECUTE 를 PUBLIC 에 기본 부여한다.
--    그래서 이 계산 함수들이 anon(익명)·authenticated(리테일러 포함)
--    누구에게나 열려 있었다. 화면은 안 거쳐도 키 하나로 호출됐다.
--
--  원칙:
--   · 리테일러가 쓰는 함수(asap_saved_*, asap_my_lines)는 내부에서
--     my_retailer() 로 자른다 — 익명엔 0행, 남의 것도 0행. 그대로 둔다.
--   · 관리자 계산 함수(asap_lines / _json / _summary, 창·매핑 헬퍼)는
--     리테일러·익명이 만질 일이 없다. PUBLIC·anon·authenticated 에서
--     실행권을 거둔다. 보안definer 래퍼(asap_snapshot 등)는 소유자
--     권한으로 돌므로 영향 없다.
--   · 관리자가 '직접' 부르던 자리(아카이브 원본 내보내기)는 is_admin()
--     으로 막은 전용 함수로 바꾼다.
-- ============================================================

-- ── 1. 계산용 원본 함수 — 아무도 직접 못 부르게 (소유자/보안definer 만)
revoke all on function asap_lines(date, date, uuid)           from public, anon, authenticated;
revoke all on function asap_lines_json(date, date, uuid)      from public, anon, authenticated;
revoke all on function asap_summary(date, date, uuid)         from public, anon, authenticated;
revoke all on function asap_showroom_window(date, date, int)  from public, anon, authenticated;
revoke all on function asap_promo_window()                    from public, anon, authenticated;
revoke all on function asap_branch_retailer(text, text)       from public, anon, authenticated;

-- ── 2. 관리자가 직접 쓰던 자리(아카이브 원본 내보내기)용 — is_admin() 게이트
create or replace function asap_lines_admin(p_from date, p_to date, p_round uuid default null)
returns json
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
begin
  if not is_admin() then raise exception '관리자만 조회할 수 있습니다'; end if;
  return (select coalesce(json_agg(x), '[]'::json) from asap_lines(p_from, p_to, p_round) x);
end
$$;
revoke all on function asap_lines_admin(date, date, uuid) from public, anon, authenticated;
grant execute on function asap_lines_admin(date, date, uuid) to authenticated;

create or replace function asap_summary_admin(p_from date, p_to date, p_round uuid default null)
returns json
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '110s'
as $$
begin
  if not is_admin() then raise exception '관리자만 조회할 수 있습니다'; end if;
  return (select coalesce(json_agg(x), '[]'::json) from asap_summary(p_from, p_to, p_round) x);
end
$$;
revoke all on function asap_summary_admin(date, date, uuid) from public, anon, authenticated;
grant execute on function asap_summary_admin(date, date, uuid) to authenticated;

-- ── 3. 혹시 다른 계산/삭제 함수에도 PUBLIC 기본부여가 남아 있으면 거둔다.
--      (이미 거둔 것은 다시 거둬도 무해하다)
revoke all on function asap_snapshot(uuid, date, date)       from public, anon;
revoke all on function turnover_delete_ym(text, int)         from public, anon;
revoke all on function sales_report_delete_ym(text, int)     from public, anon;
revoke all on function part_prices_delete_ym(text, int)      from public, anon;
revoke all on function asap_accept_request(bigint)           from public, anon;
revoke all on function asap_undo_request(bigint)             from public, anon;

-- ── 확인 — 아래 둘은 '관리자만' 나와야 정상. 익명으로 호출 시 거부돼야 한다.
select 'asap_lines_admin / asap_summary_admin 생성' as 항목,
       (select count(*)::text from pg_proc
         where proname in ('asap_lines_admin','asap_summary_admin')) as 값;


-- ============================================================
--  2부 — RLS: '아무 로그인 사용자나 전부 읽기(using true)' 를 조인다
--
--  침투 테스트에서 아래 네 표가 read 정책이 using(true) 라, 리테일러 A
--  계정으로도 다른 리테일러·전 차종 데이터를 읽을 수 있었다.
--   · asap_line_overrides — 판매자 정정(직원 이름 포함)이 전 리테일러 노출
--   · iqm_vehicles        — 전 차대·판매딜러 노출 (차대로 남의 판매 추적 가능)
--   · campaign_rules       — 내부 검증 규칙·임계값 노출 (우회에 악용 가능)
--   · part_prices          — 전 품목 가격/매입가(NIV) 노출
--
--  네 표 모두 '리테일러 화면이 직접 읽지 않는다'. 관리자 화면만 읽고,
--  산출 엔진은 보안definer(소유자 권한, RLS 우회)로 돈다. 그래서 read 를
--  관리자로 좁혀도 리테일러 기능은 멀쩡하다.
-- ============================================================

drop policy if exists asap_line_ovr_read on asap_line_overrides;
create policy asap_line_ovr_read on asap_line_overrides
  for select to authenticated using (is_admin());

drop policy if exists iqm_read on iqm_vehicles;
create policy iqm_read on iqm_vehicles
  for select to authenticated using (is_admin());

drop policy if exists campaign_rules_read on campaign_rules;
create policy campaign_rules_read on campaign_rules
  for select to authenticated using (is_admin());

drop policy if exists part_prices_read on part_prices;
create policy part_prices_read on part_prices
  for select to authenticated using (is_admin());

-- 확인 — using(true) 로 남은 민감 테이블이 더 있나 (settlement_types_public 뷰는 정상)
select schemaname, tablename, policyname, cmd, qual
  from pg_policies
 where schemaname = 'public'
   and cmd = 'SELECT'
   and (qual = 'true' or qual is null)
 order by tablename;
