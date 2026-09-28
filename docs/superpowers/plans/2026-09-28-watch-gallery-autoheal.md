# watch-gallery Autoheal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `watch-gallery`/`watch-gallery-nginx`가 "컨테이너는 안 죽었지만 NFS 마운트가 stale이라 실제로는 고장난" 상태에 빠졌을 때(2026-09-28 발생, 밥플러스 그리드 이미지 알림 누락/미리보기 실패 사건 원인), 사람이 로그를 뒤져 수동으로 `docker restart` 하지 않아도 자동 복구되게 한다.

**Architecture:** 두 서비스에 Docker `healthcheck`를 추가해 stale file handle을 실제로 감지하게 만들고(현재는 프로세스가 죽지 않으므로 `restart: unless-stopped`가 전혀 발동하지 않음), 호스트(192.168.1.10)에 별도의 systemd timer + oneshot 스크립트를 둬서 `docker ps --filter health=unhealthy`로 잡히는 컨테이너를 주기적으로 재시작한다. `docker.sock`을 공유하는 별도 컨테이너(autoheal 사이드카) 방식은 쓰지 않는다 — 호스트 systemd 쪽이 신뢰 범위가 더 좁다는 게 사용자 결정.

**Tech Stack:** Docker Compose healthcheck, POSIX shell, systemd (service + timer). 이 조직 관례상 인프라 레포에 테스트 프레임워크가 없으므로(watch-admin 계획 문서에도 명시된 기존 컨벤션), 각 태스크의 검증은 pytest가 아니라 문법 체크 + 실제 배포 후 관찰로 대체한다.

**Spec:** 별도 스펙 문서 없음 — 이 계획 자체가 2026-09-28 인시던트 대화에서 도출된 요구사항을 담는다 (아래 Global Constraints가 스펙 역할).

## Global Constraints

- healthcheck의 `test`는 이번에 실제로 터진 실패 모드(`OSError: [Errno 116] Stale file handle`)를 그대로 재현해서 잡아야 한다 — 단순 프로세스 생존 체크(`curl /health` 등)로는 이 버그를 못 잡는다. `stat()`을 호출하는 명령이어야 한다.
- `docker.sock`을 마운트하는 추가 컨테이너(예: `willfarrell/autoheal`)는 쓰지 않는다 — 호스트 신뢰 범위를 넓히지 않기 위해 사용자가 명시적으로 배제(B안 선택).
- 자동 재시작 대상은 하드코딩된 컨테이너 이름 목록이 아니라 `docker ps --filter health=unhealthy`로 동적으로 찾는다 — 나중에 다른 서비스에 healthcheck를 추가해도 스크립트 수정이 필요 없게.
- 배포는 이 레포의 기존 파이프라인(`.github/workflows/deploy.yml` → `git pull` → `apply.sh` → `docker compose up -d`)을 그대로 타야 한다. `apply.sh`가 `$HOME/watch-infra`(= 레포 루트)에서 실행된다는 전제([apply.sh:3](../../../apply.sh)의 `cd "$(dirname "$0")"`)는 유지.
- systemd 유닛의 `ExecStart` 경로는 하드코딩된 절대경로(`/home/bnbnac/...`) 대신 `User=`+`%h` specifier로 홈 디렉토리를 참조한다 — 나중에 다른 유저/경로로 옮겨도 유닛 파일을 안 고쳐도 되게.
- `docker restart`를 실행하는 systemd 유닛의 `User=`는 `docker` 그룹에 속한 기존 운영 유저(`bnbnac`)를 그대로 쓴다 — 이미 이 유저가 sudo 없이 `docker ps`/`docker logs`를 실행하고 있는 게 확인됨(2026-09-28 인시던트 대응 중 터미널 출력으로 확인).
- `apply.sh`에 추가하는 systemd 설치 스텝은 `sudo`가 필요하다. self-hosted CI 러너 유저가 passwordless sudo를 쓸 수 있는지 **아직 확인 안 됨** — Task 4의 첫 스텝이 이 확인이다. 안 되면 그 태스크만 사용자가 수동으로 1회 설치.

---

## Task 1: docker-compose.yml에 healthcheck 추가

**Files:**
- Modify: `docker-compose.yml:99-117` (`watch-gallery-nginx`, `watch-gallery` 서비스 블록)

**Interfaces:**
- Produces: 두 서비스 모두 `docker inspect --format='{{.State.Health.Status}}' <container>`로 `healthy`/`unhealthy`/`starting` 상태를 조회 가능해짐. Task 2의 autoheal 스크립트가 이 상태를 전제로 동작한다.

- [ ] **Step 1: `watch-gallery-nginx`에 healthcheck 추가**

`docker-compose.yml`의 `watch-gallery-nginx` 서비스를 다음과 같이 수정한다 (기존 `ports`/`volumes` 사이 또는 뒤에 삽입):

```yaml
  watch-gallery-nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "8000:80"
    volumes:
      - /mnt/nfs/temp/watch-gallery:/usr/share/nginx/html:ro
    healthcheck:
      # NFS stale file handle이면 stat()이 실패해서 `test -d`가 non-zero를
      # 반환한다 (2026-09-28 인시던트에서 실제로 발생한 실패 모드).
      test: ["CMD-SHELL", "test -d /usr/share/nginx/html || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 20s
```

- [ ] **Step 2: `watch-gallery`에 healthcheck 추가**

`watch-gallery` 서비스에 동일한 방식으로 추가한다:

```yaml
  watch-gallery:
    image: watch-gallery
    restart: unless-stopped
    init: true
    user: "10002:10002"
    environment:
      - PUBLIC_DOMAIN=${WATCH_GALLERY_DOMAIN:-bnbnac2.duckdns.org}
      - RETENTION_SECONDS=${WATCH_GALLERY_RETENTION_SECONDS:-259200}
      - SERVE_DIR=/serve
    volumes:
      - /mnt/nfs/temp/watch-gallery:/serve
    healthcheck:
      # watch-gallery-nginx와 같은 이유로 SERVE_DIR(/serve)의 stat()을 확인한다.
      test: ["CMD", "python", "-c", "import pathlib,sys; sys.exit(0 if pathlib.Path('/serve').is_dir() else 1)"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 20s
```

- [ ] **Step 3: YAML 문법 검증**

로컬에는 docker가 없을 수 있으니 Python으로 최소 문법만 확인한다:

Run: `python -c "import yaml; yaml.safe_load(open('docker-compose.yml'))" && echo OK`
Expected: `OK`

호스트(192.168.1.10)에 배포된 뒤에는 다음으로 실제 검증:

Run: `docker compose config --quiet && echo OK`
Expected: `OK` (문법/변수 치환 오류 없음)

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: watch-gallery/nginx에 NFS stale handle 감지 healthcheck 추가"
```

---

## Task 2: autoheal 스크립트 작성

**Files:**
- Create: `scripts/autoheal.sh`

**Interfaces:**
- Consumes: Task 1에서 추가된 healthcheck (컨테이너가 `unhealthy` 상태가 될 수 있어야 이 스크립트가 의미 있음).
- Produces: `scripts/autoheal.sh` — Task 3의 systemd service가 `ExecStart`로 호출하는 대상.

- [ ] **Step 1: 스크립트 작성**

```bash
#!/usr/bin/env bash
# unhealthy 상태인 컨테이너를 찾아 재시작한다.
# healthcheck가 stat() 기반이라, NFS stale file handle처럼 "프로세스는 살아있지만
# 실제로는 고장난" 상태(2026-09-28 밥플러스 그리드 이미지 인시던트)를 잡아낸다.
# 컨테이너 이름을 하드코딩하지 않고 health=unhealthy 필터로 동적으로 찾으므로,
# 나중에 다른 서비스에 healthcheck를 추가해도 이 스크립트는 그대로 쓸 수 있다.
set -euo pipefail

for cid in $(docker ps --filter health=unhealthy --format '{{.ID}}'); do
  name=$(docker inspect --format '{{.Name}}' "$cid" | sed 's#^/##')
  logger -t docker-autoheal "unhealthy 컨테이너 감지: ${name} (${cid}) - 재시작"
  docker restart "$cid"
done
```

- [ ] **Step 2: 실행 권한 부여**

Run: `chmod +x scripts/autoheal.sh`

- [ ] **Step 3: 문법 검증**

Run: `bash -n scripts/autoheal.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: (호스트에서) 동작 확인**

배포 후 아무 unhealthy 컨테이너 없는 상태에서 직접 실행해도 안전한지 확인:

Run: `bash scripts/autoheal.sh; echo "exit=$?"`
Expected: `exit=0`, 출력 없음 (unhealthy 컨테이너가 없으므로 루프가 그냥 안 돎)

- [ ] **Step 5: Commit**

```bash
git add scripts/autoheal.sh
git commit -m "feat: unhealthy 컨테이너 자동 재시작 스크립트 추가"
```

---

## Task 3: systemd service + timer 유닛 작성

**Files:**
- Create: `systemd/docker-autoheal.service`
- Create: `systemd/docker-autoheal.timer`

**Interfaces:**
- Consumes: `scripts/autoheal.sh` (Task 2), `User=bnbnac`가 `docker` 그룹에 속해 `docker restart`를 sudo 없이 실행 가능하다는 전제.
- Produces: `docker-autoheal.timer` 유닛 이름 — Task 4의 `apply.sh`가 `systemctl enable --now docker-autoheal.timer`로 활성화하는 대상.

- [ ] **Step 1: service 유닛 작성**

```ini
# systemd/docker-autoheal.service
[Unit]
Description=Restart unhealthy Docker containers (watch-infra)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=bnbnac
ExecStart=%h/watch-infra/scripts/autoheal.sh
```

- [ ] **Step 2: timer 유닛 작성**

```ini
# systemd/docker-autoheal.timer
[Unit]
Description=Run docker-autoheal.service every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=docker-autoheal.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: (호스트에서) 문법 검증**

Run: `systemd-analyze verify systemd/docker-autoheal.service systemd/docker-autoheal.timer`
Expected: 출력 없음(경고/에러 없음). `%h` specifier는 유닛이 실제로 설치되고 `User=`가 있어야 완전히 검증되므로, 여기서 안 잡히는 문제는 Task 4 Step 4에서 다시 확인.

- [ ] **Step 4: Commit**

```bash
git add systemd/docker-autoheal.service systemd/docker-autoheal.timer
git commit -m "feat: docker-autoheal systemd timer 유닛 추가"
```

---

## Task 4: apply.sh에 systemd 유닛 설치 스텝 추가

**Files:**
- Modify: `apply.sh`

**Interfaces:**
- Consumes: `systemd/docker-autoheal.service`, `systemd/docker-autoheal.timer` (Task 3).

- [ ] **Step 1: (호스트에서) self-hosted 러너 유저의 sudo 권한 확인**

Run: `sudo -n true && echo "passwordless sudo OK" || echo "NEEDS PASSWORD"`
Expected: `passwordless sudo OK`. `NEEDS PASSWORD`가 나오면 이 태스크의 자동화(Step 2)는 CI 파이프라인에서 실패한다 — 이 경우 systemd 유닛 설치만 사용자가 수동으로 1회 실행하고, `apply.sh`에는 이 스텝을 추가하지 않는다 (아래 Step 2는 건너뜀).

- [ ] **Step 2: `apply.sh`에 설치 스텝 추가**

`docker compose up -d` 다음 줄에 추가:

```bash
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

# unhealthy 컨테이너 자동 재시작 (NFS stale handle 등으로 컨테이너는 안 죽었지만
# 실제로는 고장난 상태를 감지 - 2026-09-28 인시던트 대응)
sudo install -m 644 systemd/docker-autoheal.service /etc/systemd/system/docker-autoheal.service
sudo install -m 644 systemd/docker-autoheal.timer /etc/systemd/system/docker-autoheal.timer
sudo systemctl daemon-reload
sudo systemctl enable --now docker-autoheal.timer
```

- [ ] **Step 3: 문법 검증**

Run: `bash -n apply.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: (호스트에서) 실제 배포 + 동작 확인**

배포(`git pull` + `bash apply.sh`, 또는 main에 push해서 CI가 돌게) 후:

Run: `systemctl status docker-autoheal.timer --no-pager`
Expected: `Active: active (waiting)`, `Trigger:` 필드에 5분 이내 다음 실행 시각 표시

Run: `docker inspect --format='{{.State.Health.Status}}' watch-infra-watch-gallery-1 watch-infra-watch-gallery-nginx-1`
Expected: 둘 다 `healthy` (배포 시점에 재생성됐으므로 stale 문제도 같이 해소됨)

- [ ] **Step 5: Commit**

```bash
git add apply.sh
git commit -m "feat: apply.sh에 docker-autoheal timer 설치 스텝 추가"
```

---

## Task 5: README에 문서화

**Files:**
- Modify: `README.md`

**Interfaces:**
- 없음 (문서 전용 태스크)

- [ ] **Step 1: README에 섹션 추가**

`README.md`의 적절한 위치(다른 운영/장애 대응 섹션 근처)에 추가:

```markdown
## Autoheal (unhealthy 컨테이너 자동 재시작)

`watch-gallery`, `watch-gallery-nginx`는 `/mnt/nfs/temp/watch-gallery`(HC4가 export하는 NFS)에
의존한다. HC4가 재부팅되면 NFS 서버가 내려갔다 올라오는데, **이미 떠 있던 컨테이너는 그 시점의
파일 핸들을 그대로 캐시하고 있어서 호스트의 마운트가 복구돼도 컨테이너 안에서는 영영
`Stale file handle`(Errno 116) 상태로 남는다** — 프로세스가 죽지 않으므로
`restart: unless-stopped`도 발동하지 않는다 (2026-09-28 밥플러스 그리드 이미지 알림 누락 인시던트
원인).

이를 잡기 위해 두 서비스에 `stat()` 기반 healthcheck를 추가했고, `systemd/docker-autoheal.timer`가
5분마다 `scripts/autoheal.sh`를 돌려 `docker ps --filter health=unhealthy`로 잡히는 컨테이너를
자동 재시작한다. 유닛은 `apply.sh`가 배포 때마다 (재)설치한다.

**HC4 재부팅 후 확인할 것**: `docker inspect --format='{{.State.Health.Status}}' watch-infra-watch-gallery-1 watch-infra-watch-gallery-nginx-1` — `unhealthy`가 5분 넘게 지속되면 `systemctl status docker-autoheal.timer`로 타이머 자체가 살아있는지 먼저 확인.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: docker-autoheal 메커니즘 문서화"
```

---

## Self-Review 메모

- **스펙 커버리지**: healthcheck 추가(Task 1), 감지→재시작 자동화(Task 2+3), 배포 파이프라인 통합(Task 4), 운영 문서화(Task 5) — 대화에서 합의된 B안 요구사항 전부 커버.
- **플레이스홀더 스캔**: 없음 — 모든 스텝에 실제 파일 내용/명령 포함.
- **일관성**: 컨테이너 이름(`watch-infra-watch-gallery-1` 등)은 실제 `docker ps` 출력에서 확인된 이름과 동일하게 사용. `scripts/autoheal.sh` 경로는 Task 2와 Task 3(`%h/watch-infra/scripts/autoheal.sh`)에서 일치.
- **미해결 리스크**: Task 4의 passwordless sudo 여부는 실행 시점에 처음 확인됨 — Step 1에서 막히면 그 태스크만 범위를 수동 설치로 축소.

## 실행 후 정정 사항 (2026-09-28, 최종 리뷰에서 발견)

Global Constraints의 "systemd 유닛의 `ExecStart` 경로는... `User=`+`%h` specifier로 홈 디렉토리를 참조한다" 항목은 **틀렸다**. `%h`는 시스템 유닛(`--user` 유닛이 아닌)에서는 `User=`와 무관하게 `/root`로 풀린다 — 이 계획대로 구현했다면 `docker-autoheal.service`는 매번 `203/EXEC`로 조용히 실패했을 것이다. 실제로 동작하려면 `WorkingDirectory=~`(이건 `User=`를 따라간다)를 쓰고 `ExecStart`는 그 기준 상대경로로 써야 한다. 이 패턴을 다른 systemd 유닛 작업에 재사용하지 말 것.

## 실행 후 정정 사항 2 (PR 리뷰 중 사용자 결정으로 번복)

Task 4("apply.sh에 systemd 유닛 설치 스텝 추가")는 PR 코드 리뷰 대화 중 되돌렸다. systemd 유닛 파일은 한 번 맞게 설치되면 거의 바뀔 일이 없는데, 그걸 위해 무인 CI 배포 스크립트(`apply.sh`)에 `sudo`를 매번 실행하게 만드는 건 실익 대비 위험(사람 검토 없이 매 배포마다 root 권한 명령이 도는 표면적 확대)이 크다고 판단. 대신 `README.md`의 Autoheal 섹션에 "최초 설치 (1회, 수동)" 절차로 옮겼다 — 호스트를 새로 프로비저닝하거나 유닛 파일을 고쳤을 때만 사람이 직접 실행한다.
