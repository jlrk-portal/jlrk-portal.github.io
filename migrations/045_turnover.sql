-- ============================================================
--  Migration 045 — Turn Over 적재 (포털 내 검증의 기준 데이터)
--
--  지금까지 캠페인 검증은 포털 밖에서 로컬 Turn Over 파일을 읽어
--  돌렸다. 매니저가 포털 안에서 전부 끝내려면 Turn Over 자체가
--  DB 에 있어야 한다. 월별 xlsx 를 그대로 적재한다.
--  (월 약 140,000행 · 2025-04 ~ 현재)
-- ============================================================

create table if not exists turnover_lines (
  id          bigserial primary key,
  ym          text not null,            -- 적재 기준 월 'YYYYMM' (파일 기간)
  ro_no       text,
  svc_type    text,                     -- 서비스타입
  in_date     date,                     -- 차량입고일
  ro_date     date,                     -- RO발행일
  stl_no      text,                     -- 정산번호
  stl_line    numeric,                  -- 정산라인번호
  claim_type  text,                     -- 청구유형 (일반/보증/캠페인…)
  claim_acct  text,                     -- 청구계정
  inv_no      text,                     -- 인보이스번호
  inv_status  text,
  inv_date    date,                     -- 인보이스완료일
  item_type   text,                     -- 품목유형 (부품/공임)
  part_no     text,                     -- 품목코드
  part_name   text,
  qty         numeric,                  -- 품목수량
  retail      numeric,                  -- 품목소매가
  retail_sum  numeric,                  -- 품목소매가합계
  sale_sum    numeric,                  -- 품목판매단가합계
  split       numeric,                  -- 분할율 (%)
  disc_code   text,                     -- 할인코드
  vin         text,                     -- 차대번호
  reg_date    date,                     -- 차량등록일
  brand       text,
  model       text,
  dealer      text,                     -- AS딜러
  workshop    text,                     -- AS지점
  customer    text,
  loaded_at   timestamptz not null default now()
);

-- 같은 정산라인이 여러 달 파일에 중복으로 들어온다. 먼저 적재된 쪽을 남긴다.
create unique index if not exists turnover_lines_uniq on turnover_lines
  (coalesce(stl_no,''), coalesce(stl_line,-1), coalesce(part_no,''),
   coalesce(claim_acct,''), coalesce(inv_no,''), coalesce(item_type,''));

create index if not exists turnover_ro_idx   on turnover_lines (ro_no, vin);
create index if not exists turnover_vin_idx  on turnover_lines (vin);
create index if not exists turnover_part_idx on turnover_lines (part_no);
create index if not exists turnover_ym_idx   on turnover_lines (ym);
create index if not exists turnover_inv_idx  on turnover_lines (inv_date);

alter table turnover_lines enable row level security;
drop policy if exists turnover_admin on turnover_lines;
create policy turnover_admin on turnover_lines
  for all to authenticated using (is_admin()) with check (is_admin());
-- 리테일러는 자기 지점 줄만 (검증 근거를 확인할 수 있어야 반박이 가능하다)
drop policy if exists turnover_read on turnover_lines;
create policy turnover_read on turnover_lines
  for select to authenticated using (is_admin());

-- 적재된 월 목록 — 적재 메뉴와 "해당 월 없음" 경고에 쓴다
create or replace view turnover_months as
  select ym, count(*) as lines,
         count(*) filter (where item_type = '부품') as parts,
         min(inv_date) as inv_from, max(inv_date) as inv_to,
         max(loaded_at) as loaded_at
    from turnover_lines group by ym order by ym desc;
