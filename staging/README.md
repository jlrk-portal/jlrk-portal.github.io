# 검증 환경 (staging)

`https://jlrk-portal.github.io/staging/` 로 서빙된다. **운영(`/index.html`)은 건드리지 않는다.**

| | 주소 | Supabase |
|---|---|---|
| 운영 | `jlrk-portal.github.io/` | `yomuvsquaewmfxhfcgao` |
| 검증 | `jlrk-portal.github.io/staging/` | `vrgjpibiecslnxhajinw` |
| 로컬 | `localhost:*` | `vrgjpibiecslnxhajinw` (검증) |

`staging/index.html` 상단 `ENVS` 블록이 **접속 주소로** 운영/검증을 가른다
(`location.hostname` + `location.pathname.startsWith('/staging')`).
검증일 때는 화면 맨 위에 주황색 띠가 깔리고 탭 제목에 `[검증]` 이 붙는다.

## 작업 순서

1. 변경은 **`staging/index.html` 에 먼저** 넣고 `/staging/` 에서 확인한다
2. 유영중 매니저님 확인 후 지시가 있을 때만 루트 `index.html` 로 복사해 운영 반영

```bash
cp staging/index.html index.html   # 운영 반영 (지시 있을 때만)
```

## 검증 DB 안전장치

- 리테일러 수신 메일이 전부 `staging+<code>@jlrk.test` 로 치환되어 있다 (실존하지 않는 도메인)
- `retailers` 에 트리거가 걸려 있어 실주소를 넣어도 자동으로 `.test` 로 되돌린다
- `environment_marker` 테이블에 `STAGING` 표식
- `send-email` Edge Function 에 `MAIL_REDIRECT_TO` 시크릿을 걸면 모든 메일이 그 주소로만 간다 (미적용)

## 테스트 계정

| 역할 | 이메일 | 비고 |
|---|---|---|
| 관리자 | `admin@jlrk.test` | |
| 리테일러 | `aj@jlrk.test` | 아주네트웍스 |
| 리테일러 | `ch@jlrk.test` | 천일오토모빌 |

## 구축 시 발견한 원본 마이그레이션 문제 2건 (운영 저장소 미반영)

1. `000_seed_retailers.sql` 은 `workshops.vendor_code` / `biz_no` 를 쓰는데 그 컬럼은
   `001_invoice_biz_no_rollup.sql` 이 추가한다 → **001 뒤에 실행해야 한다.** README 순서는 틀렸다.
2. `retailers.biz_no` 가 `not null` 인데 시드에 값이 없다 → 지점 시드 후 백필 구문이 필요하다.
