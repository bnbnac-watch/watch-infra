-- migrate:up
ALTER TABLE crawlers ADD COLUMN last_error TEXT;

-- migrate:down
ALTER TABLE crawlers DROP COLUMN last_error;
