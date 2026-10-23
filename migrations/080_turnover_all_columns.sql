-- ============================================================
--  Migration 080 — Turn Over 는 열을 하나도 버리지 않는다
--
--  매니저 지시(2026-10-23): "턴오버는 아까도 얘기했지만 거의 모든 정산
--  검증 시 필수적으로 쓰는 데이터파일이야. 모든 필드를 하나도 버리지말고
--  다 담고 있어야해"
--
--  실측: 원본 77열 중 43열만 담고 있었다. 34열을 버리고 있었다.
--    버리던 것 — No · 예약번호 · 인보이스 총금액/금액/할인금액 · 마진 ·
--    마진(%) · 인보이스등록자/취소일/취소자 · ICT 8열 · 차량번호 ·
--    인도일자 · 고객형태 · 거래처코드
--    + 매니저가 엑셀에서 직접 달던 작업열 12개 (인센티브 제외 ·
--      JLRK Comment · 판매구분 · Model · 6th digit · Sold Date ·
--      DF/ETC · 영업사원 · 시승차/커티시카/전시 · 신차등록일 ·
--      영업 프로모션 · 전시차여부)
--
--  ⚠ raw json 으로 통째로 담는 방법은 쓰지 않았다.
--    턴오버는 3개월치만 39만행이고 1년이면 150만행이 넘는다.
--    행당 raw 가 1.6KB 라 3개월 645MB · 1년 2.5GB 가 된다 (실측 평균).
--    그래서 전부 '타입 있는 열' 로 받는다 — 빈 값은 공간을 거의 안 쓰고
--    조회도 된다. 대신 나중에 모르는 열이 오면 raw_extra 에 담는다.
-- ============================================================

-- ── DMS 원본 열
alter table turnover_lines add column if not exists src_no        int;      -- No
alter table turnover_lines add column if not exists booking_no    text;     -- 예약번호
alter table turnover_lines add column if not exists inv_total     numeric;  -- 인보이스 총금액
alter table turnover_lines add column if not exists inv_amount    numeric;  -- 인보이스 금액
alter table turnover_lines add column if not exists inv_discount  numeric;  -- 인보이스 할인금액
alter table turnover_lines add column if not exists margin        numeric;  -- 마진
alter table turnover_lines add column if not exists margin_pct    numeric;  -- 마진(%)
alter table turnover_lines add column if not exists inv_by        text;     -- 인보이스등록자
alter table turnover_lines add column if not exists inv_cancel_at date;     -- 인보이스취소일
alter table turnover_lines add column if not exists inv_cancel_by text;     -- 인보이스취소자
alter table turnover_lines add column if not exists ict_branch    text;     -- ICT 요청지점
alter table turnover_lines add column if not exists ict_req_date  date;     -- ICT요청일
alter table turnover_lines add column if not exists ict_part_name text;     -- ICT요청 부품명
alter table turnover_lines add column if not exists ict_part_no   text;     -- ICT요청 부품코드
alter table turnover_lines add column if not exists ict_out_by    text;     -- ICT출고자
alter table turnover_lines add column if not exists ict_out_at    text;     -- ICT출고일시 (시각 포함)
alter table turnover_lines add column if not exists ict_out_qty   numeric;  -- ICT출고수량
alter table turnover_lines add column if not exists ict_out_amt   numeric;  -- ICT출고금액
alter table turnover_lines add column if not exists car_no        text;     -- 차량번호 ★
alter table turnover_lines add column if not exists delivery_date date;     -- 인도일자
alter table turnover_lines add column if not exists customer_type text;     -- 고객형태
alter table turnover_lines add column if not exists account_code  text;     -- 거래처코드

-- ── 매니저가 엑셀에서 달던 작업열. 포털이 같은 판단을 하지만,
--    원본에 적혀 있으면 그대로 보관한다 (대조용).
alter table turnover_lines add column if not exists note_excl      text;    -- 인센티브 제외
alter table turnover_lines add column if not exists note_jlrk      text;    -- JLRK Comment
alter table turnover_lines add column if not exists note_sale_div  text;    -- 판매구분
alter table turnover_lines add column if not exists note_model     text;    -- Model
alter table turnover_lines add column if not exists note_6th       text;    -- 6th digit
alter table turnover_lines add column if not exists note_sold_date text;    -- Sold Date
alter table turnover_lines add column if not exists note_dfetc     text;    -- DF/ETC
alter table turnover_lines add column if not exists note_seller    text;    -- 영업사원
alter table turnover_lines add column if not exists note_demo      text;    -- 시승차/커티시카/전시
alter table turnover_lines add column if not exists note_newreg    text;    -- 신차등록일
alter table turnover_lines add column if not exists note_promo     text;    -- 영업 프로모션
alter table turnover_lines add column if not exists note_showroom  text;    -- 전시차여부

-- ── 그래도 모르는 열이 오면 여기에. 평소에는 비어 있어 공간을 안 쓴다.
alter table turnover_lines add column if not exists raw_extra json;
comment on column turnover_lines.raw_extra is
  '적재 시 매핑에 없던 열 {헤더: 값}. 비어 있으면 null. 열 순서를 지켜야 해서 jsonb 가 아니라 json.';

create index if not exists turnover_car_no_idx on turnover_lines (car_no);

-- ── 차량번호를 ASAP 스냅샷에도 실어 보낸다
alter table asap_round_lines add column if not exists car_no text;

-- 확인
select '턴오버 열 수' as 항목, count(*)::text as 값
  from information_schema.columns where table_name = 'turnover_lines'
union all select '차량번호 담긴 행',
  (select count(*)::text from turnover_lines where coalesce(car_no,'') <> '')
union all select '안내',
  '새 열은 다음 Turn Over 적재부터 채워집니다 — 기존 3개월분은 다시 올려야 합니다';
