-- Migration 040 — Pick up & Delivery 건별 검토 결과
--   매니저가 엑셀에서 수기로 확인하던 7개 항목(주문자명·연락처·고객명·차량번호·
--   차량모델·RO/예약번호·차대번호)의 O/X 와 청구유형 판정을 그대로 담는다.
--   리테일러는 자기 지점 건만 보고, 왜 깎였는지 건별로 확인할 수 있어야 한다.
create table if not exists pnd_lines (
  id           uuid primary key default gen_random_uuid(),
  round_id     uuid not null references rounds(id) on delete cascade,
  retailer_id  uuid not null references retailers(id) on delete restrict,
  workshop_id  uuid references workshops(id) on delete set null,
  src_row      int,                    -- 원본 엑셀 행번호 (대조용)
  branch_label text,                   -- 차란차 원본 지점 표기 (예: 'AJU성산 AS')
  svc_date     date,                   -- 탁송일자
  leg          text,                   -- 픽업 / 딜리버리
  svc_type     text,                   -- 서비스 유형
  charge_type  text,                   -- 청구유형_JLRK용 (일반 / One Care)
  brand        text,                   -- Jaguar / LandRover
  orderer      text,
  orderer_tel  text,
  customer     text,
  car_no       text,
  car_model    text,
  ro_no        text,
  vin          text,
  origin       text,                   -- 출발지
  dest         text,                   -- 도착지
  distance     numeric,                -- 주행거리
  claim_jlrk   numeric not null default 0,   -- JLRK청구 (리테일러 원 청구)
  retailer_own numeric not null default 0,   -- 리테일러부담
  total_amt    numeric not null default 0,   -- 청구 금액
  checks       jsonb,                  -- {"주문자명":"O", ... "차대번호":"X"}
  verdict      text not null default 'O' check (verdict in ('O','X')),
  note         text,                   -- JLRK Comment (깎인 사유)
  created_at   timestamptz not null default now()
);
create index if not exists pnd_lines_round_idx    on pnd_lines (round_id, retailer_id);
create index if not exists pnd_lines_workshop_idx on pnd_lines (round_id, workshop_id);
create index if not exists pnd_lines_verdict_idx  on pnd_lines (round_id, verdict);

alter table pnd_lines enable row level security;

-- 관리자: 전체
drop policy if exists pnd_lines_admin on pnd_lines;
create policy pnd_lines_admin on pnd_lines for all to authenticated
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'ADMIN'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'ADMIN'));

-- 리테일러: 자기 법인 건만 읽기. 공지 전(DRAFT)에는 보이지 않는다.
drop policy if exists pnd_lines_retailer on pnd_lines;
create policy pnd_lines_retailer on pnd_lines for select to authenticated
  using (
    exists (select 1 from profiles p
             where p.id = auth.uid() and p.retailer_id = pnd_lines.retailer_id)
    and exists (select 1 from rounds r
                 where r.id = pnd_lines.round_id and r.status <> 'DRAFT')
  );
