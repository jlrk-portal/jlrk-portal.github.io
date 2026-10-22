-- ============================================================
--  Migration 053 — 엔진오일 원본 라인 보관 (리테일러 엑셀용)
--
--  매니저 지시(2026-10-22): 리테일러가 엑셀로 받으면 '자기 것만' 로우데이터가
--  그대로 들어가 있어야 한다. 지금은 지점별 집계만 들어가고 원본 행이 없다.
--
--  파서가 집계만 하고 원본 행을 버리고 있었다. 그대로 쌓아둔다.
--  리테일러는 자기 리테일러 행만 읽는다(RLS). 남의 건은 안 보인다.
-- ============================================================

create table if not exists engineoil_lines (
  id            bigserial primary key,
  round_id      uuid not null references rounds(id) on delete cascade,
  retailer_id   uuid references retailers(id) on delete set null,
  retailer_code text,
  workshop_code text,
  kind          text not null default 'COUPON' check (kind in ('COUPON','BOOK')),

  -- 쿠폰 클레임(사용반환금/Retailer Support) 원본 열
  coupon_no     text,          -- 쿠폰번호
  ref_no        text,          -- 쿠폰사용 참조번호
  claim_status  text,
  used_at       text,          -- 사용일자
  sent_at       text,          -- 클레임전송일자
  customer      text,
  car_no        text,
  vin           text,
  site_name     text,          -- 원본 지점 표기
  parts_amt     numeric,
  labour_amt    numeric,
  total_amt     numeric,

  -- 쿠폰북(Sales Incentive) 원본 열
  book_id       text,          -- 쿠폰북ID
  book_type     text,          -- 판매/환불/반품
  product       text,
  seller_id     text,
  seller_name   text,
  base_ym       text,

  -- 계산 결과 (리테일러가 금액 근거를 같이 보게)
  saveback      numeric,       -- 사용반환금 (총금액 × 80%)
  vme           numeric,
  castrol       numeric,
  incentive     numeric,

  created_at    timestamptz not null default now()
);
create index if not exists eo_lines_round_idx on engineoil_lines (round_id, retailer_code);
create index if not exists eo_lines_ws_idx    on engineoil_lines (round_id, workshop_code);

alter table engineoil_lines enable row level security;

drop policy if exists eo_lines_admin on engineoil_lines;
create policy eo_lines_admin on engineoil_lines
  for all to authenticated using (is_admin()) with check (is_admin());

-- 리테일러는 자기 것만. 남의 리테일러 라인은 절대 안 보인다.
drop policy if exists eo_lines_read on engineoil_lines;
create policy eo_lines_read on engineoil_lines
  for select to authenticated
  using (is_admin() or retailer_id = my_retailer());
