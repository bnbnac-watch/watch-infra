-- migrate:up
-- watch-ai의 일일 요약 요청 카운터 (RPD 한도 체크용)
-- 2026-07-11 HC4에 수동 CREATE된 상태라 IF NOT EXISTS로 통과시킴
CREATE TABLE IF NOT EXISTS ai_usage (
    date          DATE PRIMARY KEY,
    request_count INTEGER NOT NULL DEFAULT 0
);

-- migrate:down
DROP TABLE IF EXISTS ai_usage;
