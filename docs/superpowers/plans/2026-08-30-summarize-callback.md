# 요약 비동기 job/콜백 아키텍처 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `watch-runner`가 `watch-ai`의 `/summarize` 응답을 동기로 기다리다 클라이언트
타임아웃(120s)으로 결과를 유실시키는 경로를, Postgres LISTEN/NOTIFY 기반
job/콜백 방식으로 대체한다.

**Architecture:** `watch-ai`는 `/summarize`를 받으면 `async_jobs` 테이블에
`pending` row를 만들고 즉시 202+`job_id`를 반환한 뒤 백그라운드 task로 처리한다.
완료되면 같은 트랜잭션에서 결과를 쓰고 `pg_notify`한다. `watch-runner`는 앱
수명 동안 유지되는 전용 LISTEN 커넥션 + 30초 폴백 폴링으로 job 완료를 기다린다.
기존 `pending_summaries` 기반 크롤 사이클 간 재시도 로직은 그대로 두고, 그
아래 계층(`_call_summarize_api`)만 교체한다.

**Tech Stack:** Python 3.11, FastAPI, asyncpg(LISTEN/NOTIFY), httpx,
pytest + pytest-asyncio(`asyncio_mode = auto`), dbmate 마이그레이션.

**Spec:** `watch-infra/docs/superpowers/specs/2026-08-30-summarize-callback-design.md`

## Global Constraints

- job 대기 상한은 300초. 초과 시 `_call_summarize_api`는 `None`을 반환하고
  기존 `pending_summaries` 재시도 로직이 다음 크롤 사이클에 재시도한다.
- pending job 정리 스윕 주기는 1시간 — 1시간 이상 `pending`인 job은 `failed`로
  마킹한다.
- 폴백 폴링 주기는 30초.
- `async_jobs.kind`는 지금 `'summarize'`만 쓰지만 컬럼 자체는 범용으로
  유지한다.
- `pending_summaries`/`_resolve_summaries`/`_PermanentSummaryFailure`/
  `MAX_SUMMARY_ATTEMPTS`(`watch-runner`)는 변경하지 않는다.
- `AI_CONCURRENCY`/`RPD_LIMIT`/`SUMMARIZE_TIMEOUT_S`(`watch-ai`) 정책은
  변경하지 않는다.
- Task 8(`executor.py`의 불필요한 전역 세마포어 제거)은 사용자 요청으로 이
  계획에 같이 포함된, 콜백 설계와는 무관한 별도 수정이다.

---

### Task 1: `async_jobs` 마이그레이션

**Files:**
- Create: `watch-infra/db/migrations/20260901010000_create_async_jobs.sql`

**Interfaces:**
- Produces: `async_jobs` 테이블(컬럼: `id uuid pk`, `kind text`, `payload jsonb`,
  `status text`, `result jsonb`, `error text`, `retryable boolean`,
  `created_at timestamptz`, `finished_at timestamptz`), 인덱스
  `async_jobs_kind_status_created_idx`.

- [ ] **Step 1: 마이그레이션 파일 작성**

```sql
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
```

- [ ] **Step 2: 로컬 스크래치 Postgres에 up 적용해서 검증**

```bash
docker run -d --rm --name migration-test-pg -e POSTGRES_PASSWORD=test -p 15432:5432 postgres:16
sleep 3
docker run --rm --network host \
  -v "$PWD/watch-infra/db:/db" \
  -e DATABASE_URL="postgresql://postgres:test@localhost:15432/postgres?sslmode=disable" \
  -e DBMATE_NO_DUMP_SCHEMA=true \
  amacneil/dbmate:2 up
```

Expected: 마이그레이션이 에러 없이 적용됨. `\d async_jobs`로 컬럼/인덱스 확인
가능(`docker exec migration-test-pg psql -U postgres -c '\d async_jobs'`).

- [ ] **Step 3: down도 깨끗이 되는지 확인 후 컨테이너 정리**

```bash
docker run --rm --network host \
  -v "$PWD/watch-infra/db:/db" \
  -e DATABASE_URL="postgresql://postgres:test@localhost:15432/postgres?sslmode=disable" \
  -e DBMATE_NO_DUMP_SCHEMA=true \
  amacneil/dbmate:2 down
docker stop migration-test-pg
```

Expected: `DROP TABLE`이 에러 없이 실행됨.

- [ ] **Step 4: Commit**

```bash
git add watch-infra/db/migrations/20260901010000_create_async_jobs.sql
git commit -m "feat: async_jobs 테이블 마이그레이션 추가"
```

---

### Task 2: `watch-ai` — job 저장소 함수 (`db.py`)

**Files:**
- Modify: `watch-ai/db.py`
- Modify: `watch-ai/tests/conftest.py` (`FakeConn`에 `execute`/`fetch`/`transaction` 추가)
- Test: `watch-ai/tests/test_db.py` (신규)

**Interfaces:**
- Consumes: `_pool`(기존 모듈 전역), `watch-ai/tests/conftest.py`의
  `fake_pool`/`fake_conn` fixture.
- Produces: `create_job(job_id: uuid.UUID, kind: str, payload: dict) -> None`,
  `complete_job(job_id: uuid.UUID, result: dict) -> None`,
  `fail_job(job_id: uuid.UUID, error: str, retryable: bool) -> None`,
  `sweep_stale_jobs(older_than_seconds: int) -> int` — Task 3이 이 네 함수를
  그대로 호출한다.

- [ ] **Step 1: `conftest.py`의 `FakeConn`을 확장하는 실패 테스트 작성**

`watch-ai/tests/test_db.py` 생성:

```python
import uuid

import db


async def test_create_job_inserts_row(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    job_id = uuid.uuid4()

    await db.create_job(job_id, "summarize", {"url": "https://x"})

    query, args = fake_conn.execute_calls[0]
    assert "INSERT INTO async_jobs" in query
    assert args == (job_id, "summarize", {"url": "https://x"})


async def test_complete_job_updates_and_notifies(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    job_id = uuid.uuid4()

    await db.complete_job(job_id, {"result": "요약"})

    update_query, update_args = fake_conn.execute_calls[0]
    assert "status = 'done'" in update_query
    assert update_args == (job_id, {"result": "요약"})
    notify_query, notify_args = fake_conn.execute_calls[1]
    assert "pg_notify" in notify_query
    assert notify_args == (str(job_id),)


async def test_fail_job_marks_retryable_flag(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    job_id = uuid.uuid4()

    await db.fail_job(job_id, "자막 없음", retryable=False)

    update_query, update_args = fake_conn.execute_calls[0]
    assert "status = 'failed'" in update_query
    assert update_args == (job_id, "자막 없음", False)


async def test_sweep_stale_jobs_returns_count(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    fake_conn.fetch_return = [{"id": uuid.uuid4()}, {"id": uuid.uuid4()}]

    count = await db.sweep_stale_jobs(3600)

    assert count == 2
```

- [ ] **Step 2: 테스트 실행해서 실패 확인**

Run: `cd watch-ai && pytest tests/test_db.py -v`
Expected: FAIL — `FakeConn`에 `execute`/`fetch` 없음, `db.create_job` 등 미정의.

- [ ] **Step 3: `conftest.py`의 `FakeConn`에 `execute`/`fetch`/`transaction` 추가**

`watch-ai/tests/conftest.py`의 `FakeConn` 클래스를 아래로 교체:

```python
class _FakeTransactionCtx:
    async def __aenter__(self):
        return None

    async def __aexit__(self, exc_type, exc, tb):
        return False


class FakeConn:
    def __init__(self):
        self.fetchrow_return = None
        self.fetchrow_calls = []
        self.execute_calls = []
        self.fetch_return = []
        self.fetch_calls = []

    async def fetchrow(self, query, *args):
        self.fetchrow_calls.append((query, args))
        return self.fetchrow_return

    async def execute(self, query, *args):
        self.execute_calls.append((query, args))

    async def fetch(self, query, *args):
        self.fetch_calls.append((query, args))
        return self.fetch_return

    def transaction(self):
        return _FakeTransactionCtx()
```

- [ ] **Step 4: `db.py`에 jsonb 코덱 등록 + job 함수 구현**

`watch-ai/db.py` 전체를 아래로 교체(기존 `increment_usage`는 그대로 유지):

```python
import json
import os
import uuid

import asyncpg

_pool: asyncpg.Pool | None = None


async def _init_conn(conn: asyncpg.Connection):
    # asyncpg는 JSONB를 str로 반환하므로 dict로 자동 변환하는 코덱 등록
    await conn.set_type_codec(
        "jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog"
    )


async def init():
    global _pool
    _pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], init=_init_conn)


async def increment_usage() -> int:
    async with _pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO ai_usage (date, request_count) VALUES (CURRENT_DATE, 1)
            ON CONFLICT (date) DO UPDATE SET request_count = ai_usage.request_count + 1
            RETURNING request_count
            """
        )
        return row["request_count"]


async def create_job(job_id: uuid.UUID, kind: str, payload: dict) -> None:
    async with _pool.acquire() as conn:
        await conn.execute(
            "INSERT INTO async_jobs (id, kind, payload) VALUES ($1, $2, $3)",
            job_id, kind, payload,
        )


async def complete_job(job_id: uuid.UUID, result: dict) -> None:
    async with _pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                "UPDATE async_jobs SET status = 'done', result = $2, finished_at = now() WHERE id = $1",
                job_id, result,
            )
            await conn.execute("SELECT pg_notify('async_job_done', $1)", str(job_id))


async def fail_job(job_id: uuid.UUID, error: str, retryable: bool) -> None:
    async with _pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                "UPDATE async_jobs SET status = 'failed', error = $2, retryable = $3, finished_at = now() WHERE id = $1",
                job_id, error, retryable,
            )
            await conn.execute("SELECT pg_notify('async_job_done', $1)", str(job_id))


async def sweep_stale_jobs(older_than_seconds: int = 3600) -> int:
    async with _pool.acquire() as conn:
        rows = await conn.fetch(
            "UPDATE async_jobs SET status = 'failed', error = 'stale: no worker completed this job', "
            "retryable = true, finished_at = now() "
            "WHERE status = 'pending' AND created_at < now() - ($1 || ' seconds')::interval "
            "RETURNING id",
            str(older_than_seconds),
        )
        return len(rows)
```

- [ ] **Step 5: 테스트 실행해서 통과 확인**

Run: `cd watch-ai && pytest tests/test_db.py -v`
Expected: PASS (4 tests)

- [ ] **Step 6: 기존 테스트 회귀 확인**

Run: `cd watch-ai && pytest -v`
Expected: 기존 `test_gemini.py`, `test_main.py` 전부 PASS(이 Task는 `main.py`를
건드리지 않으므로 영향 없어야 함).

- [ ] **Step 7: Commit**

```bash
git add watch-ai/db.py watch-ai/tests/conftest.py watch-ai/tests/test_db.py
git commit -m "feat: async_jobs 저장소 함수 추가"
```

---

### Task 3: `watch-ai` — `/summarize`를 job 접수 방식으로 변경

**Files:**
- Modify: `watch-ai/main.py`
- Modify: `watch-ai/tests/test_main.py`

**Interfaces:**
- Consumes: Task 2의 `db.create_job`/`db.complete_job`/`db.fail_job`/
  `db.sweep_stale_jobs`.
- Produces: `POST /summarize` → `202 {"job_id": str}`. `_process_job(job_id: uuid.UUID, url: str, summarizer, semaphore) -> None`
  — Task 6에서 이 계약(같은 시그니처는 아니지만 동일한 job 생명주기)을 전제로
  `watch-runner`가 결과를 기다린다.

- [ ] **Step 1: 실패하는 테스트부터 교체**

`watch-ai/tests/test_main.py`에서 `test_summarize_respects_semaphore_capacity`와
`test_summarize_times_out_and_releases_semaphore`를 **삭제**하고(동기 응답
계약을 전제로 한 테스트라 더 이상 유효하지 않음) 아래로 교체:

```python
async def test_process_job_respects_semaphore_capacity(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    fake_conn.fetchrow_return = {"request_count": 1}
    fake = _FakeSummarizer(delay=0.05)
    semaphore = asyncio.Semaphore(2)

    await asyncio.gather(*[
        main._process_job(uuid.uuid4(), f"https://x/{i}", fake, semaphore)
        for i in range(4)
    ])

    assert fake.max_concurrent == 2
    done_calls = [c for c in fake_conn.execute_calls if "status = 'done'" in c[0]]
    assert len(done_calls) == 4


async def test_process_job_marks_retryable_on_timeout(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    fake_conn.fetchrow_return = {"request_count": 1}
    fake = _FakeSummarizer(delay=0.2)
    monkeypatch.setattr(main, "SUMMARIZE_TIMEOUT_S", 0.05)

    await main._process_job(uuid.uuid4(), "https://x", fake, asyncio.Semaphore(1))

    query, args = fake_conn.execute_calls[0]
    assert "status = 'failed'" in query
    assert args[2] is True  # retryable


async def test_process_job_marks_not_retryable_when_no_captions(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    fake_conn.fetchrow_return = {"request_count": 1}
    fake = _FakeSummarizer(result=None)

    await main._process_job(uuid.uuid4(), "https://x", fake, asyncio.Semaphore(1))

    query, args = fake_conn.execute_calls[0]
    assert "status = 'failed'" in query
    assert args[2] is False  # retryable


async def test_process_job_marks_retryable_when_rpd_exceeded(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    fake_conn.fetchrow_return = {"request_count": 9999}
    fake = _FakeSummarizer()

    await main._process_job(uuid.uuid4(), "https://x", fake, asyncio.Semaphore(1))

    query, args = fake_conn.execute_calls[0]
    assert "status = 'failed'" in query
    assert args[1] == "RPD 한도 초과"
    assert args[2] is True  # retryable


async def test_summarize_endpoint_returns_job_id_immediately(client):
    async with client:
        main.app.state.summarizer = _FakeSummarizer()
        main.app.state.semaphore = asyncio.Semaphore(2)
        res = await client.post("/summarize", json={"url": "https://x"})

    assert res.status_code == 202
    uuid.UUID(res.json()["job_id"])  # 유효한 UUID 문자열인지 확인
```

파일 맨 위 import에 `import uuid` 한 줄 추가.

- [ ] **Step 2: 테스트 실행해서 실패 확인**

Run: `cd watch-ai && pytest tests/test_main.py -v`
Expected: FAIL — `main._process_job` 없음, `/summarize`가 여전히 동기 응답.

- [ ] **Step 3: `main.py`의 `/summarize` 핸들러를 job 접수 방식으로 교체**

`watch-ai/main.py`에서:
- import 줄의 `HTTPException`을 제거(더 이상 안 씀), `import uuid` 추가.
- 아래 상수 2개 추가(기존 `SUMMARIZE_TIMEOUT_S` 정의 바로 아래):

```python
SWEEP_INTERVAL_SECONDS = 3600
STALE_JOB_SECONDS = 3600
```

- `lifespan`을 아래로 교체:

```python
async def _sweep_loop():
    while True:
        try:
            count = await db.sweep_stale_jobs(STALE_JOB_SECONDS)
            if count:
                logger.warning("오래된 pending job %d개 정리", count)
        except Exception as exc:
            logger.warning("job 정리 스윕 실패: %s", exc)
        await asyncio.sleep(SWEEP_INTERVAL_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.init()
    async with httpx.AsyncClient() as client:
        gemini.set_client(client)
        app.state.summarizer = _build_summarizer()
        app.state.semaphore = asyncio.Semaphore(AI_CONCURRENCY)
        sweep_task = asyncio.create_task(_sweep_loop())
        yield
        sweep_task.cancel()
```

- `/summarize` 핸들러 전체를 아래로 교체:

```python
async def _process_job(job_id: uuid.UUID, url: str, summarizer, semaphore: asyncio.Semaphore):
    async with semaphore:
        count = await db.increment_usage()
        if count > RPD_LIMIT:
            logger.warning("RPD 한도 초과 (오늘 %d회)", count)
            await db.fail_job(job_id, "RPD 한도 초과", retryable=True)
            return

        try:
            result = await asyncio.wait_for(
                summarizer.summarize(url), timeout=SUMMARIZE_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            logger.error("요약 시간 초과 (%s, %.0fs)", url, SUMMARIZE_TIMEOUT_S)
            await db.fail_job(job_id, "요약 시간 초과", retryable=True)
            return

        if result is None:
            await db.fail_job(job_id, "자막 없음", retryable=False)
            return

        logger.info("요약 완료: %s (오늘 %d회)", url, count)
        await db.complete_job(job_id, {"result": result})


@app.post("/summarize", status_code=202)
async def summarize_video(req: SummarizeRequest, request: Request):
    job_id = uuid.uuid4()
    await db.create_job(job_id, "summarize", {"url": req.url})
    asyncio.create_task(
        _process_job(job_id, req.url, request.app.state.summarizer, request.app.state.semaphore)
    )
    return {"job_id": str(job_id)}
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

Run: `cd watch-ai && pytest tests/test_main.py -v`
Expected: PASS

- [ ] **Step 5: 전체 회귀 확인**

Run: `cd watch-ai && pytest -v`
Expected: `test_lifespan_wires_semaphore_and_gemini_client`를 포함해 전부 PASS.

- [ ] **Step 6: Commit**

```bash
git add watch-ai/main.py watch-ai/tests/test_main.py
git commit -m "feat: /summarize를 job 접수 방식으로 변경, 스윕 루프 추가"
```

---

### Task 4: `watch-runner` — `get_job` 조회 함수

**Files:**
- Modify: `watch-runner/db.py`
- Test: `watch-runner/tests/test_db.py`

**Interfaces:**
- Produces: `get_job(job_id) -> dict | None` — Task 5의 `jobs.py`가 이 함수를
  호출한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`watch-runner/tests/test_db.py`에 추가:

```python
import uuid


async def test_get_job_returns_row_as_dict(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)
    job_id = uuid.uuid4()
    fake_conn.fetchrow_return = {
        "id": job_id, "status": "done", "result": {"result": "요약"},
        "error": None, "retryable": True,
    }

    row = await db.get_job(job_id)

    assert row["status"] == "done"
    assert row["result"] == {"result": "요약"}


async def test_get_job_returns_none_when_missing(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)

    row = await db.get_job(uuid.uuid4())

    assert row is None
```

(파일 맨 위에 이미 `import db`가 있으므로 `import uuid`만 추가하면 된다.)

- [ ] **Step 2: 테스트 실행해서 실패 확인**

Run: `cd watch-runner && pytest tests/test_db.py -v`
Expected: FAIL — `db.get_job` 미정의.

- [ ] **Step 3: `db.py`에 `get_job` 추가**

`watch-runner/db.py` 맨 끝에 추가:

```python
async def get_job(job_id) -> dict | None:
    async with _pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, status, result, error, retryable FROM async_jobs WHERE id = $1",
            job_id,
        )
        return dict(row) if row else None
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

Run: `cd watch-runner && pytest tests/test_db.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add watch-runner/db.py watch-runner/tests/test_db.py
git commit -m "feat: async_jobs 조회 함수 추가"
```

---

### Task 5: `watch-runner` — `jobs.py` (LISTEN 대기 + 폴백 폴링)

**Files:**
- Create: `watch-runner/jobs.py`
- Test: `watch-runner/tests/test_jobs.py`

**Interfaces:**
- Consumes: Task 4의 `db.get_job(job_id) -> dict | None`.
- Produces: `wait_for_job(job_id: str, timeout: int = 300) -> dict | None`,
  `start_listener(dsn: str) -> asyncio.Task`, `start_fallback_poll() -> asyncio.Task`
  — Task 6이 이 세 함수를 사용한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`watch-runner/tests/test_jobs.py` 생성:

```python
import asyncio
import uuid

import pytest

import jobs


@pytest.fixture(autouse=True)
def _clear_pending():
    jobs._pending.clear()
    yield
    jobs._pending.clear()


async def test_wait_for_job_returns_row_immediately_if_already_done(monkeypatch):
    job_id = str(uuid.uuid4())

    async def fake_get_job(jid):
        return {"status": "done", "result": {"result": "요약"}}
    monkeypatch.setattr(jobs.db, "get_job", fake_get_job)

    row = await jobs.wait_for_job(job_id, timeout=1)

    assert row["status"] == "done"
    assert job_id not in jobs._pending


async def test_wait_for_job_resolves_when_notified(monkeypatch):
    job_id = str(uuid.uuid4())

    async def fake_get_job(jid):
        return None
    monkeypatch.setattr(jobs.db, "get_job", fake_get_job)

    async def notify_later():
        await asyncio.sleep(0.01)
        jobs._resolve(job_id, {"status": "done", "result": {"result": "요약"}})
    asyncio.create_task(notify_later())

    row = await jobs.wait_for_job(job_id, timeout=1)

    assert row["status"] == "done"


async def test_wait_for_job_times_out_and_cleans_up_pending(monkeypatch):
    job_id = str(uuid.uuid4())

    async def fake_get_job(jid):
        return None
    monkeypatch.setattr(jobs.db, "get_job", fake_get_job)

    row = await jobs.wait_for_job(job_id, timeout=0.05)

    assert row is None
    assert job_id not in jobs._pending


async def test_on_pg_notify_resolves_matching_future(monkeypatch):
    job_id = str(uuid.uuid4())
    fut = asyncio.get_event_loop().create_future()
    jobs._pending[job_id] = fut

    async def fake_get_job(jid):
        return {"status": "done", "result": {"result": "요약"}}
    monkeypatch.setattr(jobs.db, "get_job", fake_get_job)

    await jobs._on_pg_notify(None, None, "async_job_done", job_id)

    assert fut.done()
    assert fut.result()["status"] == "done"


async def test_on_pg_notify_ignores_unknown_job_id(monkeypatch):
    async def fake_get_job(jid):
        return {"status": "done"}
    monkeypatch.setattr(jobs.db, "get_job", fake_get_job)

    await jobs._on_pg_notify(None, None, "async_job_done", str(uuid.uuid4()))
    # 매칭되는 future가 없어도 예외 없이 조용히 지나가면 통과


async def test_fallback_poll_resolves_completed_pending_jobs(monkeypatch):
    job_id = str(uuid.uuid4())
    fut = asyncio.get_event_loop().create_future()
    jobs._pending[job_id] = fut

    async def fake_get_job(jid):
        return {"status": "done", "result": {"result": "요약"}}
    monkeypatch.setattr(jobs.db, "get_job", fake_get_job)
    monkeypatch.setattr(jobs, "FALLBACK_POLL_INTERVAL_S", 0.01)

    poll_task = asyncio.create_task(jobs._fallback_poll_loop())
    await asyncio.sleep(0.03)
    poll_task.cancel()

    assert fut.done()
```

- [ ] **Step 2: 테스트 실행해서 실패 확인**

Run: `cd watch-runner && pytest tests/test_jobs.py -v`
Expected: FAIL — `jobs` 모듈 자체가 없음.

- [ ] **Step 3: `jobs.py` 구현**

```python
import asyncio
import logging

import asyncpg

import db

logger = logging.getLogger(__name__)

FALLBACK_POLL_INTERVAL_S = 30

_pending: dict[str, asyncio.Future] = {}


def _resolve(job_id: str, row: dict):
    fut = _pending.pop(job_id, None)
    if fut and not fut.done():
        fut.set_result(row)


async def wait_for_job(job_id: str, timeout: int = 300) -> dict | None:
    fut = asyncio.get_event_loop().create_future()
    _pending[job_id] = fut
    try:
        row = await db.get_job(job_id)
        if row is not None and row["status"] != "pending":
            _pending.pop(job_id, None)
            return row
        return await asyncio.wait_for(fut, timeout=timeout)
    except asyncio.TimeoutError:
        logger.warning("job 대기 타임아웃 (%s)", job_id)
        return None
    finally:
        _pending.pop(job_id, None)


async def _on_pg_notify(conn, pid, channel, payload):
    job_id = payload
    row = await db.get_job(job_id)
    if row is not None:
        _resolve(job_id, row)


async def _fallback_poll_loop():
    while True:
        await asyncio.sleep(FALLBACK_POLL_INTERVAL_S)
        for job_id in list(_pending.keys()):
            row = await db.get_job(job_id)
            if row is not None and row["status"] != "pending":
                _resolve(job_id, row)


async def start_listener(dsn: str) -> asyncio.Task:
    """전용 LISTEN 커넥션을 열고 유지하다가, 끊기면 재연결하는 supervisor
    task를 반환한다. 호출자는 앱 종료 시 이 task를 cancel()하면 된다."""

    async def _run():
        while True:
            conn = None
            try:
                conn = await asyncpg.connect(dsn)
                closed = asyncio.Event()
                conn.add_termination_listener(lambda c: closed.set())
                await conn.add_listener("async_job_done", _on_pg_notify)
                logger.info("job 리스너 커넥션 연결됨")
                await closed.wait()
                logger.warning("job 리스너 커넥션 끊김, 재연결 시도")
            except Exception as exc:
                logger.warning("job 리스너 커넥션 오류: %s", exc)
            finally:
                if conn is not None and not conn.is_closed():
                    await conn.close()
            await asyncio.sleep(5)

    return asyncio.create_task(_run())


def start_fallback_poll() -> asyncio.Task:
    return asyncio.create_task(_fallback_poll_loop())
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

Run: `cd watch-runner && pytest tests/test_jobs.py -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add watch-runner/jobs.py watch-runner/tests/test_jobs.py
git commit -m "feat: job 완료 대기용 LISTEN/폴백폴링 모듈 추가"
```

---

### Task 6: `watch-runner` — `_call_summarize_api`를 job 대기 방식으로 교체

**Files:**
- Modify: `watch-runner/main.py`
- Test: `watch-runner/tests/test_main.py`

**Interfaces:**
- Consumes: Task 5의 `jobs.wait_for_job`/`jobs.start_listener`/
  `jobs.start_fallback_poll`.
- Produces: `_call_summarize_api(url: str) -> str | None`(기존과 동일한 계약 —
  성공 시 요약 문자열, 영구 실패 시 `_PermanentSummaryFailure`, 그 외 실패 시
  `None`). `_summarize`/`_resolve_item_summary`/`_resolve_summaries`는 이
  계약이 유지되는 한 수정 불필요.

- [ ] **Step 1: 실패하는 테스트 작성**

`watch-runner/tests/test_main.py` 맨 위 import에 `import jobs` 추가 후, 파일
끝에 추가:

```python
class _FakeSummarizeResponse:
    def __init__(self, job_id="job-1"):
        self._job_id = job_id

    def raise_for_status(self):
        pass

    def json(self):
        return {"job_id": self._job_id}


async def test_call_summarize_api_returns_result_on_done(monkeypatch):
    async def fake_post(url, json, timeout):
        return _FakeSummarizeResponse()
    monkeypatch.setattr(main, "_http_client", type("C", (), {"post": staticmethod(fake_post)})())

    async def fake_wait_for_job(job_id, timeout):
        assert job_id == "job-1"
        return {"status": "done", "result": {"result": "요약"}}
    monkeypatch.setattr(main.jobs, "wait_for_job", fake_wait_for_job)

    result = await main._call_summarize_api("https://x")

    assert result == "요약"


async def test_call_summarize_api_raises_permanent_failure_when_not_retryable(monkeypatch):
    async def fake_post(url, json, timeout):
        return _FakeSummarizeResponse()
    monkeypatch.setattr(main, "_http_client", type("C", (), {"post": staticmethod(fake_post)})())

    async def fake_wait_for_job(job_id, timeout):
        return {"status": "failed", "retryable": False, "error": "자막 없음"}
    monkeypatch.setattr(main.jobs, "wait_for_job", fake_wait_for_job)

    with pytest.raises(main._PermanentSummaryFailure):
        await main._call_summarize_api("https://x")


async def test_call_summarize_api_returns_none_when_wait_times_out(monkeypatch):
    async def fake_post(url, json, timeout):
        return _FakeSummarizeResponse()
    monkeypatch.setattr(main, "_http_client", type("C", (), {"post": staticmethod(fake_post)})())

    async def fake_wait_for_job(job_id, timeout):
        return None
    monkeypatch.setattr(main.jobs, "wait_for_job", fake_wait_for_job)

    result = await main._call_summarize_api("https://x")

    assert result is None


async def test_call_summarize_api_returns_none_on_transient_failure(monkeypatch):
    async def fake_post(url, json, timeout):
        return _FakeSummarizeResponse()
    monkeypatch.setattr(main, "_http_client", type("C", (), {"post": staticmethod(fake_post)})())

    async def fake_wait_for_job(job_id, timeout):
        return {"status": "failed", "retryable": True, "error": "요약 시간 초과"}
    monkeypatch.setattr(main.jobs, "wait_for_job", fake_wait_for_job)

    result = await main._call_summarize_api("https://x")

    assert result is None
```

파일 맨 위에 `import pytest`가 없다면 추가한다.

- [ ] **Step 2: 테스트 실행해서 실패 확인**

Run: `cd watch-runner && pytest tests/test_main.py -v`
Expected: FAIL — `main.jobs` 모듈 미참조, `_call_summarize_api`가 아직 옛
방식(세마포어+동기 대기).

- [ ] **Step 3: `main.py` 수정**

`watch-runner/main.py` 상단 import에 `import jobs` 추가.

`_summarize_sem = asyncio.Semaphore(SUMMARIZE_CONCURRENCY)` 줄과
`SUMMARIZE_CONCURRENCY = int(os.getenv("SUMMARIZE_CONCURRENCY", "4"))` 줄을
**삭제**.

`_call_summarize_api`를 아래로 교체(기존 주석은 더 이상 정확하지 않으므로
같이 교체):

```python
async def _call_summarize_api(url: str) -> str | None:
    # job 생성 요청은 가벼운 INSERT + 202 응답이라 10초면 충분하다. 실제 요약
    # 작업 대기는 jobs.wait_for_job의 300초 상한이 담당 — watch-ai의
    # AI_CONCURRENCY 큐잉이 아무리 길어져도 여기서 응답을 조용히 유실하지
    # 않는다(대기만 하다 300초를 넘기면 None을 반환해 기존 pending_summaries
    # 재시도 로직으로 넘어간다).
    try:
        res = await _http_client.post(f"{WATCH_AI_URL}/summarize", json={"url": url}, timeout=10)
        res.raise_for_status()
        job_id = res.json()["job_id"]
    except Exception as e:
        logger.error("watch-ai 요청 실패 (%s): %s", url, e)
        return None

    row = await jobs.wait_for_job(job_id, timeout=300)
    if row is None:
        return None
    if row["status"] == "done":
        return row["result"]["result"]
    if not row["retryable"]:
        raise _PermanentSummaryFailure(row["error"])
    return None
```

`lifespan`을 아래로 교체:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    global _scheduler, _http_client
    await db.init()
    async with httpx.AsyncClient() as client:
        _http_client = client
        executor.set_client(client)
        listener_task = await jobs.start_listener(os.environ["DATABASE_URL"])
        fallback_task = jobs.start_fallback_poll()
        _scheduler = await create_scheduler(run_crawler, run_batch)
        _scheduler.start()
        yield
        _scheduler.shutdown()
        listener_task.cancel()
        fallback_task.cancel()
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

Run: `cd watch-runner && pytest tests/test_main.py -v`
Expected: PASS

- [ ] **Step 5: 전체 회귀 확인**

Run: `cd watch-runner && pytest -v`
Expected: 기존 `_resolve_summaries` 관련 테스트를 포함해 전부 PASS(그
테스트들은 `_call_summarize_api`가 아니라 `_resolve_item_summary`/
`_call_summarize_api`를 monkeypatch로 대체하므로 영향 없음).

- [ ] **Step 6: Commit**

```bash
git add watch-runner/main.py watch-runner/tests/test_main.py
git commit -m "feat: _call_summarize_api를 job 대기 방식으로 교체"
```

---

### Task 7: `watch-infra` — `SUMMARIZE_CONCURRENCY` 제거

**Files:**
- Modify: `watch-infra/docker-compose.yml`
- Modify: `watch-infra/.env.example`

**Interfaces:** 없음(설정 파일 변경).

- [ ] **Step 1: `docker-compose.yml`에서 watch-runner 서비스의
  `- SUMMARIZE_CONCURRENCY=${SUMMARIZE_CONCURRENCY:-4}` 줄 삭제**

- [ ] **Step 2: `.env.example`에서 `SUMMARIZE_CONCURRENCY` 관련 줄 삭제**

- [ ] **Step 3: compose 파일이 여전히 유효한지 확인**

Run: `cd watch-infra && docker compose config`
Expected: 에러 없이 파싱됨(실제 값 채우기 전이라 `DATABASE_URL` 등 일부
경고는 나올 수 있음 — 그건 무시).

- [ ] **Step 4: Commit**

```bash
git add watch-infra/docker-compose.yml watch-infra/.env.example
git commit -m "chore: 더 이상 안 쓰는 SUMMARIZE_CONCURRENCY 제거"
```

---

### Task 8: `watch-runner` — `executor.py`의 불필요한 전역 세마포어 제거

이 Task는 콜백/job 설계와 무관한 별도 발견 사항이다. `executor.py`의
`asyncio.Semaphore(1)`이 서로 무관한 크롤러 컨테이너 9개 전체를 하나의 락
뒤에 줄 세우고 있었다 — watch-playwright에 의존하는 크롤러 보호는 이미
watch-playwright 자신의 `MAX_CONCURRENCY` 세마포어가 하고 있어서 이 락은
중복이었고, 나머지 크롤러(YouTube API 호출 등)에는 지연만 만들고 있었다.

**Files:**
- Modify: `watch-runner/executor.py`
- Test: `watch-runner/tests/test_executor.py` (신규)

**Interfaces:**
- Produces: `execute(crawler: dict) -> list[dict]`(시그니처 동일, 내부 동작만
  변경 — 더 이상 전역 락을 거치지 않는다).

- [ ] **Step 1: 지금의 버그(불필요한 직렬화)를 드러내는 실패 테스트 작성**

`watch-runner/tests/test_executor.py` 생성:

```python
import asyncio
import time

import executor


class _FakeResponse:
    status_code = 200

    def json(self):
        return []


class _FakeClient:
    def __init__(self, delay=0.05):
        self.delay = delay
        self.max_concurrent = 0
        self._current = 0

    async def post(self, url, json, timeout):
        self._current += 1
        self.max_concurrent = max(self.max_concurrent, self._current)
        try:
            await asyncio.sleep(self.delay)
            return _FakeResponse()
        finally:
            self._current -= 1


async def test_execute_runs_concurrently_across_different_crawlers():
    client = _FakeClient(delay=0.05)
    executor.set_client(client)
    crawlers = [{"container": f"crawler-{i}", "params": {}} for i in range(4)]

    start = time.monotonic()
    await asyncio.gather(*[executor.execute(c) for c in crawlers])
    elapsed = time.monotonic() - start

    assert client.max_concurrent == 4
    assert elapsed < 0.05 * 2  # 지금처럼 직렬화되면 4 * 0.05 = 0.2초 이상 걸림
```

- [ ] **Step 2: 테스트 실행해서 실패 확인 (지금 버그를 재현)**

Run: `cd watch-runner && pytest tests/test_executor.py -v`
Expected: FAIL — `client.max_concurrent == 1`이고 `elapsed`가 0.1초를 넘김
(전역 세마포어(1) 때문에 직렬화됨).

- [ ] **Step 3: `executor.py`에서 전역 세마포어 제거**

`watch-runner/executor.py` 전체를 아래로 교체:

```python
import re

import httpx

_http_client: httpx.AsyncClient | None = None

# 크롤러 에러 메시지에 API 키 등이 쿼리스트링으로 섞여 알림까지 새는 것을 막는 방어선.
# 개별 크롤러가 놓친 경우를 대비한 것이라 시크릿 패턴을 열거하지 않고 URL 쿼리스트링 자체를 제거한다.
_QUERYSTRING_RE = re.compile(r"(https?://[^\s'\"]+?)\?[^\s'\"]*")


def set_client(client: httpx.AsyncClient):
    global _http_client
    _http_client = client


def _strip_querystrings(text: str) -> str:
    return _QUERYSTRING_RE.sub(r"\1", text)


async def execute(crawler: dict) -> list[dict]:
    target = crawler["container"]
    params = crawler.get("params") or {}
    res = await _http_client.post(f"http://{target}:8080/crawl", json=params, timeout=60)
    if res.status_code != 200:
        body = _strip_querystrings(res.text[:300])
        raise Exception(f"{target} 응답 {res.status_code}: {body}")
    return res.json()
```

(`import asyncio`와 `_semaphore` 정의가 사라진 것 외에는 동일 — `async with
_semaphore:` 블록만 벗겨냈다.)

- [ ] **Step 4: 테스트 실행해서 통과 확인**

Run: `cd watch-runner && pytest tests/test_executor.py -v`
Expected: PASS — `max_concurrent == 4`, `elapsed < 0.1`

- [ ] **Step 5: 전체 회귀 확인**

Run: `cd watch-runner && pytest -v`
Expected: 전부 PASS.

- [ ] **Step 6: Commit**

```bash
git add watch-runner/executor.py watch-runner/tests/test_executor.py
git commit -m "fix: executor의 불필요한 전역 세마포어 제거 (watch-playwright 보호는 자체 세마포어가 이미 담당)"
```

---

### Task 9: 수동 통합 검증 (배포 전, 자동화 테스트 아님)

Task 1~6의 유닛테스트는 전부 mock 기반이라, 실제 Postgres LISTEN/NOTIFY가
동작하는지, 리스너 커넥션이 끊겨도 폴백 폴링이 커버하는지, 세마포어 큐잉이
실제로 유실 없이 늦게라도 도착하는지는 실제 컨테이너로 한 번 확인해야 한다.
이 Task는 체크리스트이며 커밋 대상 산출물이 없다.

**Files:** 없음(검증만).

- [ ] **Step 1: 로컬 Postgres + 마이그레이션 적용**

```bash
docker run -d --rm --name jobs-test-pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=watchdb -p 15432:5432 postgres:16
sleep 3
docker run --rm --network host \
  -v "$PWD/watch-infra/db:/db" \
  -e DATABASE_URL="postgresql://postgres:test@localhost:15432/watchdb?sslmode=disable" \
  -e DBMATE_NO_DUMP_SCHEMA=true \
  amacneil/dbmate:2 up
```

- [ ] **Step 2: watch-ai 이미지를 빌드하고 `AI_CONCURRENCY=1`로 기동해서
  큐잉을 인위적으로 만든다**

```bash
docker build -t watch-ai:jobs-test watch-ai
docker run -d --rm --name jobs-test-ai --network host \
  -e DATABASE_URL="postgresql://postgres:test@localhost:15432/watchdb?sslmode=disable" \
  -e AI_CONCURRENCY=1 -e GEMINI_API_KEY="${GEMINI_API_KEY}" \
  -p 18010:8080 watch-ai:jobs-test
```

- [ ] **Step 3: 동시에 요청 2개를 보내 둘 다 job_id를 즉시 받는지 확인**

```bash
curl -s -X POST http://localhost:18010/summarize -H "Content-Type: application/json" \
  -d '{"url": "https://www.youtube.com/watch?v=<영상1>"}' &
curl -s -X POST http://localhost:18010/summarize -H "Content-Type: application/json" \
  -d '{"url": "https://www.youtube.com/watch?v=<영상2>"}' &
wait
```

Expected: 둘 다 즉시(1초 이내) `{"job_id": "..."}`와 함께 202 반환.

- [ ] **Step 4: 두 번째 job이 큐잉됐다가도 결국 `done`으로 끝나는지 DB로 확인**

```bash
sleep 130  # 두 번째 job이 처리(최대 110s)까지 끝날 시간을 넉넉히 확보
docker exec jobs-test-pg psql -U postgres -d watchdb -c \
  "SELECT id, status, retryable FROM async_jobs ORDER BY created_at;"
```

Expected: 두 행 모두 `status = done`. (`AI_CONCURRENCY=1`이라 두 번째는
첫 번째가 끝날 때까지 대기했다가 처리된 것 — 이게 바로 예전엔 클라이언트
타임아웃 때문에 유실되던 경로다.)

- [ ] **Step 5: 리스너 커넥션이 끊겨도 폴백 폴링이 결과를 회수하는지 확인**

watch-runner를 붙여서(또는 `jobs.py`를 대화형으로 import해) `start_listener`로
연결한 상태에서, `jobs-test-pg` 컨테이너를 `docker restart jobs-test-pg`로
잠깐 끊었다가 살린 뒤에도, 이미 던져둔 job의 결과가 30초 폴백 폴링 주기
안에 `wait_for_job`을 통해 정상적으로 회수되는지 확인한다.

- [ ] **Step 6: 정리**

```bash
docker stop jobs-test-ai jobs-test-pg
```
