-- ============================================================
--  Migration 052 — Sales Incentive 판매자별 내역 + 수정 요청
--
--  매니저 지시(2026-10-22): 리테일러가 판매자별로 볼 수 있어야 하고,
--  실제 판매자가 다르면 수정 요청을 보내 매니저가 승인하면 바뀌어야 한다.
--  관리자 화면에도 리테일러·지점·판매자 표가 필요하다.
--
--  지금까지는 쿠폰북 원본의 판매자ID·판매자명을 읽지도 않고 지점 단위로만
--  집계했다. 원본에는 그 두 열이 들어 있다.
--
--  수정 요청은 '요청'만 담는다 — 승인 전까지 금액·집계는 그대로다.
--  승인하면 seller_name 이 바뀌고 이력(before)이 남는다.
-- ============================================================

create table if not exists incentive_sellers (
  id            uuid primary key default gen_random_uuid(),
  round_id      uuid not null references rounds(id) on delete cascade,
  retailer_id   uuid references retailers(id) on delete set null,
  retailer_code text,
  workshop_code text,                       -- 'CH-SS'
  workshop_name text,                       -- '성수 서비스센터'
  seller_id     text,                       -- 원본 판매자ID
  seller_name   text,                       -- 현재 유효한 판매자명 (승인되면 바뀐다)
  sale          int  not null default 0,
  refund        int  not null default 0,
  cnt           int  not null default 0,    -- 최종판매 = sale - refund
  amount        numeric not null default 0,

  -- 리테일러 수정 요청
  req_name      text,                       -- 리테일러가 적은 실제 판매자명
  req_note      text,
  req_status    text not null default 'NONE'
                  check (req_status in ('NONE','REQUESTED','APPROVED','REJECTED')),
  req_at        timestamptz,
  req_by        uuid references auth.users(id) on delete set null,
  decided_at    timestamptz,
  decided_by    uuid references auth.users(id) on delete set null,
  decide_note   text,
  prev_name     text,                       -- 승인 전 이름 (이력)

  created_at    timestamptz not null default now()
);
create index if not exists inc_sellers_round_idx on incentive_sellers (round_id, retailer_code);
create index if not exists inc_sellers_req_idx   on incentive_sellers (round_id)
  where req_status = 'REQUESTED';
create unique index if not exists inc_sellers_uniq on incentive_sellers
  (round_id, workshop_code, coalesce(seller_id,''), coalesce(seller_name,''));

alter table incentive_sellers enable row level security;

drop policy if exists inc_sellers_admin on incentive_sellers;
create policy inc_sellers_admin on incentive_sellers
  for all to authenticated using (is_admin()) with check (is_admin());

-- 리테일러는 자기 회차 행만 본다
drop policy if exists inc_sellers_read on incentive_sellers;
create policy inc_sellers_read on incentive_sellers
  for select to authenticated
  using (is_admin() or retailer_id = my_retailer());

-- 리테일러는 '요청' 칸만 쓸 수 있다. 금액·건수·이름은 못 바꾼다.
--  (UPDATE 정책은 어느 열을 바꿨는지 볼 수 없으므로, 바뀌면 안 되는 값들이
--   그대로인지 with check 에서 직접 비교한다)
drop policy if exists inc_sellers_request on incentive_sellers;
create policy inc_sellers_request on incentive_sellers
  for update to authenticated
  using (retailer_id = my_retailer() and req_status in ('NONE','REQUESTED','REJECTED'))
  with check (retailer_id = my_retailer() and req_status = 'REQUESTED');

create or replace function inc_sellers_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_admin() then return new; end if;
  -- 리테일러가 바꿀 수 있는 것은 요청 관련 칸뿐이다
  if new.round_id is distinct from old.round_id
     or new.retailer_id is distinct from old.retailer_id
     or new.workshop_code is distinct from old.workshop_code
     or new.seller_id is distinct from old.seller_id
     or new.seller_name is distinct from old.seller_name
     or new.sale is distinct from old.sale
     or new.refund is distinct from old.refund
     or new.cnt is distinct from old.cnt
     or new.amount is distinct from old.amount
     or new.decided_at is distinct from old.decided_at
     or new.prev_name is distinct from old.prev_name then
    raise exception '수정 요청 칸 외에는 변경할 수 없습니다.';
  end if;
  return new;
end $$;

drop trigger if exists inc_sellers_guard_trg on incentive_sellers;
create trigger inc_sellers_guard_trg before update on incentive_sellers
  for each row execute function inc_sellers_guard();
