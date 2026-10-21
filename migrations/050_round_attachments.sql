-- ============================================================
--  Migration 050 — 회차 원본 파일 첨부
--
--  매니저가 웅진에서 받은 원본(운영비용 요약·상세, 라이선스 카운트)을
--  회차에 올려두면 증빙 받을 때 같이 내려받는다.
--  [{name, path, size, at}] — path 는 settlements 버킷의 키.
--  파일 자체는 스토리지에 있고 여기엔 목록만 둔다.
-- ============================================================
alter table rounds add column if not exists attachments jsonb not null default '[]'::jsonb;
