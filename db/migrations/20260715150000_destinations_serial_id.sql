-- migrate:up
-- destinations.id를 TEXT 슬러그에서 SERIAL로 변경, 기존 슬러그는 name으로 이동.
-- id가 FK로 참조되는 상태에서 슬러그를 바꾸면 FK cascade가 걸려 운영 중 이름 변경이
-- 번거로웠음(예: discord-main을 slack 웹훅으로 용도 변경). id는 안정적인 정수로 두고
-- 사람이 읽는 이름은 name에서 자유롭게 바꿀 수 있게 분리.

ALTER TABLE destinations ADD COLUMN name TEXT;
UPDATE destinations SET name = id;
ALTER TABLE destinations ALTER COLUMN name SET NOT NULL;
ALTER TABLE destinations ADD CONSTRAINT destinations_name_key UNIQUE (name);

ALTER TABLE destinations ADD COLUMN id_new SERIAL;

ALTER TABLE crawler_destinations ADD COLUMN destination_id_new INTEGER;
UPDATE crawler_destinations cd
    SET destination_id_new = d.id_new
    FROM destinations d
    WHERE d.id = cd.destination_id;
ALTER TABLE crawler_destinations ALTER COLUMN destination_id_new SET NOT NULL;

ALTER TABLE crawler_destinations DROP CONSTRAINT crawler_destinations_destination_id_fkey;
ALTER TABLE crawler_destinations DROP CONSTRAINT crawler_destinations_pkey;
ALTER TABLE crawler_destinations DROP COLUMN destination_id;
ALTER TABLE crawler_destinations RENAME COLUMN destination_id_new TO destination_id;

ALTER TABLE destinations DROP CONSTRAINT destinations_pkey;
ALTER TABLE destinations DROP COLUMN id;
ALTER TABLE destinations RENAME COLUMN id_new TO id;
ALTER TABLE destinations ADD PRIMARY KEY (id);

ALTER TABLE crawler_destinations ADD PRIMARY KEY (crawler_id, destination_id);
ALTER TABLE crawler_destinations ADD CONSTRAINT crawler_destinations_destination_id_fkey
    FOREIGN KEY (destination_id) REFERENCES destinations(id);

-- migrate:down
-- name 값을 기준으로 TEXT id를 복원한다. up 이후 name이 다시 바뀐 적 있으면
-- 원래 슬러그가 아니라 "현재 name" 기준으로 복원됨(최선 복원, 완전 원복 보장 아님).

ALTER TABLE crawler_destinations DROP CONSTRAINT crawler_destinations_destination_id_fkey;
ALTER TABLE crawler_destinations DROP CONSTRAINT crawler_destinations_pkey;

ALTER TABLE crawler_destinations ADD COLUMN destination_id_old TEXT;
UPDATE crawler_destinations cd
    SET destination_id_old = d.name
    FROM destinations d
    WHERE d.id = cd.destination_id;
ALTER TABLE crawler_destinations ALTER COLUMN destination_id_old SET NOT NULL;
ALTER TABLE crawler_destinations DROP COLUMN destination_id;
ALTER TABLE crawler_destinations RENAME COLUMN destination_id_old TO destination_id;

ALTER TABLE destinations DROP CONSTRAINT destinations_pkey;
ALTER TABLE destinations ADD COLUMN id_old TEXT;
UPDATE destinations SET id_old = name;
ALTER TABLE destinations DROP COLUMN id;
ALTER TABLE destinations RENAME COLUMN id_old TO id;
ALTER TABLE destinations ADD PRIMARY KEY (id);

ALTER TABLE crawler_destinations ADD PRIMARY KEY (crawler_id, destination_id);
ALTER TABLE crawler_destinations ADD CONSTRAINT crawler_destinations_destination_id_fkey
    FOREIGN KEY (destination_id) REFERENCES destinations(id);

ALTER TABLE destinations DROP CONSTRAINT destinations_name_key;
ALTER TABLE destinations DROP COLUMN name;
