# 마이그레이션 인덱스

이미 프로덕션 Supabase에 전부 반영 완료 상태 (2026-08-30 기준, `diagnostics/check_migrations_status.sql`로 검증함).
**새로 실행할 필요 없음** — 이 폴더는 스키마 변경 이력 기록용. 신규 환경을 처음부터 구축할 때만 순서대로 실행.

| 파일 | 내용 |
|---|---|
| `000_schema.sql` | Phase 0 기반 스키마 — 테이블 13개, RLS, 트리거, 헬퍼 함수(`is_admin()` 등) |
| `000_seed_retailers.sql` | 리테일러 8개사 + 지점 21개 시드 데이터 |
| `001_invoice_biz_no_rollup.sql` | (히스토리) 세금계산서 롤업을 biz_no 단위로 — 이후 006에서 리테일러 단위로 되돌림 |
| `002_claim_file_storage.sql` | 청구서 파일 업로드 지원 (`claims.file_path` + Storage RLS) |
| `003_reject_resubmit_rls.sql` | 반송된 건은 회차 마감 후에도 재제출 허용 |
| `004_admin_storage_write.sql` | 관리자가 리테일러 폴더에 첨부파일 업로드 가능하도록 |
| `005_invoice_insert_policy.sql` | (히스토리) biz_no 기준 invoice insert 정책 |
| `006_invoice_retailer_unit.sql` | **세금계산서를 리테일러×회차 단위 1건으로 최종 확정** (biz_no 기준 폐기) |
| `009_voucher_template_fields.sql` | 바우처 템플릿 업로드, `workshops.is_primary`, `vouchers.retailer_id` nullable |
| `010_invoice_issue_date.sql` | 관리자가 지정하는 세금계산서 발행일 |
| `011_admin_notify_email.sql` | 관리자 알림 수신 이메일 |
| `012_ar_workflow.sql` | AR(JLRK→리테일러 청구) 워크플로우 — dispute enum 정리, 확인/근거 필드 |
| `013_ar_settlement_structure.sql` | AR 정산 유형 설정 (VAT코드/브랜드배분/원천파싱/customer_code) |
| `014_audit_log_permissions.sql` | 감사로그 기록 권한, profiles 관리자 조회 |
| `015_round_archive.sql` | 회차 아카이브 (파일 삭제 권한, 최종 요약 보존) |
| `016_account_management.sql` | 계정 관리 (초기 비밀번호 변경 강제) |
| `017_budget_management.sql` | 예산 구분(P&A Selling/VME/FMI/Accrual), 주기 확장(연간/상시) |
| `018_dedup_settled_records.sql` | 범용 기정산 이력 (`settled_records`) — 시스템 산출 정산의 중복 방지 |
| `019_ar_customer_master.sql` | AR 거래처 코드·사업자번호 보정 (customer_code) |
| `020_retailer_representative_bizno.sql` | 그룹 내 사업자번호 분기 리테일러(AJ·HS·WB) 대표지점 biz_no 시드 |
| `021_form_template_storage_read.sql` | 리테일러가 청구서 양식(form-templates/) 다운로드하도록 Storage 읽기 허용 |
| `022_rls_anon_lockdown.sql` | **보안 보완** — `settlement_types`·`rounds` 익명 SELECT 차단, `rounds` 는 참여 리테일러사만(`has_claim_in_round`). 2026-09-04 점검 대응 |
| `023_settlement_types_accounting_lockdown.sql` | **보안 보완** — `settlement_types` 직접 SELECT 관리자 전용, 리테일러는 안전 컬럼만 담긴 `settlement_types_public` 뷰로. GL코드·배분비율·단가 등 회계 컬럼 차단. index.html 리테일러 3경로 동시 변경 |
| `024_retailer_notify_emails.sql` | 리테일러 8개사 알림 수신 이메일(`retailers.email`) 등록. 담당자 2명(AJ·KCC)은 쉼표 구분. index.html `splitEmails()` 로 다중 수신 |
| `025_inventory.sql` | 마케팅 제작물/기프트 재고 관리 — `mkt_items`(품목군+브랜드) / `mkt_txns`(입고·배부·회수·이동·조정) / `mkt_stock` 뷰. 창고 PDC·지하 2곳, 보관위치 자유입력. RLS 관리자 전용(`is_admin()`). index.html `재고 관리` 메뉴 |
| `026_inventory_hq_warehouse.sql` | 재고 관리 창고에 `본사`(HQ) 추가 — `mkt_txns.warehouse`/`to_warehouse` CHECK 제약 확장 |
| `027_legacy_settlement_history.sql` | **포털 도입 전 청구이력** — `legacy_settlements` 테이블. 1행 = (기간 × 지점 × 항목), `item` = SP(판매대금·AR) / SAVEBACK(사용반환금) / SUPPORT(JLRK 기여금) / INCENTIVE. 워크플로 없는 읽기전용 기록이라 rounds·claims 와 분리. RLS: 관리자 전체 + 리테일러 자기 법인만, 익명 차단 |
| `028_legacy_engine_oil_seed_1~7.sql` | Engine Oil Package 과거 정산 **555행 시드** (FY26 Q3 ~ FY27 Q2 7월). master 9종 + 실제 발행 AP/AR 바우처에서 추출, 27개 기간×항목 합계가 바우처 금액과 100% 일치 검증됨. ⚠️ `027` 먼저, 그다음 **1~7번 순서대로**. SQL Editor 가 약 50KB 에서 입력을 자르기 때문에(→ `unterminated quoted string`) 7개로 분할함. FK 연결 update + 검증 select 는 7번 파일에 있음. 재실행 시 1번 파일 상단 `delete` 주석 해제 |
| `029_legacy_pickup_delivery_seed_1~2.sql` | Pick up & Delivery 과거 정산 **112행 시드** (FY26 Q1 ~ FY27 Q1, 분기 5회, AP·VAT 10%). 각 분기 내역서의 `JLRK 전체리스트` 원본 로우데이터를 지점별 집계 → 5개 분기 × 리테일러 9개사 전부 실제 AP 바우처 금액과 원 단위 일치 검증. 마지막 파일에서 `settlement_types` 의 실제 Pick up & Delivery 유형 코드로 `type_code` 를 자동 교정한다. ⚠️ `027` 먼저, 1→2 순서 |

## ⚠️ 알아둘 것

- `001`과 `005`는 나중에 `006`으로 **설계가 뒤집힌 히스토리**임. 006이 최종 상태.
- `007`, `008`은 스키마 변경이 없는 순수 진단 쿼리라 `diagnostics/`로 분리했음.
- `diagnostics/check_migrations_status.sql`은 언제든 재실행해서 스키마 상태를 점검할 수 있는 상시 도구.
- `diagnostics/diag_rls_anon_exposure.sql` — 익명/리테일러 역할의 테이블 노출 점검. `022` 적용 후 재실행해 검증.
- `028` 시드의 예외 1건: `FY26 Q4 2603 master` 의 좌측 판매대금 표가 나중에 4월 데이터로
  덮여 있었다(2604 와 지점별 금액 완전 동일). 같은 파일 우측 브랜드 피벗은 3월 데이터가
  남아있고 합계가 실제 3월 AR 바우처(503,837,400)와 일치하므로 3월 AR 은 그쪽 기준으로 넣었다.
- `029`(P&D) 금액 규칙은 분기마다 다르다: FY26 Q1·Q2·Q3 / FY27 Q1 은 `JLRK청구` 중
  `데이터 검증 = O` 인 건만, **FY26 Q4 는 `최종정산금액` 컬럼(전체 행)**. 이게 각 분기
  바우처 금액과 일치하는 조합이다.
- `029` One Care 분해는 FY26 Q2 만 바우처와 불일치(그 분기 분류 기준이 달랐음)라서
  Q2 행에는 normal/onecare 를 넣지 않았다. 브랜드(JG/LR) 는 원본에 Brand 컬럼이 있는
  FY26 Q2·Q4 / FY27 Q1 만 채웠다.
- `028` 에는 포털 미등록 지점도 들어있다 — 천안(`CH CA`), 브리티시 평촌(`BA PC`, 폐업).
  `workshop_code`/`retailer_id` 가 null 이라 관리자 화면에서만 보인다.

## 후속 보안 과제

- ~~`settlement_types` 회계 컬럼이 로그인 리테일러사에게 노출~~ → `023` 에서 해결
  (직접 SELECT 관리자 전용 + `settlement_types_public` 뷰).
- `rounds` 교차 열람은 `022` 로 정책상 차단됐으나, 실제 회차 데이터가 들어간 뒤
  리테일러 계정으로 한 번 더 검증할 것 (점검 시점엔 테스트 회차가 비어 있었음).
