-- ============================================================
--  Migration 037 — 캠페인 부품할인 정산 (청구 라인 + 검증 + 반송)
--
--  리테일러가 올린 캠페인 청구서를 라인 단위로 보관하고,
--  마감 Turn Over·부품가격 마스터와 자동 대조한 결과를 함께 저장한다.
--  (2026-10-17 하계캠페인 설계)
-- ============================================================

create table if not exists campaign_lines (
  id            uuid primary key default gen_random_uuid(),
  round_id      uuid not null references rounds(id) on delete cascade,
  retailer_id   uuid not null references retailers(id) on delete restrict,
  src_row       int,                         -- 원본 엑셀 행번호
  workshop      text,
  ro_no         text not null,
  vin           text,
  invoice_date  date,
  part_no       text not null,
  part_name     text,
  qty           numeric,
  retail        numeric,                     -- 소비자가 (리테일러 입력)
  sale          numeric,                     -- 판매가
  discount      numeric,                     -- 할인적용
  jlrk          numeric,                     -- JLRK 지원금 (50%)
  rate          numeric,                     -- 할인율
  self_excluded boolean not null default false,   -- 리테일러 '정산제외' 표기

  -- 자동 검증 결과
  verdict       text not null default 'PENDING'
                  check (verdict in ('PENDING','PASS','WARN','FAIL')),
  checks        jsonb,                       -- [{name, claim, close, lvl, note}]
  flags         text[],
  warns         text[],
  to_jlrk       numeric,                     -- 마감 기준 JLRK 지원금

  -- 관리자 처리
  decision      text not null default 'NONE'
                  check (decision in ('NONE','APPROVED','EXCEPTION','REJECT','REJECT_FINAL')),
  decided_by    uuid references auth.users(id) on delete set null,
  decided_at    timestamptz,
  note          text,                        -- 예외승인/반려 코멘트 (리테일러에게 보임)

  -- 리테일러 재청구
  revised_retail numeric, revised_sale numeric, revised_qty numeric,
  revised_at     timestamptz,
  revision       int not null default 0,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists campaign_lines_round_idx    on campaign_lines (round_id, retailer_id);
create index if not exists campaign_lines_verdict_idx  on campaign_lines (round_id, verdict);
create index if not exists campaign_lines_ro_idx       on campaign_lines (round_id, ro_no, vin);

-- 반송 발송 묶음 (리테일러당 1건으로 모아 보낸다)
create table if not exists campaign_rejections (
  id          uuid primary key default gen_random_uuid(),
  round_id    uuid not null references rounds(id) on delete cascade,
  retailer_id uuid not null references retailers(id) on delete restrict,
  kind        text not null check (kind in ('REVISE','FINAL')),  -- 일반반송 / 완전반송
  line_count  int not null default 0,
  amount      numeric,
  memo        text,
  sent_at     timestamptz,
  sent_by     uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists campaign_rejections_idx on campaign_rejections (round_id, retailer_id);

alter table campaign_lines      enable row level security;
alter table campaign_rejections enable row level security;

drop policy if exists campaign_lines_admin on campaign_lines;
create policy campaign_lines_admin on campaign_lines
  for all to authenticated using (is_admin()) with check (is_admin());

-- 리테일러는 자기 것만 보고, 반송(REVISE)된 라인의 금액만 고칠 수 있다
drop policy if exists campaign_lines_read on campaign_lines;
create policy campaign_lines_read on campaign_lines
  for select to authenticated using (is_admin() or retailer_id = my_retailer());

drop policy if exists campaign_lines_revise on campaign_lines;
create policy campaign_lines_revise on campaign_lines
  for update to authenticated
  using (retailer_id = my_retailer() and decision = 'REJECT')
  with check (retailer_id = my_retailer());

drop policy if exists campaign_rej_admin on campaign_rejections;
create policy campaign_rej_admin on campaign_rejections
  for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists campaign_rej_read on campaign_rejections;
create policy campaign_rej_read on campaign_rejections
  for select to authenticated using (is_admin() or retailer_id = my_retailer());
