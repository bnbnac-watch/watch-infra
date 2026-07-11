-- migrate:up
-- 기존 운영 DB에 이미 존재하는 테이블 (IF NOT EXISTS로 신규/기존 DB 모두 통과)

CREATE TABLE IF NOT EXISTS crawlers (
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    schedule     TEXT NOT NULL,            -- cron 표현식 (KST 기준)
    enabled      BOOLEAN NOT NULL DEFAULT true,
    last_run     TIMESTAMPTZ,
    fail_count   INTEGER NOT NULL DEFAULT 0,
    container    TEXT NOT NULL,            -- Docker 서비스 이름 (http://{container}:8080/crawl)
    params       JSONB,                    -- 크롤러 컨테이너에 POST body로 전달할 파라미터
    filter       JSONB,                    -- null 또는 {"title_keywords": ["단어", ...]} (매칭 아이템만 알림 대상)
    post_process JSONB,                    -- null 또는 {"type": "summarize", "provider": "gemini"}
    batch_group  TEXT                      -- null이면 독립 job, 값이 있으면 해당 batch job에서 처리
);

CREATE TABLE IF NOT EXISTS seen_items (
    crawler_id  INTEGER NOT NULL REFERENCES crawlers(id),
    item_id     TEXT NOT NULL,
    seen_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (crawler_id, item_id)
);

CREATE TABLE IF NOT EXISTS destinations (
    id      TEXT PRIMARY KEY,              -- 식별용 이름 (e.g. discord-main)
    type    TEXT NOT NULL,                 -- slack | telegram | discord | webhook
    config  JSONB NOT NULL                 -- {"url": "..."} 또는 {"token": "...", "chat_id": "..."}
);

CREATE TABLE IF NOT EXISTS crawler_destinations (
    crawler_id      INTEGER NOT NULL REFERENCES crawlers(id),
    destination_id  TEXT NOT NULL REFERENCES destinations(id),
    enabled         BOOLEAN NOT NULL DEFAULT true,
    PRIMARY KEY (crawler_id, destination_id)
);

-- migrate:down
DROP TABLE IF EXISTS crawler_destinations;
DROP TABLE IF EXISTS destinations;
DROP TABLE IF EXISTS seen_items;
DROP TABLE IF EXISTS crawlers;
