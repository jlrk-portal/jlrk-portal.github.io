-- Migration 038 — 캠페인 RO 단위 검증 요약 + 마감 줄 스냅샷
create table if not exists campaign_ro (
  id          uuid primary key default gen_random_uuid(),
  round_id    uuid not null references rounds(id) on delete cascade,
  retailer_id uuid not null references retailers(id) on delete restrict,
  ro_no       text not null,
  vin         text,
  workshop    text,
  center      text,
  model       text,
  in_date     date,
  reg_date    date,
  parts       int,
  claim_jlrk  numeric,
  to_jlrk     numeric,
  verdict     text not null default 'PASS' check (verdict in ('PASS','WARN','FAIL')),
  nwarn       int not null default 0,
  checks      jsonb,          -- 화면 상단 대조표
  close_lines jsonb,          -- 마감 줄 스냅샷 (Turn Over)
  decision    text not null default 'NONE'
                check (decision in ('NONE','APPROVED','EXCEPTION','REJECT','REJECT_FINAL')),
  note        text,
  decided_by  uuid references auth.users(id) on delete set null,
  decided_at  timestamptz,
  unique (round_id, ro_no, vin)
);
create index if not exists campaign_ro_idx on campaign_ro (round_id, verdict, retailer_id);
alter table campaign_ro enable row level security;
drop policy if exists campaign_ro_admin on campaign_ro;
create policy campaign_ro_admin on campaign_ro for all to authenticated
  using (is_admin()) with check (is_admin());
drop policy if exists campaign_ro_read on campaign_ro;
create policy campaign_ro_read on campaign_ro for select to authenticated
  using (is_admin() or retailer_id = my_retailer());
