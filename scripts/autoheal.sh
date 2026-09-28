#!/usr/bin/env bash
# unhealthy 상태인 컨테이너를 찾아 재시작한다.
# healthcheck가 stat() 기반이라, NFS stale file handle처럼 "프로세스는 살아있지만
# 실제로는 고장난" 상태(2026-09-28 밥플러스 그리드 이미지 인시던트)를 잡아낸다.
# 컨테이너 이름을 하드코딩하지 않고 health=unhealthy 필터로 동적으로 찾으므로,
# 나중에 다른 서비스에 healthcheck를 추가해도 이 스크립트는 그대로 쓸 수 있다.
# label=com.docker.compose.project=watch-infra로 이 compose 프로젝트 소속 컨테이너만
# 대상으로 한다 - 같은 N2+ 호스트에서 도는 남남 컨테이너(honeymoon-note-app 등, 이미
# 자체 헬스체크로 unhealthy인 경우가 있음)까지 건드리지 않기 위함.
set -euo pipefail

PROJECT=watch-infra

for cid in $(docker ps --filter health=unhealthy --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.ID}}'); do
  name=$(docker inspect --format '{{.Name}}' "$cid" | sed 's#^/##')
  logger -t docker-autoheal "unhealthy 컨테이너 감지: ${name} (${cid}) - 재시작"
  docker restart "$cid" || logger -t docker-autoheal "재시작 실패: ${name} (${cid})"
done
