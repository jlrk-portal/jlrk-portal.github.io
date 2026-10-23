-- ============================================================
--  Migration 066 — 액세서리 프로모션 지원 이력을 DB 로 쌓는다
--
--  매니저 지시(2026-10-23): "프로모션 차대들도 정산서 내가 줄게. 이것도
--  ASAP 전시차 지원금처럼 필드 그대로 유지해서 DB로만 저장해놔."
--
--  실측 (ACC_Promotion_2604to2609.xlsx, Sheet1)
--    497행 · 차대 496대 · 2026-04 ~ 2026-09
--    열 19개 — Month · 구분 · Promotion/Incentive · Program · Program 2 ·
--    Brand · VIN · Model · EV · MY · CODE · KAIDA 등록일 · Retailer · SR ·
--    정산 쇼룸 · Order type · 영업사원명 · 고객명 · Remark
--  전시차와 같은 방식: 쓰는 열은 꺼내고 원본 행은 raw(json) 에 통째로.
-- ============================================================

create table if not exists asap_promo_support (
  id            bigserial primary key,
  src_file      text not null,
  src_row       int,

  month_ym      text,            -- '2604' → 2026-04
  category      text,            -- 구분 (New car …)
  promo_type    text,            -- Promotion/Incentive
  program       text,            -- Program (액세서리 패키지)
  program2      text,            -- Program 2 (Tactical …)
  brand         text,
  vin           text not null,
  model         text,
  ev            text,
  model_year    text,
  reg_date      date,            -- KAIDA 등록일
  retailer_code text,            -- Retailer
  showroom      text,            -- SR
  settle_showroom text,          -- 정산 쇼룸
  order_type    text,
  seller        text,            -- 영업사원명
  customer      text,            -- 고객명
  remark        text,
  raw           json,            -- 원본 행 전체 {헤더: 값}

  loaded_at     timestamptz not null default now(),
  loaded_by     uuid references auth.users(id) on delete set null
);

create unique index if not exists asap_promo_uniq
  on asap_promo_support (src_file, src_row);
create index if not exists asap_promo_vin on asap_promo_support (vin);
create index if not exists asap_promo_ym  on asap_promo_support (month_ym);

alter table asap_promo_support enable row level security;
drop policy if exists asap_promo_admin on asap_promo_support;
create policy asap_promo_admin on asap_promo_support
  for all to authenticated using (is_admin()) with check (is_admin());

-- 차대 하나당 한 줄
create or replace view asap_promo_vehicles as
  select vin,
         string_agg(distinct month_ym, ', ' order by month_ym) as months,
         string_agg(distinct program, ', ')    as programs,
         string_agg(distinct program2, ', ')   as programs2,
         string_agg(distinct showroom, ', ')   as showrooms,
         string_agg(distinct retailer_code, ', ') as retailers,
         min(reg_date) as first_reg, max(reg_date) as last_reg,
         count(*) as lines
    from asap_promo_support
   group by vin;


-- ── 엔진: 프로모션 판정에 이 이력도 함께 본다
create or replace function asap_promo_window()
returns table (vin text, kinds text)
language sql stable as $$
  select vin, string_agg(distinct coalesce(support_type,'프로모션'), ', ') as kinds
    from asap_support_vins where kind = 'PROMO' group by vin
  union all
  select vin, string_agg(distinct coalesce(nullif(program2,''), program, '프로모션'), ', ') as kinds
    from asap_promo_support group by vin
$$;

-- 확인
select 'asap_promo_support' as 항목,
       case when to_regclass('public.asap_promo_support') is not null then 'ok' else '없음' end as 상태
union all select 'asap_promo_vehicles(view)',
       case when to_regclass('public.asap_promo_vehicles') is not null then 'ok' else '없음' end
union all select '지금 쌓인 행', (select count(*)::text from asap_promo_support);
