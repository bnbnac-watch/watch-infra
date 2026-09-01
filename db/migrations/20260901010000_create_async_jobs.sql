-- migrate:up
CREATE TABLE async_jobs (
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
CREATE INDEX async_jobs_kind_status_created_idx
    ON async_jobs (kind, status, created_at);

-- migrate:down
DROP TABLE async_jobs;
