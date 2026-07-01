CREATE TABLE crawlers (
    id          TEXT PRIMARY KEY,          -- Docker 서비스명과 일치 (e.g. crawler-woltube)
    name        TEXT NOT NULL,
    schedule    TEXT NOT NULL,             -- cron 표현식 (e.g. "0 9 * * *")
    enabled     BOOLEAN NOT NULL DEFAULT true,
    last_run    TIMESTAMPTZ,
    fail_count  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE seen_items (
    crawler_id  TEXT NOT NULL REFERENCES crawlers(id),
    item_id     TEXT NOT NULL,
    seen_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (crawler_id, item_id)
);

CREATE TABLE destinations (
    id      TEXT PRIMARY KEY,              -- 식별용 이름 (e.g. discord-main)
    type    TEXT NOT NULL,                 -- slack | telegram | discord | webhook
    config  JSONB NOT NULL                 -- {"url": "..."} 또는 {"token": "...", "chat_id": "..."}
);

CREATE TABLE crawler_destinations (
    crawler_id      TEXT NOT NULL REFERENCES crawlers(id),
    destination_id  TEXT NOT NULL REFERENCES destinations(id),
    enabled         BOOLEAN NOT NULL DEFAULT true,
    PRIMARY KEY (crawler_id, destination_id)
);
