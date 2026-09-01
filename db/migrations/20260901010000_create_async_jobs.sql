-- migrate:up
CREATE TABLE IF NOT EXISTS async_jobs (
    id          uuid PRIMARY KEY,
    kind        text NOT NULL,
    payload     jsonb NOT NULL,
    status      text NOT NULL DEFAULT 'pending',  -- pending | done | failed
    result      jsonb,
    error       text,
    retryable   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz
);
CREATE INDEX async_jobs_status_created_idx
    ON async_jobs (status, created_at);

-- migrate:down
DROP TABLE IF EXISTS async_jobs;
