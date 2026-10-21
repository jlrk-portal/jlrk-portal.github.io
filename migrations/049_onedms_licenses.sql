-- ============================================================
--  Migration 049 — One DMS 라이선스 유형 (관리자 전용)
--
--  매니저 지시 (2026-10-21): 라이선스 유형을 포털에 넣되
--  "절대 리테일러쪽에는 안 나가게" 막는다.
--
--  ⚠ 왜 claims.detail 에 넣지 않는가
--     리테일러는 자기 claims 행을 읽을 수 있다. detail 은 jsonb 라
--     화면에서 가려도 API 로는 그대로 보인다. 화면만 가리는 건
--     막은 게 아니다. 그래서 유형은 아예 별도 표에 두고 RLS 로
--     관리자만 읽게 한다 — 리테일러 정책을 만들지 않는다.
--
--  원본 월 셀에 이미 'PRO' / 'SERVICE' 같은 값이 들어 있었는데
--  지금까지는 "값이 있으면 과금" 으로만 쓰고 유형은 버리고 있었다.
-- ============================================================

create table if not exists onedms_licenses (
  id            uuid primary key default gen_random_uuid(),
  round_id      uuid not null references rounds(id) on delete cascade,
  retailer_id   uuid references retailers(id) on delete set null,
  retailer_code text,
  dealer_name   text,                  -- 원본의 딜러사 표기 그대로
  user_name     text,
  login         text,
  role          text,
  first_login   text,
  status        text,                  -- 재직 / 퇴직
  retire        text,
  month_labels  text[],                -- ['7월','8월','9월']
  types         text[],                -- ['PRO','PRO',''] — month_labels 와 같은 순서
  months_active int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists onedms_lic_round_idx on onedms_licenses (round_id, retailer_code);
create index if not exists onedms_lic_type_idx  on onedms_licenses (round_id)
  where months_active > 0;

alter table onedms_licenses enable row level security;

-- 관리자만. 리테일러 정책은 일부러 만들지 않는다 — 만들면 그 순간 샌다.
drop policy if exists onedms_lic_admin on onedms_licenses;
create policy onedms_lic_admin on onedms_licenses
  for all to authenticated using (is_admin()) with check (is_admin());

-- 증빙의 「Retailer Charge」 시트 — 리테일러 × 유형 × 월별 수량
create or replace view onedms_charge_matrix as
  select l.round_id, l.retailer_code, l.dealer_name,
         upper(btrim(t.type)) as license_type,
         l.month_labels[t.ord] as month_label,
         count(*) as users
    from onedms_licenses l
    cross join lateral unnest(l.types) with ordinality as t(type, ord)
   where btrim(coalesce(t.type, '')) <> ''
   group by l.round_id, l.retailer_code, l.dealer_name,
            upper(btrim(t.type)), l.month_labels[t.ord];

-- 뷰도 관리자만 (기반 표의 RLS 를 그대로 탄다)
revoke all on onedms_charge_matrix from anon;
