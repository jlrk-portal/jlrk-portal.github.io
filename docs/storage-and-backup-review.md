# 검토 — 용량 모니터링 & 리테일러 파일 백업

> 2026-09-06 검토. **아직 미구현.** 아래 열린 질문 확정 후 착수.

## 1. 지금 용량 현황 (측정치)

| 저장소 | 현재 | 한도 | 사용률 |
|---|---|---|---|
| **GitHub 저장소** | 1.1 MB | 1 GB (Pages 권장) | 0.1 % |
| **Supabase Storage** (`settlements` 버킷) | 4.35 MB · 18개 파일 | Free 1 GB / Pro 100 GB | 0.4 % (Free 기준) |
| **Supabase DB** | 수 KB (거의 비어있음) | Free 500 MB / Pro 8 GB | ~0 % |
| **Supabase Egress**(월 전송량) | 미측정 (대시보드 필요) | Free 5 GB/월 / Pro 250 GB/월 | ? |

- GitHub 최대 blob = `index.html` 리비전 ~365 KB × 50여개 → `.git` 3.4 MB. **비바이너리라 걱정 없음.**
- Storage 4.35 MB 중 대부분이 **과거 테스트 업로드** (한 리테일러 폴더에 14개 3.26 MB, `undefined/` 폴더에 중복 INVOICE PDF 등) + 템플릿 3개(1.2 MB).
- DB `rounds/claims/invoices/vouchers/settled_records` 전부 0행 (테스트분 정리됨). `audit_log` 28행.

## 2. 실서비스 가동 후 증가 추정

- **회차당** ≈ 리테일러 청구파일 8개(50–300 KB) + 세금계산서 PDF 8개(200–400 KB) + 생성 바우처 → **약 3–5 MB/회차**
- 정산유형 7개 × 월/분기 주기 → **연 30–50회차 → Storage 약 150–250 MB/년**
- DB: `settled_records`(Engine Oil SI/SP 회차당 수백 행), `claims.detail` jsonb(One DMS 명단 회차당 20–50 KB), `rounds.source_summary`, `audit_log`(append-only) → **연 10–30 MB/년**
- **Egress가 먼저 닿을 위험**: 리테일러 양식·바우처 다운로드 + 관리자가 바우처 생성할 때마다 템플릿 재다운로드. Free 5 GB/월은 활발히 쓰면 몇 달 안에 근접 가능.

**요약:** Free 플랜 기준 Storage 1 GB는 4–5년, DB 500 MB는 십수 년. **Egress(월 5 GB)가 실질 병목.** Pro면 수년간 무관.

---

## 3. 기능 A — 용량 한도 확인 + 증가 알림

### 옵션
| 안 | 방식 | 장점 | 단점 |
|---|---|---|---|
| **A1. 관리자 대시보드 위젯** | 로그인 시 Storage 합계(`storage.objects` size 합, 관리자 Storage API로 계산) + 주요 테이블 행 수 표시, 임계 넘으면 색 경고 | 인프라 0, index.html 수정만 | 관리자가 접속해야만 보임 (푸시 아님) |
| **A2. `pg_cron` 주간 → send-email** ⭐ | Supabase에 `pg_cron`+`pg_net` 켜고, 주 1회 SQL 함수가 Storage/DB 용량·행수 계산 → 임계 초과 시 `send-email` Edge Function 호출 | 진짜 푸시 알림, 누가 온라인이든 무관 | 마이그레이션 1개 (extension + 함수 + 크론 + 임계·수신주소 설정행) |
| **A3. 맥미니 cron/launchd** | 상시가동 맥미니에서 스크립트가 Storage API + GitHub API + (선택)Supabase 관리 API 조회 → 임계 초과 시 Discord/이메일 | GitHub·Egress 등 외부 지표까지 한 번에, Supabase 관리API로 정확한 egress 확인 가능 | 맥미니 가동에 의존, 스크립트+plist |
| A4. Supabase 관리 API `/v1/projects/{ref}/usage` | egress·DB·storage 실제 대시보드 수치 | 가장 정확(특히 egress) | Supabase Personal Access Token 필요 (A2/A3에 결합해서 씀) |

### 권장
**A2(주간 pg_cron 이메일) + A1(대시보드 위젯) 병행.** GitHub은 알림 불필요 — `.gitignore`에 `*.xlsx *.pdf *.zip` 추가 + (선택) 커밋 전 파일크기 체크 훅으로 충분.

---

## 4. 기능 B — 리테일러 업로드 파일 항상 내 PC(맥미니) 백업

대상 파일: `settlements` 버킷의 `{retailer_id}/{round_id}/{claim_id}-{파일}` (청구서), 세금계산서 PDF, AR 근거자료. (+ 과거 버그로 생긴 `undefined/` 폴더)

### 옵션
| 안 | 방식 | 장점 | 단점 |
|---|---|---|---|
| **B1. 맥미니 증분 동기화 (launchd)** ⭐ | 시간당(또는 일1회) 스크립트: 관리자 로그인 → Storage list(재귀) → `~/jlrk-backup/` 에 없는 파일만 다운로드, `retailer_id`→코드로 폴더명 변환. 멱등(있으면 스킵) | 단순·견고, 상시 맥미니 활용. **서비스키 불필요** (관리자 RLS로 전체 읽기 가능). 맥미니 꺼져도 다음 실행 때 따라잡음 | 실시간 아님(최대 1h/1d 지연) |
| B2. Storage/DB 웹훅 → 맥미니 리스너 | `storage.objects` INSERT 시 `net.http_post`로 맥미니에 알림 → 즉시 다운로드 | 실시간 | **Supabase 클라우드에서 맥미니 Tailscale IP는 못 닿음** → 공인포트 개방 or Cloudflare Tunnel 필요. 노출 위험·복잡. 비권장 |
| B3. `rclone` (S3 프로토콜) | Supabase Storage는 S3 호환. `rclone sync supabase-s3:settlements ~/jlrk-backup` 를 cron | 제일 깔끔, 삭제 미러링·재개 내장 | S3 엔드포인트·액세스키가 플랜/설정에서 활성화돼 있어야 함 (확인 필요) |
| B4. 앱 라운드-아카이브 확장 | 회차 FINALIZED/VOUCHERED 시 자동으로 백업폴더에 저장 (migration 015 흐름 확장) | 회차 단위로 깔끔 | 클라이언트 트리거 = 관리자가 브라우저에 있을 때만 |

### 권장
**B1(맥미니 launchd 증분 동기화, 시간당).** S3 엔드포인트가 켜져 있으면 **B3(rclone)** 로 더 간단히. 백업 폴더 `~/jlrk-backup/` `chmod 700`.
⚠️ 리테일러 세금계산서 등 사업자 데이터가 맥미니에 쌓임 — 관리자 본인 기기라 문제는 아니나 권한·암호화(FileVault) 확인 권장.

---

## 5. 착수 전 확정할 것 (사용자)

1. **Supabase 플랜** — Free / Pro? (대시보드 → Settings → Billing) → 알림 긴급도·egress 중요도 결정
2. **알림 채널** — 이메일(기존 send-email) / Discord 봇 핑 / 둘 다?
3. **임계값** — 한도의 몇 %에서 알림? (예: 60 / 80 / 90 %)
4. **백업 주기** — 시간당 / 일1회? (실시간은 비권장)
5. **백업 범위** — 리테일러 업로드(청구·계산서·근거)만? 아니면 생성 바우처·템플릿까지 전부?
6. **기존 파일 정리** — `undefined/` 폴더 + 과거 테스트 업로드(약 3.3 MB) 삭제할지? (4.35 MB → ~1 MB)
7. **백업 보관 정책** — 영구 보관 / N개월 후 / 서버에서 아카이브되면 로컬만 유지?
8. **S3 엔드포인트** 사용 가능한지 (rclone 경로 여부)
