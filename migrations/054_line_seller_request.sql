-- ============================================================
--  Migration 054 — 건별 판매자 수정 요청
--
--  매니저 지시(2026-10-22): 인센티브는 건별로 책정되니 차대번호·고객명·
--  판매일자가 보여야 하고, 실제 판매자가 다를 수 있으니 '개별 건' 에 대해
--  수정 요청을 할 수 있어야 한다.
--
--  ⚠ 판매자 집계(incentive_sellers)에 요청을 달면, 승인해도 건수가 옮겨가지
--     않는다. 라인이 진짜 원본이므로 요청도 라인에 단다. 승인하면 그 라인의
--     판매자가 바뀌고 집계는 자연히 따라 움직인다.
-- ============================================================

alter table engineoil_lines add column if not exists req_seller  text;
alter table engineoil_lines add column if not exists req_note    text;
alter table engineoil_lines add column if not exists req_status  text not null default 'NONE';
alter table engineoil_lines add column if not exists req_at      timestamptz;
alter table engineoil_lines add column if not exists req_by      uuid references auth.users(id) on delete set null;
alter table engineoil_lines add column if not exists decided_at  timestamptz;
alter table engineoil_lines add column if not exists decided_by  uuid references auth.users(id) on delete set null;
alter table engineoil_lines add column if not exists decide_note text;
alter table engineoil_lines add column if not exists prev_seller text;

alter table engineoil_lines drop constraint if exists eo_lines_req_chk;
alter table engineoil_lines add constraint eo_lines_req_chk
  check (req_status in ('NONE','REQUESTED','APPROVED','REJECTED'));

create index if not exists eo_lines_req_idx on engineoil_lines (round_id)
  where req_status = 'REQUESTED';

-- 리테일러는 자기 라인의 '요청' 칸만 쓸 수 있다
drop policy if exists eo_lines_request on engineoil_lines;
create policy eo_lines_request on engineoil_lines
  for update to authenticated
  using (retailer_id = my_retailer() and req_status in ('NONE','REQUESTED','REJECTED'))
  with check (retailer_id = my_retailer() and req_status = 'REQUESTED');

-- 금액·건수·판매자명을 리테일러가 직접 못 바꾸게 막는다 (정책만으로는 열 단위를 못 본다)
create or replace function eo_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_admin() then return new; end if;
  if new.round_id is distinct from old.round_id
     or new.retailer_id is distinct from old.retailer_id
     or new.workshop_code is distinct from old.workshop_code
     or new.seller_name is distinct from old.seller_name
     or new.seller_id is distinct from old.seller_id
     or new.vin is distinct from old.vin
     or new.total_amt is distinct from old.total_amt
     or new.saveback is distinct from old.saveback
     or new.incentive is distinct from old.incentive
     or new.decided_at is distinct from old.decided_at
     or new.prev_seller is distinct from old.prev_seller then
    raise exception '수정 요청 칸 외에는 변경할 수 없습니다.';
  end if;
  return new;
end $$;

drop trigger if exists eo_lines_guard_trg on engineoil_lines;
create trigger eo_lines_guard_trg before update on engineoil_lines
  for each row execute function eo_lines_guard();
