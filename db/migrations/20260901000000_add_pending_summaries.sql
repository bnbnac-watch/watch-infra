-- migrate:up
-- 요약(watch-ai) 실패 아이템을 성공할 때까지 발송 보류하기 위한 실패 횟수 추적 테이블.
-- attempts가 MAX_SUMMARY_ATTEMPTS(watch-runner 환경변수)에 도달하면 포기하고
-- 요약 없이 발송한 뒤 이 행을 삭제한다. 성공해도 즉시 삭제한다 — 이 테이블에는
-- "현재 재시도 대기 중"인 아이템만 남아 있어야 한다.
CREATE TABLE IF NOT EXISTS pending_summaries (
    crawler_id  INTEGER NOT NULL REFERENCES crawlers(id),
    item_id     TEXT NOT NULL,
    attempts    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (crawler_id, item_id)
);

-- migrate:down
DROP TABLE IF EXISTS pending_summaries;
