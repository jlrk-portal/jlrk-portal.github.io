# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# JLRK 리테일러 정산 포털

JLR Korea가 8개 리테일러(21개 지점)와 주고받는 정산·청구 업무를 대체하는 웹 포털.
기존에는 엑셀 청구서를 메일로 주고받고, 세금계산서 PDF를 수작업으로 캡쳐해 회사 결재 바우처에
붙여넣던 프로세스를 전부 시스템화했다. 담당자 1인(관리자) + 리테일러 8개사 계정 구조.

## 아키텍처 — 반드시 지킬 것

- **빌드 과정 없음.** `index.html` 단일 파일이 전부. React/Vue/번들러 도입 금지 — 지금 방식이 의도된 설계.
- 프론트: GitHub Pages 정적 호스팅 (`index.html`을 그대로 배포)
- 백엔드: Supabase (Postgres + Auth + Storage + Edge Functions), 리전 ap-northeast-2(Seoul)
- 인증/보안: RLS(Row Level Security)로 리테일러 간 데이터 격리. 프론트에 넣는 키는
  `anon`/`publishable` 키뿐 — `service_role` 키는 Edge Function 시크릿에만 존재.
- 라이브러리(CDN): `@supabase/supabase-js`, SheetJS(`xlsx`), `pdf.js`, `JSZip`.
  **ExcelJS·jsPDF·html2canvas는 의도적으로 제거함** (아래 "겪었던 사고" 참고). 다시 추가하지 말 것.

## 저장소 구조

> ⚠️ 이 저장소의 실제 위치는 **`~/icloud/Claude/jlrk-settlement`** (iCloud Drive, 2026-09-27 이전).
> `~/Desktop/jlrk-settlement` 는 심볼릭링크. `.git` 은 iCloud 손상을 피해
> `~/.local/claude-git/jlrk-settlement.git` 에 분리해뒀다 — 구조·주의사항은 `docs/icloud-folder-layout.md`.

```
/index.html                 ← 애플리케이션 전체 (HTML+CSS+JS 단일 파일)
/migrations/                ← 실행 순서대로 정리된 SQL. README.md에 각 파일 설명 있음
/migrations/diagnostics/    ← 스키마 상태 점검용 진단 쿼리
/supabase/functions/        ← Edge Functions (send-email, manage-user)
```

## 명령어 / 로컬 개발

빌드·테스트 러너·패키지 매니저 없음. `npm` 스크립트도 없다.

- **로컬 실행**: 정적 서버로 `index.html`을 열면 끝. `python3 -m http.server 8000` 후
  `http://localhost:8000`. `file://`로 직접 열면 Supabase 인증 리다이렉트가 깨질 수 있으니 서버로 띄울 것.
  별도 개발용 Supabase 프로젝트는 없고 `index.html:723` 상수(`SUPABASE_URL`/`SUPABASE_ANON_KEY`)가
  프로덕션을 가리킨다 — 로컬에서 로그인하면 실데이터에 붙는다는 점 유의.
- **배포**: `main`에 push하면 GitHub Pages가 `index.html`을 그대로 서빙. 파이프라인 없음.
- **Edge Function 배포**: `supabase functions deploy send-email` / `supabase functions deploy manage-user`
  (Supabase CLI 필요, `supabase link`로 프로젝트 연결 후). 시크릿은
  `supabase secrets set GMAIL_USER=... GMAIL_APP_PASSWORD=...` / `... SERVICE_ROLE_KEY=...`.
  로컬 테스트는 `supabase functions serve <name> --env-file .env`.
- **SQL 실행**: `migrations/`는 Supabase SQL Editor에 순서대로 붙여넣어 실행하는 방식(자동 러너 없음).
  스키마 상태 점검은 `migrations/diagnostics/check_migrations_status.sql`를 SQL Editor에서 재실행.
- **바우처 xlsx 검증**: 생성된 파일은 LibreOffice `recalc.py`로 열어 재계산이 깨지지 않는지 확인
  (아래 "겪었던 사고" 1번). 자동 테스트 없으므로 수동 검증이 유일한 안전장치.

## index.html 내부 구조 (단일 파일 SPA)

- **레이아웃**: `<head>`에 CDN 스크립트 4개(`index.html:718~721`) → 인라인 `<style>`(다크 테마 커스텀 프로퍼티)
  → `<body>`에 로그인 화면 + 비밀번호변경 화면 + `<main>` 안에 `<section id="view-*">` 8개
  (`dashboard`/`accounts`/`audit`/`types`/`retailers`/`rounds`/`roundDetail`/`retailer`) → 인라인 `<script>`.
- **라우팅**: 해시 라우터 없음. `switchView(name)`(`index.html:1263`)이 모든 `<section>`을 `display:none`으로
  깔고 `view-<name>` 하나만 켠 뒤, 이름에 맞는 `loadXxx()`를 호출한다. 네비 클릭 → `switchView`.
- **세션/진입**: `checkSession()` → `enterApp(session)`(`index.html:1171`)에서 `profiles` 행을 읽어
  전역 `myProfile`에 저장하고 `role`로 분기 — `ADMIN`이면 `#adminNav` 표시 + `switchView('dashboard')`,
  `RETAILER`면 `retailer-mode` 클래스 + `loadMyRetailerContext()` + `switchView('retailer')`.
  `must_change_password`면 비밀번호 변경 화면으로 강제, `is_active===false`면 로그아웃.
- **전역 상태**(`index.html:726~735`): `sb`(Supabase 클라이언트), `myProfile`, `myRetailer`,
  `myWorkshops`, `selectedRetailerIds`, `currentRoundId`. 프레임워크 없이 이 전역들 + DOM이 상태의 전부.
- **권한**: 프론트 분기는 UX일 뿐 실제 격리는 전부 Postgres RLS. 관리자 전용 서버 작업(계정 생성 등)은
  `sb.functions.invoke('manage-user', ...)`가 Edge Function에서 `role='ADMIN'`을 재검증한다.
- **AP vs AR 회차 상세**: `renderRoundDetail()`(AP) / `renderARRoundDetail()`(AR)로 갈리고,
  `amount_mode`에 따라 다시 `renderSystemSourceSection`(SYSTEM), 업로드/수동 입력 UI 등으로 분기.

## 도메인 핵심 개념

- **정산 방향 2종**: `AP`(JLRK가 리테일러에 지급, 리테일러가 청구서 제출) / `AR`(JLRK가 리테일러에 청구, 리테일러는 확인·이의제기만)
- **청구 단위 vs 계산서 단위가 다름**: `claim_unit`은 정산 유형마다 법인 단위/지점 단위로 갈리지만,
  세금계산서는 **항상 리테일러(법인)×회차 단위로 1건**. vendor code별 배분은 바우처 생성 단계에서 처리.
- **정산 유형(`settlement_types`)이 모든 걸 설정으로 관리**: GL코드, 코스트센터, VAT 코드,
  JG/LR 배분 방식(고정비율 vs 실적기준), 금액 산출 방식(`UPLOAD`/`SYSTEM`/`UNIT`/`MANUAL`),
  원천 파싱 규칙(`source_config` JSON), 중복 판정 키(`dedup_keys`) 등. 새 정산 종류를 추가할 때
  코드를 건드리지 않고 이 설정만으로 커버하는 게 목표.
- **바우처 생성**: 관리자가 실제 결재 원본 엑셀을 템플릿으로 업로드해두면, 생성 시 그 파일의
  특정 셀 값만 바꿔서 내려받는다. 새로 만들지 않는다.
- **기정산 이력(`settled_records`)**: 리테일러 입력 없이 시스템이 원본 데이터를 읽어 자동 정산하는
  유형(`amount_mode='SYSTEM'`)에서, 이미 정산한 건을 정규화된 조합키로 걸러내는 범용 테이블.
  유형마다 `dedup_keys`가 다르므로 조합키 설계 시 "여러 건이 묶이는 컬럼을 단독 키로 쓰지 말 것"
  (예: 참조번호 하나에 쿠폰 여러 장이 물리는 사례로 실제 검증함).

## ⚠️ 겪었던 사고 — 재발 방지

1. **ExcelJS로 기존 xlsx 템플릿을 열었다 재저장하면 파일이 손상된다.**
   externalLinks, printerSettings(인쇄영역 포함), customXml, calcChain 등 원본 부품이
   무더기로 유실됨. 그래서 바우처 생성은 ExcelJS를 아예 쓰지 않고 **JSZip으로 xlsx 내부 XML을
   직접 문자열 치환**하는 방식으로 전환했다 (`buildVoucherFromTemplate` 계열 함수 참고).
   새 값을 넣어야 하는 셀만 정규식으로 찾아 `<c r="I7">...</c>` 형태를 갈아끼우고, 나머지 파츠는
   원본 zip 그대로 둔다. LibreOffice `recalc.py`로 검증하는 습관을 들일 것.
2. **표지 PDF 자동 생성은 포기한 기능이다.** 브라우저에서 엑셀 렌더링을 재현할 방법이 없어
   html2canvas 기반 시도가 4번 실패했다. 인쇄영역만 원본 그대로 보존해두고, 사용자가 엑셀에서
   직접 "다른 이름으로 저장 > PDF"를 누르는 수동 단계로 확정. 다시 자동화 시도하지 말 것.
3. **정의된 이름(defined names)의 외부 참조**(`[숫자]시트` 또는 `[파일명.xls]시트` 형태)가
   원본 템플릿에 남아있으면 재저장 시 손상 원인이 된다. 걸러낼 때 숫자 인덱스뿐 아니라
   대괄호 안에 뭐가 오든 전부 제거해야 한다 (`stripExternalDefinedNames` 참고 — 현재는
   XML 직접 조작 방식으로 넘어가면서 이 이슈 자체가 사라졌지만, 유사 로직 필요 시 기억할 것).

## 코딩 컨벤션

- 주석·UI 텍스트는 전부 한국어.
- 함수명 패턴: `renderXxx`(화면 그리기), `loadXxx`(데이터 조회+렌더), `notifyXxx`(메일 발송),
  `logAudit(action, targetType, targetId, payload)`(감사로그 — 전부 실패해도 조용히 무시).
- 알림(`sendEmail`)과 감사로그는 **실패해도 업무 흐름을 막지 않는다** — try/catch로 감싸고
  console.warn만 남긴다. 이 패턴을 깨지 말 것.
- CSS는 커스텀 프로퍼티 기반 다크 테마(`--bg`, `--surface`, `--accent` 등). 860px 이하 모바일 대응 있음.
- 금액 입력은 전부 천단위 콤마 포맷(`formatAmountInput`/`readAmountInput`), 서버엔 숫자로 저장.

## 진행 상태 (Phase 0~7 전부 1차 완료)

Phase 0 백엔드 → 1 정산유형관리 → 2 회차개설/제출 → 3 검토/확정/계산서 →
4 바우처생성 → 5 이메일알림 → 6 AR청구 → 7 대시보드/감사로그/계정관리/예산관리
전부 기능은 구현됐고 스키마도 프로덕션에 반영 완료 (`migrations/diagnostics/check_migrations_status.sql`로 검증됨).

## 미완료 / 다음에 할 일

> 프로젝트 전체 대화 기록(기획~Phase 7)은 `docs/history.md`에 있음. 설계 배경·수치가 필요하면 거기 참고.

- [x] **Edge Function 배포 완료** (2026-08-30, `npx supabase` 사용)
  - `send-email` ACTIVE v1 — `GMAIL_USER`/`GMAIL_APP_PASSWORD` 시크릿 이미 설정돼 있음
  - `manage-user` ACTIVE v2 — `SERVICE_ROLE_KEY` 없으면 자동 주입되는 `SUPABASE_SERVICE_ROLE_KEY` 사용하도록 수정함
  - 프로젝트 ref: `yomuvsquaewmfxhfcgao`, `supabase/.temp/`는 `.gitignore` 처리됨
- [x] 리테일러 알림 이메일 등록 완료 (2026-09-04, migration 024). 8개사 `retailers.email`
  전부 실주소. AJ·KCC 는 담당자 2명이라 쉼표 구분 저장(`splitEmails()` 로 다중 발송).
  담당자 로그인 계정 10개도 `manage-user` 로 생성함(초기비번 강제변경). 기존 테스트계정
  `chtest@chunilauto.co.kr` / `youngjung.yu@gmail.com` 은 아직 active — 불필요 시 비활성화.
- [x] **Engine Oil Package AP 정산 — 2개 프리셋으로 분리 (2026-09-04).**
  · `ENGINE_OIL_RS` (월 단위): 사용반환금 + Retailer Support. CouponClaim 1개 업로드 → 바우처 **2개 개별 다운로드**
    (`Engine Oil Package_사용반환금_*.xlsx` / `_Retailer Support_*.xlsx`). dedup: 차대번호+참조번호+쿠폰번호.
  · `ENGINE_OIL_SI` (분기 단위): Sales Incentive. 쿠폰북정산내역 업로드 → 바우처 1개. (판매−환불)×10,000, 표지 90:10.
    dedup: **차대번호+쿠폰북ID+유형** (쿠폰북ID는 판매/환불 쌍이 공유 → 유형 필수).
  · `ENGINE_OIL_SP` (월 단위, **방향 AR**): 판매대금. 리테일러가 쿠폰북을 고객에게 팔고 받은 돈을
    JLRK에 입금. 쿠폰북정산내역 업로드 → **지점별** `Σ가격(VAT)` (유형=판매+환불+반품 전부),
    브랜드=차대번호 3번째자리 L→LR. 바우처 1개(지점 customer_code별 행, M=JG/N=LR/I=합계, GL 702030000, VAT A0:0%).
    dedup: 차대번호+쿠폰북ID+유형. `parseEngineOilSalesPayment` + `generateEngineOilSpVoucher`.
    ⚠️ 로우데이터는 날짜로 자르지 말 것 — 미정산 쿠폰북 건 전부 넣고 dedup ∉ settled_records 로 신규만.
  공통: `eoPreset(type)`가 comps/src/ar 를 결정, `parseEngineOilCoupon`/`parseEngineOilSales`(async, dedup 추가) 재사용,
  `renderEngineOilRoundDetail`/`renderEngineOilSection`/`renderEngineOilPreview`/`eo3vBuildBreakdown`(sp 인자)/
  `generateEngineOilVouchers`/`renderEngineOilRetailerCard`가 프리셋별 분기. 리테일러 확인은 회차당 1번. `ENGINE_OIL_3V`는 하위호환용으로 남김.
  바우처 템플릿(`voucher-templates/eo3v-{saveback|support|incentive|salespayment}.xlsx`)은 회차 바우처 생성 화면에서 업로드.
  산출 상수(사용반환금 비율 0.8 / Castrol 21,000 / 인센티브 10,000)는 정산유형 설정폼의
  "시스템 산출 상수" 3필드 → `source_config`(키: `customer_rate`/`castrol_per`/`incentive_unit`),
  비우면 `EO3V` 기본값(`eo3vParams()`).
  - 브랜드 판정: 차대번호 3번째 자리 = `L` → Land Rover, 아니면 Jaguar.
  - ① 사용반환금 GL `702030000` / ② Retailer Support GL `700050800`(VME)+`1105020600`(Castrol), GL 라인 4개 /
    ③ Sales Incentive GL `700050800`, 표지 고정 90:10. VAT 전부 `V0:0%`.
  - dedup_keys: `["차대번호","쿠폰사용 참조번호","쿠폰번호"]` 3개 조합. 정규화 = 공백제거+대문자. 상태필터 `클레임상태=전송`.
  - ⚠️ 실제 원본파일로 E2E 검증은 사용자 몫 (샘플 데이터 `docs/engine-oil-test-scenario.md`).
  - ⚠️ `EO3V.WS_MAP`(원본 지점명→workshop code 24개)은 아직 하드코딩. 브리티시(BA) 항목 포함 — 8개사 밖 딜러
    안 나온다는 전제(사용자 확인). 필요 시 `source_config` 오버라이드로 뺄 것.
- [x] **`amount_mode='UNIT'`(수량×단가) — 1차 완료.** `renderARRoundDetail`의 `isUnit` 경로:
  리테일러별 수량 입력 → `수량 × unit_price` 자동계산(읽기전용) → `saveARClaim`이 `claims.quantity` 저장.
  `charge_unit='PRIMARY'`면 `generateARVoucher`가 대표지점(`workshops.is_primary` + `customer_code`)에 금액 몰빵,
  `brand_jg_ratio` 고정배분 + `vat_code` 적용. 설정폼에 `amount_mode=UNIT`/단가/계상단위 필드 존재.
  (단순 수량×단가 유형용. One DMS 는 아래 별도 프리셋으로 처리.)
- [x] **One DMS License Fee (`source_config.preset='ONE_DMS_AR'`, SYSTEM + 방향 AR) — 1차 완료 (2026-09-04).**
  관리자가 라이선스 로우데이터(1인 1행, 월별 라이선스 종류 칸) 업로드 → 리테일러별 **활성 유저-month**
  (그 달 라이선스 칸 비어있지 않으면 카운트, 분기=앞 3개 월컬럼) 집계 → `Σ유저-month × FY 유저당 월단가`.
  FY 단가맵: `ONE_DMS.FY_RATES` (FY26/27=109,329.6667 등) + `source_config.fy_rates` 오버라이드,
  회차 `fiscal_year`로 자동선택(`FY27`↔`FY26/27` 변환).
  제외: JLRK 본사·브리티시(폐업). VAT 10%, JG:LR 10:90 고정, GL 605030101.
  흐름: DRAFT(업로드·미리보기·공지) → PUBLISHED(리테일러 확인) → FINALIZED → VOUCHERED.
  리테일러 카드/엑셀 다운로드는 **라이선스 종류·단가 미표시** — 유저 명단(이름/ID/역할/첫로그인/재직/퇴직/월별 O·X/사용개월) + 금액만.
  AR 바우처: `ONE_DMS.REP_BRANCH` 대표지점 코드 사용 — ⚠️ 기존 AR 마스터(019)와 CH/HS/HY 코드 다름
  (사용자 확인: One DMS 바우처 코드 KR01048/KR01030/KR01120 사용, 019 값은 안 건드림).
  함수: `parseOneDmsRaw` / `renderOneDmsRoundDetail` / `publishOneDmsRound` / `finalizeOneDmsRound` /
  `generateOneDmsVoucher` / `renderOneDmsRetailerCard` / `downloadOneDmsRetailerXlsx`. DB 스키마 변경 없음.
  - ⚠️ 실데이터 E2E: 파서 로직은 사용자 제공 파일의 `집계` 피벗과 8개사 전부 일치 확인. 실제 회차로 업로드→바우처까지 1회 검증 필요.
  - 유형 생성 시: `amount_mode=SYSTEM`, `direction=AR`, `source_config={"preset":"ONE_DMS_AR"}`, AR 바우처 템플릿 업로드,
    `voucher_lines[0].description`(예: One DMS License Fee), 회차에 `fiscal_year` 세팅.
- [ ] **검증 규칙 엔진** — 사용자가 엑셀로 눈으로 하던 검증을 포털 안에서 자동 실행. 설계만 끝남(`docs/history.md` 3805~3976).
  - 핵심 원칙: **AI는 규칙을 "만들 때만" 사용**, 실제 검증(라인 수천 건)은 결정론적 계산 로직으로 매번 실행.
  - 규칙 JSON 타입: `FORMULA`(계산식 재검증), `RANGE`, `DUPLICATE`(dedup keys), `DATE_RANGE`(기간 이탈),
    `REQUIRED`, `ENUM`, `SUM_MATCH`(raw↔요약 합계). `level`: `ERROR`(제출 차단) / `WARN`(경고만).
  - 입력 방식은 **C안**: 기본은 규칙 빌더 UI(무료), 자연어→규칙 변환은 Anthropic API 키 있으면 활성/없으면 자동 숨김.
    검증 엔진(규칙 실행부)을 먼저 만들고 입력 방식 2갈래를 그 위에 얹음. **API 키 발급 가능 여부 사용자 재확인 필요.**
- [x] GitHub Pages URL 이전 완료 (2026-08-31) — `jlrk-portal` Organization 생성 후 repo 이전 + `jlrk-portal.github.io` 로 이름 변경.
  운영 주소: **https://jlrk-portal.github.io/** (기존 `youngjung-ai.github.io/jlrk-settlement/` 폐기).
  git remote: `github.com/jlrk-portal/jlrk-portal.github.io`. Supabase Auth URL Configuration(Site URL / Redirect URLs)도 새 주소로 교체함.

## 확인해야 할 것 (아직 리스크로 남아있음)

- AJ/EN/HS/WB 리테일러 그룹은 **지점별로 사업자번호가 다르다** (프랜차이즈 개별사업자 구조).
  → 해결(2026-09-01): 세금계산서는 **리테일러당 1장** 유지. 그룹 내 사업자번호가 갈리는 3곳은 대표 지점 기준
  (아주=한남 `2148800795` / 효성=부산센텀 `2548500545` / 위본=광주 `1858502077`). `migration 020`에서 `retailers.biz_no` 시드.
  AR 거래처 코드·사업자번호 보정은 `migration 019`. 상세 `docs/data-crosscheck.md`.
- 여러 정산 원본에서 **JG/LR 코스트센터 라인이 뒤바뀐 실제 회계 오류**를 발견해 사용자에게 보고함
  (Recall 10:90 고정배분 버그, Engine Oil AR/Retailer Support JG/LR 라인 반전 등). 시스템 버그가 아니라
  사용자의 기존 수작업 엑셀에 있던 문제이므로, 코드 수정 대상이 아니라 사용자가 실제 회계와
  크로스체크할 사안. 새로 정산 유형을 만들 때 원본 파일의 계산식을 그대로 믿지 말고 검증할 것.
  - Engine Oil AR: JG `64,666,800`이 LR 라인에, LR `377,155,533`이 JG 라인에 (약 3억 반전).
  - Retailer Support: JG 코스트센터에 LR 금액(VME `40,576,863` 등), LR에 JG 금액. Castrol 라인도 동일.
  - 표지 검증식 `M54=IF(G53=$E$27,...)`이 VAT 세율코드 셀(`$E$27`)을 봄 — `$E$25`(Net)가 맞음. AP·AR 양쪽 템플릿 공통 버그.
- **AR 거래처 코드 체계는 AP와 완전 별개.** AP=vendor code(`KRJD01048`), AR=customer code(`KR01074MIS`).
  `workshops.customer_code`/`ar_biz_no` 컬럼은 있으나 값 미입력 → 리테일러 관리 화면에서 직접 채워야 AR 바우처 생성 가능.
  같은 지점에 파일마다 다른 코드 발견(효성 센텀: DMS `KR01030MIS` vs Engine Oil `KR01170MIS`) — 어느 게 맞는지 확인 필요.
- **AR 대상 범위가 8개사 마스터보다 넓음** — 브리티시·선진·C&D, CH CA 지점 등이 AR 원본에 포함. 포털 등록 여부 미정.
- 세금계산서 발행일 등 회차 기간 밖 데이터가 원본에 섞여 들어오는 사례 있음(P&D 2Q 정산에 3월 건 `51,000`).
  검증 규칙 `DATE_RANGE`로 자동 플래그 대상.
