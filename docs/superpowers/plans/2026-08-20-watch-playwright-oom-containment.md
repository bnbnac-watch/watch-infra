# watch-playwright OOM 봉쇄 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** N2+ 호스트에서 Chromium이 OOM killer에 죽는 사건의 블라스트 반경을 `watch-playwright` 컨테이너 안으로 봉쇄한다 — 다른 8개 서비스가 대신 죽는 일을 막고, 상한값을 실측 기반으로 조정 가능하게 만든다.

**Architecture:** `watch-playwright` 서비스에 Compose 레벨 `mem_limit`(`.env`로 조정 가능)을 건다. 컨테이너 자체 cgroup이 상한을 강제하므로, 메모리 초과 시 커널 OOM killer가 호스트 전역에서 무작위로 희생양을 고르는 대신 이 컨테이너(사실상 Chromium) 안에서만 죽는다. 이미 적용된 `init: true`(커밋 `0e4095b`)와 `restart: unless-stopped`가 죽은 뒤의 청소와 재기동을 담당한다. 추가로 Chromium 실행 인자를 줄여 기본 메모리 풋프린트 자체도 낮춘다(선택 과제, 실기기 검증 필요).

**Tech Stack:** Docker Compose(Compose Specification, `version:` 키 없음), Python 3.11 / FastAPI / Playwright(기존 스택 그대로).

**Spec:** 없음 — 별도 브레인스토밍 문서 없이, 이 대화에서 `watch-infra/docker-compose.yml`과 `watch-playwright/main.py`를 직접 감사한 결과로 작성. 근거는 아래 Global Constraints 참고.

## Global Constraints

- 이 계획은 좀비 프로세스 누적 사고(커밋 `0e4095b`, `init: true` 적용, 2026-08-20)의 **근본 원인**이었던 "Chromium이 메모리 압박으로 OOM killer에 죽는다" 자체를 다룬다. `init: true`는 죽은 뒤 남는 고아 프로세스를 청소할 뿐, Chromium이 죽는 것 자체는 막지 못한다 — 이 사실은 `init: true` 적용 시점에도 명확히 인지된 상태였다(`watch-infra/README.md`의 해당 섹션 참고).
- 확인된 사실(2026-08-20): 현재 `docker-compose.yml`의 9개 서비스 어디에도 메모리 상한이 없다.
- `PLAYWRIGHT_MEM_LIMIT`의 실제 값은 N2+ 서버의 실물 RAM과 나머지 8개 서비스의 실측 사용량에 좌우된다. 숫자를 추측해서 하드코딩하지 않는다 — 코드/설정 배관은 이 문서에서 완결시키고, 실제 서버에 적용할 숫자는 **배포 직전 SSH 실측**으로 정한다(Task 1 Step 1).
- `mem_limit`은 Compose Specification의 최상위 서비스 키다(스웜 전용 `deploy.resources.limits`가 아니다) — 이 레포처럼 `docker compose up -d`(비-스웜)로 돌리는 구성에도 그대로 적용된다.
- `watch-playwright`에는 기존 테스트 인프라가 없다(pytest 없음). 이번 변경은 config/런타임 동작이라 유닛테스트로 의미 있게 검증하기 어렵다 — 검증은 `docker compose config`(파싱 확인)와 실기기 수동 검증(`docker stats` + `/render` 호출)으로 한다. 이 정도 변경 때문에 새로 pytest를 들여오지 않는다.
- Task 3(Chromium 실행 인자 축소)은 **신뢰도가 낮은 선택 과제**다 — 로컬에 ARM64 실기기가 없어 렌더 회귀 여부를 이 계획 작성 시점에 검증할 수 없다. 실기기에서 기존에 정상 렌더되던 사이트가 깨지면 즉시 롤백한다.

---

## Task 1: `mem_limit` 플러밍 (docker-compose.yml + .env.example)

**Files:**
- Modify: `watch-infra/docker-compose.yml`
- Modify: `watch-infra/.env.example`

**Interfaces:**
- Produces: `PLAYWRIGHT_MEM_LIMIT` env var(기본 `768m`), `watch-playwright` 서비스의 `mem_limit` 키.

- [ ] **Step 1: 실측치 확보 (수동, 배포 직전 N2+ SSH)**

```bash
free -h
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}"
```

가이드: 전체 RAM에서 나머지 8개 서비스 실측 합계 + OS 여유분(300~500MB 권장)을 뺀 값을 `PLAYWRIGHT_MEM_LIMIT` 후보로 잡는다. 이 값은 서버의 실제 `.env`(gitignore 대상, 커밋 안 함)에 설정한다. 이 Step은 코드 변경이 아니라 배포 전 확인 절차이며, Step 2~3의 기본값(`768m`)은 실측 전까지 쓰는 보수적 추정치다.

- [ ] **Step 2: `.env.example`에 문서화된 기본값 추가**

`watch-infra/.env.example`의 `MAX_CONCURRENCY` 줄 아래에 추가:

```
# watch-playwright 컨테이너 메모리 상한. Chromium이 OOM killer에 죽더라도
# 이 컨테이너 안에서만 죽도록 봉쇄한다 (다른 서비스 보호 목적).
# 기본값은 보수적 추정치 — 실서버 free -h / docker stats 실측 후 .env에서 조정할 것.
PLAYWRIGHT_MEM_LIMIT=768m
```

- [ ] **Step 3: `docker-compose.yml`의 `watch-playwright` 서비스에 `mem_limit` 추가**

`watch-infra/docker-compose.yml:1-8`을 다음과 같이 수정:

```yaml
services:
  watch-playwright:
    image: watch-playwright
    restart: unless-stopped
    init: true
    ipc: host
    mem_limit: ${PLAYWRIGHT_MEM_LIMIT:-768m}
    environment:
      - MAX_CONCURRENCY=${MAX_CONCURRENCY:-1}
```

- [ ] **Step 4: 파싱 검증**

Run:
```bash
cd watch-infra
docker compose config
```

Expected: 출력의 `watch-playwright` 서비스 블록에 `mem_limit: '768m'`(또는 `.env`에 설정한 값)이 포함됨. 이 저장소는 `docker` 실행 환경이 로컬에 없을 수 있으므로, `docker` CLI가 없으면 이 Step은 실제 배포 시점(N2+ 서버)에 실행한다.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "fix: watch-playwright 메모리 상한 추가로 OOM 블라스트 반경 봉쇄"
```

---

## Task 2: README 문서화

**Files:**
- Modify: `watch-infra/README.md`

**Interfaces:**
- Consumes: 없음(문서 전용 변경)

- [ ] **Step 1: "왜 이런 구조인가" 섹션에 항목 추가**

`watch-infra/README.md`의 `**모든 서비스에 init: true를 넣은 이유**` 단락(47-48행) 바로 뒤에 추가:

```markdown
**`watch-playwright`에 `mem_limit`을 건 이유**
`init: true`(2026-08-19 사고 대응)는 Chromium이 OOM killer에 죽은 뒤 남는 고아 프로세스를 청소할 뿐, Chromium이 애초에 죽는 것 자체는 막지 못한다. ARM64 보드(N2+)는 메모리가 넉넉하지 않아 무거운 페이지를 렌더링할 때 Chromium이 다시 OOM 대상이 될 수 있다. 호스트 전역 OOM killer는 어떤 프로세스가 죽을지 예측하기 어렵고, 최악의 경우 DB 커넥션을 쥔 다른 서비스가 대신 죽을 수도 있다. `mem_limit`으로 컨테이너별 cgroup 메모리 상한을 걸어두면, 예산을 넘겼을 때 `watch-playwright` 자기 자신(그리고 그 안의 Chromium 관련 프로세스)만 죽는다 — `restart: unless-stopped`가 재기동하고 `init: true`가 잔여 고아 프로세스를 청소한다. 근본적으로 "Chromium이 죽지 않게" 만드는 게 아니라 "죽을 때 블라스트 반경을 이 컨테이너 안으로 봉쇄"하는 접근이다. 실제 상한값(`PLAYWRIGHT_MEM_LIMIT`)은 서버 실측(`free -h`, `docker stats`) 기준으로 조정한다.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: watch-playwright mem_limit 도입 근거 기록"
```

---

## Task 3 (선택, 신뢰도 낮음 — 실기기 검증 필수): Chromium 실행 인자로 기본 풋프린트 축소

**Files:**
- Modify: `watch-playwright/main.py:57-59`

**Interfaces:**
- Consumes: 없음
- Produces: 없음 (동작 변경 없음, 리소스 사용량만 영향)

- [ ] **Step 1: launch 인자 추가**

`watch-playwright/main.py`의 `chromium.launch` 호출을 수정:

```python
        browser = await _playwright.chromium.launch(
            args=[
                "--disable-blink-features=AutomationControlled",
                "--disable-gpu",
                "--renderer-process-limit=1",
            ]
        )
```

- [ ] **Step 2: 실기기 검증 (N2+, 배포 후)**

기존에 정상 렌더되던 크롤러 대상 URL 각각에 대해 `/render`를 직접 호출해 HTML이 정상적으로 나오는지 확인:

```bash
curl -s -X POST http://localhost:8080/render \
  -H "Content-Type: application/json" \
  -d '{"url": "<crawler-wanted가 실제로 렌더하는 URL 하나>"}' | head -c 500

curl -s -X POST http://localhost:8080/render \
  -H "Content-Type: application/json" \
  -d '{"url": "<crawler-workhub가 실제로 렌더하는 URL 하나>"}' | head -c 500

curl -s -X POST http://localhost:8080/render \
  -H "Content-Type: application/json" \
  -d '{"url": "<crawler-kakao-channels가 실제로 렌더하는 URL 하나>"}' | head -c 500
```

각 응답이 200이고 기대한 콘텐츠가 들어있는지 확인. 변경 전/후 `docker stats`로 RSS도 비교해 실제로 낮아지는지 확인한다. 셋 중 하나라도 깨지면 **즉시 Step 1을 되돌리고 커밋하지 않는다**.

- [ ] **Step 3: 검증 통과 시에만 Commit**

```bash
git add main.py
git commit -m "perf: Chromium 실행 인자로 렌더 프로세스 기본 풋프린트 축소"
```
