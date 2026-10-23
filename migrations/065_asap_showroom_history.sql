-- ============================================================
--  Migration 065 — 전시차 지원 프로그램 정산서를 DB 로 쌓는다
--
--  매니저 지시(2026-10-23): "FY26 Q1 부터 FY27 Q1까지 전시차 지원 프로그램
--  정산서 다 넣어놨거든 ... 이 차대가 전시차로 어떤 지점에서 사용하던
--  차대정보라는걸 가지고 있어야해 ... DB 테이블로 쌓아놔.
--  그리고 DB를 모을때는 왠만해서는 필드를 버리지말고 최대한 다 쌓아놓고"
--
--  실측 (~/pa/ASAP, 5개 파일 'ASAP 전시차' 시트)
--    FY2526 Q1 239 · Q2 738 · Q3 441 · Q4 348 · FY27 Q1 492  = 2,258행
--    차대 273대
--  파일마다 열이 조금씩 다르다 (JLRK review · check · remark · 청구제외 …).
--  그래서 쓰는 열만 따로 꺼내 두고, 원본 행은 raw 에 통째로 담는다.
--  ⚠ raw 는 jsonb 가 아니라 json — 열 순서를 지켜야 한다.
-- ============================================================

create table if not exists asap_showroom_support (
  id            bigserial primary key,
  fy_label      text not null,      -- 'FY26 Q1' (파일명 FY2526 Q1 → FY26 Q1)
  src_file      text not null,
  src_row       int,

  retailer_code text,               -- 리테일러명 (CH · KCC · AJU …)
  branch_code   text,               -- 지점 (CHN · KCCB · AJUS …) ★ 어느 지점이 쓰던 전시차인지
  is_new        text,               -- 신규/기존
  fit_date      date,               -- 장착일자
  brand         text,
  model         text,               -- 장착 모델 (DF 등)
  l460_support  text,               -- L460/461 지원
  vin           text not null,
  part_no       text,               -- 장착 액세서리 품번
  part_name     text,
  retail_price  numeric,            -- 소비자 가격
  qty           numeric,
  sales_amount  numeric,            -- 총 매출액
  cost_amount   numeric,            -- 매출 원가
  support_amount numeric,           -- 지원 금액
  raw           json,               -- 원본 행 전체 {헤더: 값}

  loaded_at     timestamptz not null default now(),
  loaded_by     uuid references auth.users(id) on delete set null
);

-- 같은 파일의 같은 줄은 한 번만. 다시 올리면 그 분기만 갈아끼운다.
create unique index if not exists asap_showroom_uniq
  on asap_showroom_support (fy_label, src_file, src_row);
create index if not exists asap_showroom_vin  on asap_showroom_support (vin);
create index if not exists asap_showroom_fy   on asap_showroom_support (fy_label);
create index if not exists asap_showroom_br   on asap_showroom_support (branch_code);

alter table asap_showroom_support enable row level security;
drop policy if exists asap_showroom_admin on asap_showroom_support;
create policy asap_showroom_admin on asap_showroom_support
  for all to authenticated using (is_admin()) with check (is_admin());

-- 차대 하나당 한 줄로 — 어느 지점이 언제 전시차로 썼는지
create or replace view asap_showroom_vehicles as
  select vin,
         min(fy_label)                              as first_fy,
         max(fy_label)                              as last_fy,
         string_agg(distinct fy_label, ', ' order by fy_label)      as quarters,
         string_agg(distinct branch_code, ', ')     as branches,
         string_agg(distinct retailer_code, ', ')   as retailers,
         min(fit_date)                              as first_fit,
         max(fit_date)                              as last_fit,
         count(*)                                   as lines,
         sum(coalesce(support_amount,0))            as support_amount
    from asap_showroom_support
   group by vin;


-- 확인
select 'asap_showroom_support' as 항목,
       case when to_regclass('public.asap_showroom_support') is not null then 'ok' else '없음' end as 상태
union all select 'asap_showroom_vehicles(view)',
       case when to_regclass('public.asap_showroom_vehicles') is not null then 'ok' else '없음' end
union all select '지금 쌓인 행',
       (select count(*)::text from asap_showroom_support);
