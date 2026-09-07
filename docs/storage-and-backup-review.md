# 검토 — 용량 모니터링 & 리테일러 파일 백업

> 2026-09-06 최초 검토 · 2026-09-07 사용자 요구 반영 재검토. **아직 미구현.**
>
> ## 2026-09-07 사용자 확정 요구
> - 플랜 = **Supabase Free (Storage 1 GB)**
> - 사진 많은 정산유형은 **리테일러 1곳 제출이 수백 MB** 가능 → 1 GB 금방 참
> - 백업: 리테일러가 **파일 업로드·제출하는 즉시** 맥미니 폴더에 저장
> - 용량 알림: **일 단위**로, 기존 `jlrkccso@gmail.com`(send-email 발신) → `yyoo@jaguarlandrover.com`(회사메일)
>
> → 아래 §3·§4를 이 요구에 맞춰 다시 씀. §5는 좁힌 질문.

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

---

## (재검토) 기능 B — 리테일러 업로드 즉시 맥미니 백업

### 핵심 정정
최초 검토에서 "실시간 = 맥미니를 공인포트로 열어야 해서 비권장"이라 했으나 —
**Supabase Realtime(맥미니가 밖으로 나가는 WebSocket)** 을 쓰면 공인 노출·터널 없이
실시간이 된다. 맥미니가 Supabase로 **outbound** 연결만 하므로 포트포워딩/펀넬 불필요.

### 옵션 (재정리)
| 안 | 방식 | 실시간성 | 노출 | 리테일러 부담 |
|---|---|---|---|---|
| **R4. 맥미니 Realtime 구독** ⭐ | 맥미니 상시 프로세스가 `@supabase/supabase-js` Realtime로 `claims`·`invoices` INSERT/UPDATE 구독(관리자 로그인 → RLS로 전부 보임). `file_path`/`evidence_path` 채워지면 그 객체 즉시 다운로드 → `~/jlrk-backup/{리테일러코드}/{회차}/…`. 재접속 자동. | ~1초 | **없음** (맥미니 → Supabase outbound) | 없음 (업로드 1번) |
| R3. 맥미니 폴링 | 1–2분마다 `storage.objects` 를 created_at 기준 조회 → 새 파일 다운로드 | 1–2분 지연 | 없음 | 없음 |
| R2. Storage 웹훅 → Edge Function → 맥미니 | 업로드 시 Edge Function이 객체를 맥미니 공개 엔드포인트로 스트리밍 | ~수초 | **맥미니 공개 필요**(Tailscale Funnel) | 없음 |
| R1. 브라우저가 맥미니로도 직접 전송 | index.html이 같은 파일을 맥미니에 POST | 즉시 | **맥미니 공개 필요** | **업로드 2번** (수백 MB면 큰 부담) |

**권장: R4** (실시간 + 노출 없음 + 리테일러 부담 없음). 준비물:
- 마이그레이션: `claims`, `invoices` 를 `supabase_realtime` publication에 추가 (1~2줄)
- 맥미니: `~/backup-daemon/` 노드 스크립트 + launchd (부팅 자동시작, 재접속 로직). 관리자 세션(서비스키 불필요).
- R3(폴링)를 **보강용**으로 같이 돌리면 Realtime 놓친 것도 다음 주기에 회수 → 무결성 ↑

### ★ 1 GB 확보 문제 — 백업만으론 공간이 안 빔
실시간 백업은 "복사"일 뿐, Supabase 용량은 그대로다. 사진 많은 유형이면 **정리(삭제)** 가 세트로 필요:

| 정리 시점 | 장점 | 단점 |
|---|---|---|
| **회차가 VOUCHERED/FINALIZED 되면 그 회차 파일 일괄 삭제** ⭐ | 검토·이의제기 중엔 포털에서 파일 계속 열람 가능. migration 015 아카이브 흐름과 동일(다운로드 단계가 백업으로 자동화됨) | 회차 진행 중엔 용량 안 빔 (사진 유형은 한 회차가 1 GB 넘길 수도) |
| 백업 완료 확인 후 N분 뒤 즉시 삭제 | 공간 가장 빨리 확보 | **포털에서 그 파일 못 봄** — 관리자 승인검토/리테일러 재제출 화면에서 사진 다시 못 엶 |
| 삭제 안 함 | 단순 | 1 GB 도달 → 업로드 실패. 수동 정리 필요 |

→ 사진 유형이 정말 회차당 1 GB를 넘길 수 있으면 "즉시 삭제"까지 가야 하고,
그러면 **포털 검토 UI가 백업본(맥미니)에서 파일을 다시 받아 보여주는 경로**가 필요해짐(맥미니 공개 엔드포인트 = 노출 재등장).
→ 현실적 절충: **유형별로 "제출 즉시 서버 삭제" 플래그**. 사진 유형만 켜고, 그 유형은 리테일러가
제출 전 미리보기까지만 하고 제출 후엔 포털에서 파일 열람 불가(백업본이 원본). 나머지 유형은 회차 종료 시 삭제.

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

## (재검토) 기능 A — 일 단위 용량 알림 이메일

- **권장: `pg_cron` 일 1회** — SQL 함수가 Storage 바이트(Σ `storage.objects` metadata size) +
  `pg_database_size()` 계산 → 1 GB / 500 MB 대비 % → `net.http_post` 로 `send-email` Edge Function 호출
  → `jlrkccso@gmail.com` 발신, `yyoo@jaguarlandrover.com` 수신.
  - `pg_cron`·`pg_net` 은 **Free 플랜도 사용 가능**. 마이그레이션 1개(extension + 함수 + 크론 + 임계 설정행).
  - ⚠️ Free 프로젝트는 7일 무활동 시 일시정지 → 크론 멈춤. 매일 리테일러 활동 + 이 메일 자체가 활동이라 실사용 중엔 문제없음.
  - **Egress(월 5 GB, Free의 또 다른 한도)는 DB에 없음** → 이 메일은 Storage+DB만. Egress는 대시보드 수동 확인,
    또는 Supabase Management API(개인 액세스 토큰 발급 시) 추가.
- 대안: 백업 데몬이 어차피 맥미니에 상주하므로, 같은 launchd에 일일 용량조회+send-email 호출을 얹기. 한 군데서 운영. 맥미니 가동 의존.
- **메일 내용안**: 날짜 / Storage 사용 X MB (Y %) / DB 사용 X MB (Y %) / 파일 수 / 상위 폴더 / (이력 쌓이면) "현 추세로 며칠 후 만충".

---

## 4. 착수 전 확정할 것 (좁힌 질문)

1. **백업 데몬 실행 방식** — launchd 서비스(재부팅 자동, 백그라운드) vs screen 창(수동 재시작)? → launchd 권장
2. **서버 정리(삭제) 시점** — ⓐ회차 종료 시 일괄 vs ⓑ백업 확인 후 즉시(공간 최속, 단 포털에서 파일 열람 불가) vs ⓒ삭제 안 함(1 GB 도달 감수).
   사진 많은 유형이 정말 회차당 1 GB 넘을 수 있으면 ⓑ 또는 "유형별 즉시삭제 플래그" 필요.
3. **삭제 시 포털 표시** — "서버 정리됨 · 백업본 있음" 상태를 화면에 보일지, 조용히 할지.
4. **일일 이메일 발신 주체** — pg_cron(Supabase) vs 맥미니 launchd?
5. **Egress도 알림에 포함?** — 포함하려면 Supabase Management API 개인 액세스 토큰 발급 필요(님이).
6. **백업 폴더** — `~/jlrk-backup/` 로 할지, 수년치 수백 GB 대비해 **외장드라이브/NAS** 로 둘지.
7. **기존 파일 정리** — `undefined/` 폴더 + 과거 테스트 업로드(약 3.3 MB) 지금 삭제할지.
8. **S3 엔드포인트** 사용 가능 여부 (가능하면 rclone 로 폴링·정리 더 단순).
