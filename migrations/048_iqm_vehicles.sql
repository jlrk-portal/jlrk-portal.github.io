-- ============================================================
--  Migration 048 — IQM 차량 마스터 (모델 정보의 최종 기준)
--
--  왜 필요한가
--    Turn Over 의 모델 값은 믿을 수 없다. 실측(FY27 Q1):
--      · 액세서리 줄 3,737건에 모델이 아예 비어 있다
--        → 그대로 두면 Defender 인데도 ETC(7%)로 잡혀 인센티브가 반토막 난다
--      · 「New Range Rover L663」 처럼 이름과 코드가 어긋난 값이 27건 있다
--    IQM 의 Vehicle line 은 「Defender (L663)」 형태로 코드까지 깔끔하다.
--
--  규칙 (매니저 지시 2026-10-21)
--    모델은 IQM 이 모든 것에 우선한다. IQM 에 없는 차대만 기존 기록값을 쓴다.
--    포털의 모든 로직이 이 순서를 따른다.
-- ============================================================

create table if not exists iqm_vehicles (
  vin          text primary key,
  vehicle_line text,                 -- 'Defender (L663)' — 모델의 기준값
  model_code   text,                 -- 'L663' — 괄호 안에서 뽑아 둔다
  platform     text,
  model_year   text,
  body_style   text,
  colour       text,
  engine       text,
  prod_date    date,
  sold_date    date,
  sales_dealer text,
  fleet        text,
  fleet_status text,
  main_usage   text,
  fleet_type   text,
  src_ym       text,                 -- 어느 회차 파일에서 왔는지
  loaded_at    timestamptz not null default now()
);
create index if not exists iqm_line_idx on iqm_vehicles (vehicle_line);
create index if not exists iqm_code_idx on iqm_vehicles (model_code);

alter table iqm_vehicles enable row level security;
drop policy if exists iqm_admin on iqm_vehicles;
create policy iqm_admin on iqm_vehicles
  for all to authenticated using (is_admin()) with check (is_admin());
-- 리테일러도 자기 청구의 검증 근거(모델)를 볼 수 있어야 반박이 가능하다
drop policy if exists iqm_read on iqm_vehicles;
create policy iqm_read on iqm_vehicles for select to authenticated using (true);

-- 적재 현황 (기준 데이터 화면)
create or replace view iqm_status as
  select count(*) as vehicles,
         count(*) filter (where vehicle_line is not null and vehicle_line <> '') as with_line,
         count(distinct vehicle_line) as lines,
         max(src_ym) as last_ym,
         max(loaded_at) as loaded_at
    from iqm_vehicles;

-- ── 모델 해석 — 포털 전체가 이 함수를 쓴다 ────────────────────
--  IQM 우선, 없으면 넘겨받은 기존 기록값.
create or replace function resolve_model(p_vin text, p_fallback text default null)
returns text
language sql
stable
as $$
  select coalesce(
    nullif((select v.vehicle_line from iqm_vehicles v
             where v.vin = upper(btrim(p_vin))), ''),
    nullif(btrim(coalesce(p_fallback, '')), '')
  );
$$;

--  모델 코드(L663 등)만 필요할 때. IQM 에 없으면 기존값에서 긁어낸다.
create or replace function resolve_model_code(p_vin text, p_fallback text default null)
returns text
language sql
stable
as $$
  select coalesce(
    nullif((select v.model_code from iqm_vehicles v
             where v.vin = upper(btrim(p_vin))), ''),
    (select upper(m[1]) from regexp_matches(
       coalesce(p_fallback, ''), '\(?\m([LlXx]\d{3})\M\)?') as m limit 1)
  );
$$;
