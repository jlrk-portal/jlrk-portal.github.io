-- ============================================================
--  Migration 055 — Sales Report 적재 (ASAP 인센티브의 판매구분 기준)
--
--  ASAP 인센티브는 Turn Over 만으로는 못 낸다. 한 건이 Sales 실적인지
--  Service 실적인지가 Sales Report 에서만 나오기 때문이다.
--    · VIN 이 [전분기 마지막월 ~ 당분기말] Retail 에 있으면 → Sales
--      (그 차를 판 전시장·영업사원 실적)
--    · 그 외 전부 → Service (담당SA 실적)
--  제외 규칙도 여기서 나온다 — Order Type DM(시승차) · LC(커티시카) ·
--  OUV(특수차). 분기말 기준 1년 전까지 봐야 하므로 월별로 쌓아둔다.
--
--  원본: ~/pa/sales_report/Sales_Report_YYYYMM.xlsb 의 'Retail' 시트,
--        헤더 7행. 열 — Vin · Model · Order Type · Retail 전시장 ·
--        영업사원명 · 고객명 · 리테일일자
-- ============================================================

create table if not exists sales_report_lines (
  id          bigserial primary key,
  ym          text not null,            -- 적재 기준 월 'YYYYMM' (파일명)
  vin         text,
  brand       text,
  model       text,                     -- 'Defender (L663) 110'
  model_year  numeric,
  order_type  text,                     -- DM / LC / OUV / 일반 …
  showroom    text,                     -- Retail 전시장 (= 지점)
  retailer    text,                     -- Retailer (ref.)
  seller      text,                     -- 영업사원명
  customer    text,
  retail_date date,                     -- 리테일일자
  note        text,                     -- 비고
  loaded_at   timestamptz not null default now()
);

-- 같은 차가 여러 달 파일에 겹쳐 들어온다. 월+차대+리테일일자로 한 줄만 남긴다.
create unique index if not exists sales_report_uniq on sales_report_lines
  (ym, coalesce(vin,''), coalesce(retail_date,'1900-01-01'::date));

create index if not exists sales_report_vin_idx  on sales_report_lines (vin);
create index if not exists sales_report_ym_idx   on sales_report_lines (ym);
create index if not exists sales_report_date_idx on sales_report_lines (retail_date);

alter table sales_report_lines enable row level security;

-- 관리자 전용. 영업사원명·고객명이 들어 있어 리테일러에게 열지 않는다.
drop policy if exists sales_report_admin on sales_report_lines;
create policy sales_report_admin on sales_report_lines
  for all to authenticated using (is_admin()) with check (is_admin());

-- 적재된 월 목록 — 기준 데이터 화면과 '해당 월 없음' 경고에 쓴다
create or replace view sales_report_months as
  select ym, count(*) as lines,
         count(*) filter (where order_type in ('DM','LC','OUV')) as excluded,
         min(retail_date) as date_from, max(retail_date) as date_to,
         max(loaded_at) as loaded_at
    from sales_report_lines group by ym order by ym desc;
