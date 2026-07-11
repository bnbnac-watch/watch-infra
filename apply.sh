#!/bin/bash
set -e
cd "$(dirname "$0")"

# .env의 DATABASE_URL을 dbmate에 전달
set -a; source .env; set +a

# 스키마 마이그레이션: db/migrations/ 중 미적용분만 순서대로 적용
# (적용 이력은 대상 DB의 schema_migrations 테이블에 기록됨)
# HC4 Postgres가 SSL 미사용이면 DATABASE_URL에 ?sslmode=disable 필요
docker run --rm \
  -v "$PWD/db:/db" \
  -e DATABASE_URL \
  -e DBMATE_NO_DUMP_SCHEMA=true \
  amacneil/dbmate:2 up

docker compose up -d
