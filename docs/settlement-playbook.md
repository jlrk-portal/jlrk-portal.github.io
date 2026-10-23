# 정산 포털 구조 해부 · 새 정산 만드는 표준

> 2026-10-23 작성. 매니저 지시: "정산포털 전부다 소스 훑으면서 구조 전부 다시 파악해 …
> 하나의 정산이 어떤기능으로 만들어지고 구성되고 정산이이루어지는지를 알아야
> 다른정산에도 어떤스킬을 적용하는지 바로 쓸수있으니깐"
>
> `CLAUDE.md` 는 프로젝트 배경·사고 이력이고, 이 문서는 **"정산 하나를 어떻게
> 조립하는가"** 만 다룬다. 새 정산을 만들 때 이 문서의 7장 결정 트리부터 본다.

---

## 1. 큰 그림 — 데이터가 흐르는 길

```
 ① 원천 적재            ② 산출/청구              ③ 검증              ④ 확정·지급
───────────────      ─────────────────      ──────────────     ─────────────────
Turn Over            SYSTEM  : JLRK가 계산    규칙 자동판정       claims.approved_amount
Sales Report    ──▶  UPLOAD  : 리테일러 제출  ──▶ 사람 판단   ──▶ 세금계산서 접수
IQM 차량마스터        ADMIN_UP: 관리자 배포    리테일러 이의       바우처(결재 엑셀)
부품가격 마스터       UNIT    : 수량×단가                          email_outbox 발송
…                   MANUAL  : 직접 입력
```

- 프런트는 `index.html` 단일 파일. 빌드 없음. 화면 분기는 전부 함수 이름으로 갈린다.
- 격리는 **전부 Postgres RLS**. 화면 필터는 UX일 뿐이다.
  (`public.is_admin()` / `public.my_retailer()` 두 함수가 모든 정책의 기준)
- 운영/검증 두 벌: `index.html`(운영) · `staging/index.html`(검증). `ENVS` 가 호스트명으로 가른다.

---

## 2. 원천 데이터 소스 (2026-10-23 검증서버 실측)

| 테이블 | 무엇 | 누가 올리나 | 행수 | 쓰는 정산 |
|---|---|---|---|---|
| `turnover_lines` | DMS Turn Over 리포트 (RO·품목·원가·차대) | 관리자 월별 xlsx | 수십만 | ASAP · 캠페인 대조 |
| `sales_report_lines` | 월별 판매 실적 (차대·전시장·영업사원·고객·리테일일자·order_type) | 관리자 월별 | 5,750 | ASAP 판매구분/시승차 판정 |
| `iqm_vehicles` | 차량 마스터 (vehicle_line·model_code·연식·바디·색상) | 관리자 | 121,206 | **모델 판정의 유일한 기준** |
| `part_prices` | 부품가격 마스터 (월별 소비자가/NIV) | 관리자 월별 | 1,317,494 | 캠페인 소비자가 대조 |
| `onedms_licenses` | One DMS 라이선스 로우데이터 | 관리자 | 0(운영만) | One DMS AR |
| `engineoil_lines` | 쿠폰/쿠폰북 정산내역 (+원본 행 `raw`) | 관리자 | 2,129 | Engine Oil 3종 |
| `pnd_lines` | 픽업&딜리버리 원본 (+ 항목별 O/X) | 관리자 | 15,208 | P&D |
| `campaign_ro` / `campaign_lines` | 캠페인 청구 RO/라인 + 검증결과 | 리테일러 제출 → 파싱 | 732 / 5,181 | 캠페인 3종 |
| `campaign_vin_lists` / `_rows` | 대상 차대 · 리콜 목록 | 관리자 | — | 캠페인 조건 대조 |
| `asap_showroom_support` | 전시차 지원 정산서 이력 (원본 열 전부 `raw`) | 관리자 | 2,258 | ASAP 검토 근거 |
| `asap_promo_support` | 액세서리 프로모션 이력 (원본 열 전부 `raw`) | 관리자 | 497 | ASAP 검토 근거 |
| `asap_round_lines` | **회차 스냅샷** (계산 결과 + 턴오버 원본 행) | `asap_snapshot()` | 2,166 | ASAP 전부 |
| `settled_records` | 기정산 지문 (`type_id` + `dedup_hash`) | 자동 | — | SYSTEM 유형 중복 방지 |
| `legacy_settlements` | 도입 전 수기 정산 이력 | 관리자 초기적재 | 1,019 | 중복 방지 |
| `incentive_sellers` | 판매자별 인센티브 + 수정 요청 | 자동 | 65 | Engine Oil SI |

**원칙 — 원본은 버리지 않는다.** 파서가 쓰는 열만 담지 말고 원본 행 전체를 `raw json`
(jsonb 아님 — 열 순서가 깨진다) 으로 같이 담는다. 마스터 다운로드·근거 제시에 반드시 필요하다.

---

## 3. 지금 살아있는 정산 유형 10종

| code | 방향/주기/단위 | amount_mode | preset | 계산서 | 관리자 화면 | 리테일러 화면 |
|---|---|---|---|---|---|---|
| `ASAP_INCENTIVE` | AP/분기/법인 | ADMIN_UPLOAD | `ASAP_ADMIN_UPLOAD` | X | `renderAsapRoundDetail` | `renderAsapRetailerCard` |
| `ASAP_SUPPORT` | AP/분기/법인 | UPLOAD | — | O | 기본 AP | 기본 AP |
| `Engine Oil Package_RS` | AP/월/법인 | SYSTEM | `ENGINE_OIL_RS` | X | `renderEngineOilRoundDetail` | `renderEngineOilRetailerCard` |
| `Engine Oil Package_SI` | AP/분기/법인 | SYSTEM | `ENGINE_OIL_SI` | X | 〃 | 〃 |
| `Engine Oil Package_SP` | **AR**/월/법인 | SYSTEM | `ENGINE_OIL_SP` | X | 〃 | 〃 |
| `One DMS License` | **AR**/분기/법인 | SYSTEM | `ONE_DMS_AR` | X | `renderOneDmsRoundDetail` | `renderOneDmsRetailerCard` |
| `ONE_CARE_INCENTIVE` | AP/분기/법인 | ADMIN_UPLOAD | `ADMIN_UPLOAD` | X | `renderAdminUploadSection` | `renderAdminUploadRetailerCard` |
| `Pick up & Delivery` | AP/분기/**지점** | UPLOAD | `PND_REVIEW` | O | `renderPndRoundDetail` | `renderPndRetailerCard` |
| `Recall Upselling` | AP/분기/지점 | UPLOAD | — | O | `renderCampaignRoundDetail` | `renderCampaignRetailerCards` |
| `Summer Campaign` | AP/연/지점 | UPLOAD | — | X | 〃 | 〃 |

**화면 분기 지점 두 곳만 기억하면 된다.**

- 관리자: `renderRoundDetail()` 의 `if` 사다리 — ONE_DMS_AR → CAMPAIGN_PARTS_DC → PND_REVIEW →
  `isEnginePreset` → `isAsapIncentive` → `direction==='AR'` → (기본 AP)
- 리테일러: `loadRetailerClaims()` 의 `if` 사다리 — 같은 순서 + `isAdminUploadType`

> ⚠ **순서가 곧 우선순위다.** ASAP 리테일러 카드가 안 보이던 사고의 원인은
> `isAdminUploadType` 이 `isAsapIncentive` 보다 위에 있어서였다. 새 preset 은
> 더 좁은 조건을 **위로** 넣는다.

---

## 4. 청구방식 (amount_mode) 4+1 가지

### ① `UPLOAD` — 리테일러가 엑셀을 올린다
흐름: `DRAFT → OPEN(청구 접수) → CLOSED → CONFIRMED(확정 공지) → INVOICED → VOUCHERED`
- 리테일러: 양식 다운로드 → 작성 → 업로드(`storage: claims`) → 제출
- 관리자: 파싱(`parseClaimWorkbook`) → 검토 → 승인/반송(`reject_reason`) → 확정
- `claim_unit` 이 `WORKSHOP` 이면 지점별 청구, `RETAILER` 면 법인 1건
- **세금계산서는 언제나 법인×회차 1장** (`invoices`) — `claim_unit` 과 무관

### ② `SYSTEM` — JLRK 가 원천에서 계산하고 리테일러는 확인만
흐름: `DRAFT(원본 업로드·미리보기) → PUBLISHED(공지) → 리테일러 확정 → FINALIZED → VOUCHERED`
- 리테일러는 **금액을 못 고친다.** 확인(`claims.confirmed_at`) 또는 이의제기만
- 중복 방지: `settlement_types.dedup_keys` 조합키 → 정규화(공백제거+대문자) → `settled_records`
  - ⚠ **여러 건이 묶이는 컬럼을 단독 키로 쓰지 말 것** (참조번호 1개에 쿠폰 여러 장 실측)
- 예: Engine Oil(쿠폰), One DMS(라이선스), ASAP(Turn Over)

### ③ `ADMIN_UPLOAD` — 관리자가 리테일러별 파일을 배포하고 회신받는다
- 관리자가 산정 엑셀을 리테일러별로 올림 → 리테일러는 확인하거나 **수정본을 회신**
- 가장 손이 많이 가는 방식. 계산을 포털 안으로 옮길 수 있으면 `SYSTEM` 으로 승격시키는 게 맞다
  (ASAP 이 정확히 이 경로를 밟았다 — ADMIN_UPLOAD 로 시작 → Turn Over 산출로 전환)

### ④ `UNIT` — 수량 × 단가
- AR 전용 경로(`renderARRoundDetail` 의 `isUnit`). 리테일러별 수량만 입력, 금액은 읽기전용
- `charge_unit='PRIMARY'` 면 대표지점(`workshops.is_primary` + `customer_code`)에 몰아서 바우처

### ⑤ `MANUAL` — 관리자가 금액을 직접 적는다. 예외 처리용.

### AP vs AR — 방향이 바꾸는 것
| | AP (JLRK→리테일러 지급) | AR (JLRK→리테일러 청구) |
|---|---|---|
| 누가 청구서를 내나 | 리테일러 | 없음 (JLRK가 통보) |
| 리테일러 액션 | 제출 → 확정 대기 | 확인 / 이의제기(`disputes`) |
| 상태 | OPEN→CLOSED→CONFIRMED→INVOICED | PUBLISHED→FINALIZED |
| 거래처 코드 | **vendor code** `KRJD01048` | **customer code** `KR01074MIS` |
| 세금계산서 | 리테일러가 발행 → 포털 업로드 | JLRK가 발행 |

---

## 5. 검증방식 — 지금 쓰는 3가지와 그 한계

### A. 파일이 검증을 들고 온다 (P&D)
리테일러 제출 열 7개 / JLRK 확인 열 7개가 **같은 이름으로 나란히** 있는 엑셀.
`pndParse` 가 머리글을 1번째/2번째로 갈라 읽어 `checks{항목:O|X}` + `verdict` 를 담는다.
- 장점: 기존 업무 양식 그대로. 도입 비용 0
- 한계: 검증 자체는 여전히 엑셀에서 사람이 한다. 포털은 보관·집계만

### B. 바깥(Python)에서 판정해서 넣는다 (Summer Campaign)
`campaign_lines.verdict` + `checks` + `warns` 가 이미 채워진 채로 적재된다.
- 포털에 **규칙 설정 UI 는 이미 있다** — `campaign_rules` 테이블 + `COND_DEFS` 15종
  (`REG_DATE_RATE` `FIXED_RATE` `PART_RETAIL_MIN/MAX` `PART_PRICE_MATCH` `PART_IN_MASTER`
   `PART_NO` `PART_GROUP` `VIN_LIST` `RECALL_CODE` `CLAIM_ACCOUNT` `CLAIM_TYPE`
   `SHARE_BALANCE` `MODEL` `NO_DUP_CLAIM`), 조건마다 `level: ng|wn`
- **없는 것은 실행부다.** 규칙을 읽어 라인에 적용하는 엔진이 포털 안에 없다 ← 최대 미완성

### C. 포털 안에서 계산하고 사람이 라인별로 결정한다 (ASAP — 현재 최선)
```
asap_lines()      원천 → 라인 + hard_excluded(규칙상 무조건 제외) + flags(검토 사유)
asap_snapshot()   그 결과를 회차에 통째로 저장 (턴오버는 한 번만 훑는다)
asap_line_decisions   매니저 판단: EXCLUDE / KEEP + 사유
asap_line_overrides   판매자 정정 반영
asap_line_requests    리테일러 신청: 판매자 정정 / 이의신청
```
핵심 설계 3가지:
1. **규칙은 자동으로 빼지 않는다.** 사유를 달아 보여주고, 빼는 건 사람이 결정한다.
   예외는 `hard_excluded` (시승차·커티시카·업무용 / 전 차종 기본장착 품목) 뿐
2. **결정은 원본과 분리한다.** 원본을 다시 읽어도 결정·정정이 살아남는다
3. **리테일러도 라인을 보고 다툴 수 있다.** 신청 → 매니저 승인 → 금액 반영 → 이력

---

## 6. 재사용 블록 (새 정산에서 그대로 쓸 것)

| 하려는 일 | 쓸 것 | 비고 |
|---|---|---|
| 1,000행 넘는 조회 | `sbAll(makeQuery, tag)` | **PostgREST 는 1,000행에서 말없이 자른다** |
| 1,000행 넘는 RPC 결과 | `returns json` 래퍼 함수 | `asap_lines_json` / `asap_saved_lines` 참고 |
| 대량 적재 | `insertRetry(table, rows, label)` | upsert + 재시도 + 배치 반감 |
| 큰 삭제 | 청크 삭제 RPC | `turnover_delete_ym` 류. 안 하면 statement timeout |
| 엑셀 내려받기 | **`xlsxHouse` / `xsSheet`** | 제목·요약칸·산출과정·표·합계·주석 + 숫자 서식. **raw dump 금지** |
| 여러 장 엑셀 | `xsSheet` 로 시트 만들어 `book_append_sheet` | |
| 엑셀 읽기 | `XLSX.read(buf,{type:'array'})` + `xsFixBook` | **`cellDates:true` 금지** (시리얼→Date 가 52초 모자람). 날짜는 `xlDate()` |
| PDF | 팝업 + `window.print()` + `@page A4` | `noticePersonsPdf` / ASAP `openPdf` 참고. **html2canvas·jsPDF 금지** |
| 바우처(결재 엑셀) | `buildVoucherFromTemplate` | JSZip 으로 XML 직접 치환. **ExcelJS 금지 — 파일 손상** |
| 메일 | `sendEmail()` → `email_outbox(PENDING)` | **매니저가 버튼을 눌러야 QUEUED → 맥미니 워커가 발송** |
| 감사 로그 | `logAudit(action, type, id, payload)` | 실패해도 흐름을 막지 않는다 |
| 중복 정산 방지 | `settled_records` + `dedup_keys` | |
| 모델 판정 | `iqm_vehicles` → `resolve_model_code` | **IQM 이 유일한 기준.** 턴오버 모델명은 믿지 않는다 |
| 리테일러 격리 | RLS + `my_retailer()` | **`security definer` 함수를 그냥 열면 전부 샌다** |
| 지점→리테일러 | `asap_branch_retailer(scope, branch)` | JS 에만 있던 규칙을 DB 로 옮긴 것 |

### RLS 함정 (실제로 당한 것)
- UPDATE/DELETE 가 정책에 막히면 **오류 없이 0건**이 돌아온다 → 반드시 `.select('id')` 로
  `data.length` 를 확인한다. 안 하면 "성공했습니다" 라고 거짓말하게 된다
- `security definer` + `grant to authenticated` = 로그인한 누구나 전체 데이터.
  리테일러에게 열 함수는 **함수 안에서 `my_retailer()` 로 잘라야** 한다

### SQL 함정
- `42P13 cannot change return type` → 열을 바꾸려면 `drop function` 먼저
- `42P16 cannot change name of view column` → `drop view` 먼저
- `42P17 generation expression is not immutable` → `date::text` 는 DateStyle 의존. 생성열 대신
  일반 열 + `unique … nulls not distinct`

---

## 7. 새 정산을 만들 때 — 내가 따를 표준

### 7-1. 청구방식 결정 트리

```
Q1. 금액을 JLRK 가 가진 데이터만으로 계산할 수 있나?
    ├ 예 → SYSTEM.  리테일러는 '확인만'.          ← 기본값. 가능하면 무조건 이쪽
    └ 아니오
        Q2. 리테일러만 아는 정보가 필요한가? (현장 사진·고객 사인·외부 비용)
            ├ 예 → UPLOAD.  양식을 포털이 주고 파싱까지 책임진다
            └ 아니오
                Q3. 단순 수량 × 단가인가?
                    ├ 예 → UNIT
                    └ 아니오 → ADMIN_UPLOAD (임시). 다음 분기에 SYSTEM 으로 올릴 계획을 같이 세운다
```

**SYSTEM 을 기본값으로 두는 이유** — ASAP 이 ADMIN_UPLOAD → SYSTEM 으로 옮겨오면서
매니저 수작업이 사라졌고, 리테일러가 라인을 직접 보고 다툴 수 있게 됐다. 같은 전환을
One Care 에도 적용할 수 있는지 먼저 본다.

### 7-2. 검증방식 — 3층으로 나눠 만든다

새 정산의 검증은 **반드시 이 3층으로 쪼개서** 설계한다. 섞으면 매니저가 왜 빠졌는지
설명할 수 없게 된다.

| 층 | 이름 | 성격 | 자동 제외? | 리테일러에게 | 저장 위치 |
|---|---|---|---|---|---|
| 1층 | **규칙 제외** (`hard_excluded`) | 다툴 여지가 없는 규칙 | **O** | 사유와 함께 보여준다. 이의신청 가능 | 산출 함수 안 |
| 2층 | **검토 사유** (`flags`) | 의심스러우니 사람이 봐야 함 | **X** | 매니저가 뺀 뒤에만 보인다 | 산출 함수 안 |
| 3층 | **사람 결정** (`decisions`) | 매니저가 빼거나 살림 + 사유 | — | 사유 그대로 보인다 | 별도 테이블 |

- **1층도 리테일러에게 숨기지 않는다.** 대쉬캠을 조용히 빼뒀다가 지적받았다 —
  "수리로 단 것일 수도 있으니 이의신청할 수 있어야 한다"
- **2층은 절대 자동으로 빼지 않는다.** 사유를 달아 올리고 결정은 사람이 한다
- **3층은 원본과 분리된 테이블.** 원본을 다시 읽어도 살아남아야 한다
- 사유 문구는 **리테일러가 그대로 읽는다는 전제**로 쓴다 — `FY27 Q1 전시차 청구건` 처럼
  분기·근거를 박는다. `규칙 제외` 같은 말은 사유가 아니다

### 7-3. 산출은 회차에 한 번만 — 스냅샷 패턴

```sql
<type>_round_lines (round_id, line_id, retailer_id, …계산결과…, raw json)
<type>_snapshot(round, from, to)   -- 한 번 담는다
<type>_saved_lines(round)          -- 저장분 + 결정/정정을 합쳐서 읽는다
```
- 화면을 열 때마다 원천을 다시 훑으면 **20초씩 걸리고 매번 [계산하기] 를 눌러야 한다**
- 스냅샷에 `retailer_id` 를 박아두면 리테일러 RLS 가 여기서 끝난다
- 원천 파일을 다시 올렸을 때만 다시 담는다 (빨간 버튼 + 확인 + 결정은 보존)

### 7-4. 리테일러 화면 표준 (ASAP 에서 확정된 모양)

```
[＋] 유형명 · 기간                                        [확인 대기 / 확정완료]
     JLR Korea 산출 정산 · 확인만 하시면 됩니다  [공지됨]
     N대 · 확정 기한 YYYY-MM-DD HH:MM
─────────────────────────────────────────────────────────────────
대상 N대 │ 구분A 금액 │ 구분B 금액 │ 정산 금액    [내부 공지용 PDF][엑셀][정산 확정]
─────────────────────────────────────────────────────────────────
[탭A] [탭B]
  지점명                                            N명 · N대 · 금액
    담당자명                                              N대 · 금액
      대상키 | 식별정보… | 금액 | [정정 신청] [이의신청]
        ↳ 빠진 사유
        ↳ (눌러서 펼침) 구성 품목
```
- **카드는 접힌 상태로 시작** (하우스룰)
- **버튼명은 다른 정산과 같게** — 확정은 언제나 `정산 확정`
- **집계 단위를 지급 단위와 일치시킨다** — ASAP 은 차대 단위로 올림하므로 화면도 차대 단위.
  품목·라인은 엑셀에만
- 금액 0인 줄(상계로 지워진 것)은 화면에서 뺀다. 엑셀에는 남긴다
- 신청이 열려 있으면 **확정을 막는다**
- 엑셀은 반드시 `xsSheet` 하우스 서식. **PDF 는 내부 공지용으로 따로**

### 7-5. 새 정산 체크리스트

```
□ settlement_types 행 (code/name/direction/period/claim_unit/amount_mode/
                        source_config.preset/vat_code/budget_category/requires_invoice)
□ 원천 테이블 + 적재 화면 (raw json 포함, 월/분기 재적재 가능)
□ 산출 함수 + 스냅샷 3종 (snapshot / saved_lines / saved_summary)
□ 검증 3층 정의 — 1층 규칙제외 목록 / 2층 검토사유 목록 / 3층 결정 테이블
□ 제외 사유 보기 (asap_config.exclude_reasons 같은 설정값, 분기 치환)
□ 관리자 화면: renderRoundDetail 사다리에 등록 (좁은 조건을 위로)
□ 리테일러 화면: loadRetailerClaims 사다리에 등록 + 7-4 표준 레이아웃
□ 리테일러 신청 경로 (정정 / 이의) + 관리자 처리 화면
□ 엑셀 (xsSheet 2장: 요약 단위 + 라인 단위) · 내부 공지용 PDF
□ 메일 문구 + email_outbox 경유 (자동 발송 금지)
□ RLS 4종 (admin all / retailer select / retailer insert / retailer update-while-OPEN)
□ 운영 SQL 사본을 ~/pa/prod_sql/ 에 번호 붙여 복사
□ 검증서버에서 크롬으로 직접 눌러보고 보고 — grep/node --check 는 검증이 아니다
```

---

## 8. 지금 남아있는 구조적 빚

1. **검증 규칙 엔진 실행부가 없다.** `campaign_rules` 15종 조건 UI 는 있는데 실행이 없다.
   ASAP 의 1/2/3층 모델을 그대로 일반화해서 `rule → flags/hard_excluded` 로 돌리는
   공통 엔진을 만들면 캠페인 3종이 전부 포털 안으로 들어온다
2. **정산마다 화면 코드가 따로다.** `renderXxxRoundDetail` / `renderXxxRetailerCard` 가
   유형마다 복사돼 있다. 7-4 표준 레이아웃을 공통 함수로 빼면 새 정산이 설정 + 산출함수만으로 끝난다
3. **지점 마스터가 불완전하다.** 전시장 18개(AJUH·AJUM·AJUS·CHD·CHG·CHSW·EN·HSU·HSY·HY·JL·
   KCCB·KCCI·KCCS·KCCSP·KCCW·WBG·WBJ) 이름이 없어 코드로 표시된다
4. **차량번호(번호판)가 어느 원천에도 없다.** IQM·Turn Over·Sales Report 전부 열이 없다
5. **메일 워커 운영 전환 미완료** — 맥미니 워커 작업은 끝났고 전환만 보류 중
