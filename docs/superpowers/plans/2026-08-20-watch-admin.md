# watch-admin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `watch-admin`, a small internal web UI that lets the operator toggle crawlers on/off (with automatic scheduler reload) and edit crawler schedule/params/filter/post_process without touching the database directly.

**Architecture:** A new FastAPI + Jinja2 server-rendered service (`watch-admin`), no JS build step, talks to Postgres directly via `asyncpg` and to `watch-runner`'s existing `POST /reload` over the Docker-internal network. `watch-runner` gets a small addition (`crawlers.last_error` tracking) so the admin UI can show why a crawler is failing. `watch-infra` gets the new service wired into `docker-compose.yml` plus one migration.

**Tech Stack:** Python 3.11, FastAPI, Jinja2, asyncpg, httpx, pytest + pytest-asyncio (unit tests only, no CI test gate — matches this codebase's existing convention of zero test infrastructure).

**Spec:** `docs/superpowers/specs/2026-08-20-watch-admin-design.md`

## Global Constraints

- Base image `python:3.11-slim`, `CMD ["python", "main.py"]`, no `ENTRYPOINT` — matches every other service in this org. `init: true` is set in `docker-compose.yml` (already true for all 9 existing services), so PID1-zombie risk does not apply here even though this service doesn't spawn subprocesses.
- No JS framework, no build step — server-rendered Jinja2 templates, inline `<style>`, no external CDN/asset requests (works fine offline on the LAN).
- No app-level authentication. Access control is network isolation only — the port is published in `docker-compose.yml` the same way `watch-runner`'s `8001` is, and is expected to only be reachable over LAN/Tailscale (no router port-forward).
- `params` / `filter` / `post_process` are edited as raw JSON text (`textarea`), not structured per-field forms.
- `container` field is read-only in the UI — never written by `watch-admin`.
- Every DB write in `watch-admin` (`toggle`, `save`) must be followed by a `POST /reload` call to `watch-runner`; a failed reload must not roll back the DB write, and must surface as a banner on the list page (`?reload_error=1`).
- CI workflow files follow the exact pattern already used by every other repo in this org (`actions/checkout@v4` → `docker build` → `docker compose up -d --no-deps <service>`, `self-hosted` runner, `paths-ignore: ['**.md']`). No test step in CI — this repo family doesn't run tests in CI anywhere.
- Deployment order matters: `watch-admin`'s own image must exist on the N2+ host (via its first CI run) **before** `watch-infra`'s `docker-compose.yml` change referencing `image: watch-admin` is pushed, or `watch-infra`'s `apply.sh` (`docker compose up -d`) will fail trying to start a service with no local image.

---

## Task 1: `watch-admin` repo scaffold + health check

**Files:**
- Create: `watch-admin/Dockerfile`
- Create: `watch-admin/requirements.txt`
- Create: `watch-admin/requirements-dev.txt`
- Create: `watch-admin/pytest.ini`
- Create: `watch-admin/main.py`
- Create: `watch-admin/tests/conftest.py`
- Create: `watch-admin/tests/test_main.py`
- Create: `watch-admin/.gitignore`

**Interfaces:**
- Produces: `main.py` module with a FastAPI `app` object and `GET /health`. Later tasks import `db`, `validation`, `reload` into this file and add routes to `app`.

- [ ] **Step 1: Create the repo directory and git init**

```bash
mkdir -p /c/Users/sj/Documents/work/code/coft/watch-admin
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git init
```

- [ ] **Step 2: Write `.gitignore`**

```
__pycache__/
*.pyc
.env
.pytest_cache/
```

- [ ] **Step 3: Write `requirements.txt`**

```
fastapi
uvicorn
asyncpg
httpx
jinja2
python-multipart
```

- [ ] **Step 4: Write `requirements-dev.txt`**

```
-r requirements.txt
pytest
pytest-asyncio
```

- [ ] **Step 5: Write `pytest.ini`**

```ini
[pytest]
asyncio_mode = auto
```

- [ ] **Step 6: Install dev dependencies locally**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
python -m venv .venv
.venv/Scripts/pip install -r requirements-dev.txt
```

- [ ] **Step 7: Write the failing test for `/health`**

`tests/test_main.py`:

```python
from fastapi.testclient import TestClient

import main


def test_health_returns_ok():
    client = TestClient(main.app)

    res = client.get("/health")

    assert res.status_code == 200
    assert res.json() == {"status": "ok"}
```

`tests/conftest.py` (empty for now, filled in by Task 4 and Task 5):

```python
```

- [ ] **Step 8: Run test to verify it fails**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'main'` (file doesn't exist yet).

- [ ] **Step 9: Write minimal `main.py`**

```python
from fastapi import FastAPI

app = FastAPI()


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8080, loop="asyncio")
```

- [ ] **Step 10: Run test to verify it passes**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v
```

Expected: PASS

- [ ] **Step 11: Write `Dockerfile`**

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "main.py"]
```

- [ ] **Step 12: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add Dockerfile requirements.txt requirements-dev.txt pytest.ini main.py tests/ .gitignore
git commit -m "feat: watch-admin 스캐폴딩 + /health"
```

---

## Task 2: `validation.py` — JSON field parsing

**Files:**
- Create: `watch-admin/validation.py`
- Create: `watch-admin/tests/test_validation.py`

**Interfaces:**
- Produces: `parse_json_fields(params_raw: str, filter_raw: str, post_process_raw: str) -> tuple[dict, dict]`. Returns `(parsed, errors)` where `parsed` has keys `"params"`, `"filter"`, `"post_process"` (each `dict | None`, `None` for a blank/whitespace-only input), and `errors` has the same keys but only for fields that failed to parse (value is the `str(JSONDecodeError)` message). Task 8 (`main.py` save route) calls this directly.

- [ ] **Step 1: Write the failing tests**

`tests/test_validation.py`:

```python
from validation import parse_json_fields


def test_valid_json_all_fields():
    parsed, errors = parse_json_fields(
        '{"keyword": "python"}', '{"title_keywords": ["a"]}', '{"type": "summarize"}'
    )

    assert errors == {}
    assert parsed == {
        "params": {"keyword": "python"},
        "filter": {"title_keywords": ["a"]},
        "post_process": {"type": "summarize"},
    }


def test_blank_field_becomes_none():
    parsed, errors = parse_json_fields("", "   ", "")

    assert errors == {}
    assert parsed == {"params": None, "filter": None, "post_process": None}


def test_invalid_json_reports_error_for_that_field_only():
    parsed, errors = parse_json_fields("{not valid", "", "")

    assert "params" in errors
    assert "filter" not in errors
    assert "post_process" not in errors


def test_multiple_invalid_fields_all_reported():
    parsed, errors = parse_json_fields("{bad", "[bad", "")

    assert set(errors.keys()) == {"params", "filter"}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_validation.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'validation'`

- [ ] **Step 3: Write `validation.py`**

```python
import json

_FIELDS = ("params", "filter", "post_process")


def parse_json_fields(params_raw: str, filter_raw: str, post_process_raw: str) -> tuple[dict, dict]:
    raw = {"params": params_raw, "filter": filter_raw, "post_process": post_process_raw}
    parsed: dict = {}
    errors: dict = {}
    for field in _FIELDS:
        text = raw[field].strip()
        if not text:
            parsed[field] = None
            continue
        try:
            parsed[field] = json.loads(text)
        except json.JSONDecodeError as e:
            errors[field] = str(e)
    return parsed, errors
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_validation.py -v
```

Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add validation.py tests/test_validation.py
git commit -m "feat: JSON 필드 파싱/검증 추가"
```

---

## Task 3: `reload.py` — call `watch-runner`'s `/reload`

**Files:**
- Create: `watch-admin/reload.py`
- Create: `watch-admin/tests/test_reload.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `call_reload(client: httpx.AsyncClient) -> bool` — `True` if `watch-runner` accepted the reload, `False` on any exception (connection error, timeout, non-2xx). Reads `WATCH_RUNNER_URL` env var (default `http://watch-runner:8080`) at call time. Task 6 and Task 8 (`main.py` routes) call this with the shared app-level `httpx.AsyncClient`.

- [ ] **Step 1: Write the failing tests**

`tests/test_reload.py`:

```python
from unittest.mock import AsyncMock, MagicMock

import httpx

from reload import call_reload


async def test_call_reload_returns_true_on_success():
    client = AsyncMock()
    response = MagicMock()
    response.raise_for_status = MagicMock()
    client.post = AsyncMock(return_value=response)

    result = await call_reload(client)

    assert result is True
    client.post.assert_awaited_once()
    args, kwargs = client.post.call_args
    assert args[0].endswith("/reload")


async def test_call_reload_returns_false_on_connect_error():
    client = AsyncMock()
    client.post = AsyncMock(side_effect=httpx.ConnectError("boom"))

    result = await call_reload(client)

    assert result is False


async def test_call_reload_returns_false_on_http_error():
    client = AsyncMock()
    response = MagicMock()
    response.raise_for_status = MagicMock(
        side_effect=httpx.HTTPStatusError("500", request=MagicMock(), response=MagicMock())
    )
    client.post = AsyncMock(return_value=response)

    result = await call_reload(client)

    assert result is False
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_reload.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'reload'`

- [ ] **Step 3: Write `reload.py`**

```python
import os

import httpx

WATCH_RUNNER_URL = os.environ.get("WATCH_RUNNER_URL", "http://watch-runner:8080")


async def call_reload(client: httpx.AsyncClient) -> bool:
    try:
        res = await client.post(f"{WATCH_RUNNER_URL}/reload", timeout=10)
        res.raise_for_status()
        return True
    except Exception:
        return False
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_reload.py -v
```

Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add reload.py tests/test_reload.py
git commit -m "feat: watch-runner reload 호출 함수 추가"
```

---

## Task 4: `db.py` — crawler CRUD

**Files:**
- Create: `watch-admin/db.py`
- Modify: `watch-admin/tests/conftest.py`
- Create: `watch-admin/tests/test_db.py`

**Interfaces:**
- Produces:
  - `async def init()` — creates `_pool` from `DATABASE_URL` env var, registers the `jsonb` codec (same pattern as `watch-runner/db.py`).
  - `async def list_crawlers() -> list[dict]` — all crawlers, columns `id, name, enabled, fail_count, last_error, last_run, schedule, batch_group`, ordered by `id`. (`last_error` column doesn't exist yet — added in Task 10 — but this query can be written now; it'll error at runtime against today's DB until that migration lands. That's fine, this repo isn't deployed until Task 13.)
  - `async def get_crawler(crawler_id: int) -> dict | None` — columns `id, name, container, enabled, schedule, batch_group, params, filter, post_process`.
  - `async def toggle_crawler(crawler_id: int) -> None` — flips `enabled`.
  - `async def update_crawler(crawler_id: int, *, enabled: bool, schedule: str, batch_group: str | None, params: dict | None, filter_: dict | None, post_process: dict | None) -> None`.
- Task 5–8 (`main.py` routes) call these four functions directly via `import db`.

- [ ] **Step 1: Write the fake-pool test fixtures**

`tests/conftest.py` (replace the empty file from Task 1):

```python
import pytest


class FakeConn:
    def __init__(self):
        self.fetch_return = []
        self.fetchrow_return = None
        self.fetch_calls = []
        self.fetchrow_calls = []
        self.execute_calls = []

    async def fetch(self, query, *args):
        self.fetch_calls.append((query, args))
        return self.fetch_return

    async def fetchrow(self, query, *args):
        self.fetchrow_calls.append((query, args))
        return self.fetchrow_return

    async def execute(self, query, *args):
        self.execute_calls.append((query, args))


class _FakeAcquireCtx:
    def __init__(self, conn):
        self._conn = conn

    async def __aenter__(self):
        return self._conn

    async def __aexit__(self, exc_type, exc, tb):
        return False


class FakePool:
    def __init__(self, conn: FakeConn):
        self._conn = conn

    def acquire(self):
        return _FakeAcquireCtx(self._conn)


@pytest.fixture
def fake_conn():
    return FakeConn()


@pytest.fixture
def fake_pool(fake_conn):
    return FakePool(fake_conn)
```

- [ ] **Step 2: Write the failing tests**

`tests/test_db.py`:

```python
import db


async def test_list_crawlers_returns_rows_and_orders_by_id(fake_pool, fake_conn, monkeypatch):
    fake_conn.fetch_return = [
        {"id": 1, "name": "kakao", "enabled": True, "fail_count": 0,
         "last_error": None, "last_run": None, "schedule": "*/5 * * * *", "batch_group": None}
    ]
    monkeypatch.setattr(db, "_pool", fake_pool)

    result = await db.list_crawlers()

    assert result == fake_conn.fetch_return
    query, args = fake_conn.fetch_calls[0]
    assert "FROM crawlers" in query
    assert "ORDER BY id" in query
    assert args == ()


async def test_get_crawler_returns_dict_when_found(fake_pool, fake_conn, monkeypatch):
    fake_conn.fetchrow_return = {
        "id": 3, "name": "wanted", "container": "crawler-wanted", "enabled": True,
        "schedule": "0 7,17 * * *", "batch_group": None,
        "params": {"keyword": "python"}, "filter": None, "post_process": None,
    }
    monkeypatch.setattr(db, "_pool", fake_pool)

    result = await db.get_crawler(3)

    assert result == fake_conn.fetchrow_return
    query, args = fake_conn.fetchrow_calls[0]
    assert "WHERE id = $1" in query
    assert args == (3,)


async def test_get_crawler_returns_none_when_missing(fake_pool, fake_conn, monkeypatch):
    fake_conn.fetchrow_return = None
    monkeypatch.setattr(db, "_pool", fake_pool)

    result = await db.get_crawler(999)

    assert result is None


async def test_toggle_crawler_flips_enabled(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)

    await db.toggle_crawler(5)

    query, args = fake_conn.execute_calls[0]
    assert "enabled = NOT enabled" in query
    assert args == (5,)


async def test_update_crawler_writes_all_fields(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)

    await db.update_crawler(
        3, enabled=False, schedule="0 7,17 * * *", batch_group="daily",
        params={"keyword": "python"}, filter_=None, post_process={"type": "summarize"},
    )

    query, args = fake_conn.execute_calls[0]
    assert args == (3, False, "0 7,17 * * *", "daily", {"keyword": "python"}, None, {"type": "summarize"})
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_db.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'db'`

- [ ] **Step 4: Write `db.py`**

```python
import json
import os

import asyncpg

_pool: asyncpg.Pool | None = None


async def _init_conn(conn: asyncpg.Connection):
    await conn.set_type_codec(
        "jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog"
    )


async def init():
    global _pool
    _pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], init=_init_conn)


def get_pool() -> asyncpg.Pool:
    return _pool


async def list_crawlers() -> list[dict]:
    async with _pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT id, name, enabled, fail_count, last_error, last_run, schedule, batch_group "
            "FROM crawlers ORDER BY id"
        )
        return [dict(r) for r in rows]


async def get_crawler(crawler_id: int) -> dict | None:
    async with _pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, name, container, enabled, schedule, batch_group, params, filter, post_process "
            "FROM crawlers WHERE id = $1",
            crawler_id,
        )
        return dict(row) if row else None


async def toggle_crawler(crawler_id: int):
    async with _pool.acquire() as conn:
        await conn.execute(
            "UPDATE crawlers SET enabled = NOT enabled WHERE id = $1", crawler_id
        )


async def update_crawler(
    crawler_id: int,
    *,
    enabled: bool,
    schedule: str,
    batch_group: str | None,
    params: dict | None,
    filter_: dict | None,
    post_process: dict | None,
):
    async with _pool.acquire() as conn:
        await conn.execute(
            "UPDATE crawlers SET enabled = $2, schedule = $3, batch_group = $4, "
            "params = $5, filter = $6, post_process = $7 WHERE id = $1",
            crawler_id, enabled, schedule, batch_group, params, filter_, post_process,
        )
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_db.py -v
```

Expected: PASS (5 passed)

- [ ] **Step 6: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add db.py tests/conftest.py tests/test_db.py
git commit -m "feat: crawlers 테이블 CRUD 함수 추가"
```

---

## Task 5: `GET /` — crawler list page

**Files:**
- Modify: `watch-admin/main.py`
- Create: `watch-admin/templates/list.html`
- Modify: `watch-admin/tests/conftest.py`
- Modify: `watch-admin/tests/test_main.py`

**Interfaces:**
- Consumes: `db.list_crawlers()` (Task 4), `db.init()` (Task 4).
- Produces: app-level `lifespan` context manager that calls `db.init()` on startup; a `client` pytest fixture (added to `conftest.py`) that monkeypatches `db.init` to a no-op and yields a `TestClient` — every later route test reuses this fixture.

- [ ] **Step 1: Add the `client` fixture**

Append to `tests/conftest.py`:

```python
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient

import main


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main.db, "init", AsyncMock())
    with TestClient(main.app) as c:
        yield c
```

- [ ] **Step 2: Write the failing test**

Replace the whole contents of `tests/test_main.py` with (this switches `test_health_returns_ok` from its own inline `TestClient(main.app)` to the new `client` fixture, and adds the two list-page tests):

```python
from unittest.mock import AsyncMock

import main


def test_health_returns_ok(client):
    res = client.get("/health")

    assert res.status_code == 200
    assert res.json() == {"status": "ok"}


def test_list_page_shows_crawler_name(client, monkeypatch):
    monkeypatch.setattr(main.db, "list_crawlers", AsyncMock(return_value=[
        {"id": 1, "name": "kakao-channels", "enabled": True, "fail_count": 0,
         "last_error": None, "last_run": None, "batch_group": None}
    ]))

    res = client.get("/")

    assert res.status_code == 200
    assert "kakao-channels" in res.text


def test_list_page_shows_reload_error_banner(client, monkeypatch):
    monkeypatch.setattr(main.db, "list_crawlers", AsyncMock(return_value=[]))

    res = client.get("/?reload_error=1")

    assert "reload" in res.text.lower() or "실패" in res.text
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v
```

Expected: FAIL — `404 Not Found` for `GET /` (route doesn't exist yet).

- [ ] **Step 4: Create `templates/list.html`**

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>watch-admin</title>
<style>
  body { font-family: sans-serif; margin: 2rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ccc; padding: 0.5rem; text-align: left; }
  .fail-warn { color: #b00020; font-weight: bold; }
  .banner { background: #fee; border: 1px solid #b00020; padding: 0.75rem; margin-bottom: 1rem; }
  button { cursor: pointer; }
</style>
</head>
<body>
<h1>크롤러 목록</h1>
{% if reload_error %}
<div class="banner">설정은 저장됐지만 watch-runner reload 실패 — 상태 확인 필요</div>
{% endif %}
<table>
<tr>
  <th>이름</th><th>활성</th><th>실패</th><th>마지막 에러</th><th>마지막 실행</th><th>배치그룹</th><th></th>
</tr>
{% for c in crawlers %}
<tr>
  <td>{{ c.name }}</td>
  <td>
    <form method="post" action="/crawlers/{{ c.id }}/toggle" style="display:inline">
      <button type="submit">{{ "ON" if c.enabled else "OFF" }}</button>
    </form>
  </td>
  <td class="{{ 'fail-warn' if c.fail_count >= max_fail_count else '' }}">{{ c.fail_count }}</td>
  <td title="{{ c.last_error or '' }}">{{ (c.last_error or '')[:60] }}</td>
  <td>{{ c.last_run or '-' }}</td>
  <td>{{ c.batch_group or '-' }}</td>
  <td><a href="/crawlers/{{ c.id }}">편집</a></td>
</tr>
{% endfor %}
</table>
</body>
</html>
```

- [ ] **Step 5: Wire `main.py`**

Replace `main.py` with:

```python
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.templating import Jinja2Templates

import db

MAX_FAIL_COUNT = int(os.getenv("MAX_FAIL_COUNT", "5"))

templates = Jinja2Templates(directory="templates")

_http_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _http_client
    await db.init()
    async with httpx.AsyncClient() as client:
        _http_client = client
        yield


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def list_crawlers(request: Request):
    crawlers = await db.list_crawlers()
    reload_error = request.query_params.get("reload_error") is not None
    return templates.TemplateResponse(
        "list.html",
        {
            "request": request,
            "crawlers": crawlers,
            "reload_error": reload_error,
            "max_fail_count": MAX_FAIL_COUNT,
        },
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8080, loop="asyncio")
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v
```

Expected: PASS (3 passed: health, list shows name, list shows banner)

- [ ] **Step 7: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add main.py templates/list.html tests/conftest.py tests/test_main.py
git commit -m "feat: 크롤러 목록 페이지 추가"
```

---

## Task 6: `POST /crawlers/{id}/toggle`

**Files:**
- Modify: `watch-admin/main.py`
- Modify: `watch-admin/tests/test_main.py`

**Interfaces:**
- Consumes: `db.toggle_crawler(crawler_id)` (Task 4), `reload.call_reload(client)` (Task 3).
- Produces: route `POST /crawlers/{crawler_id}/toggle` returning a 303 redirect to `/` (success) or `/?reload_error=1` (reload failed). Imports `call_reload` as a bare name into `main`'s namespace (`from reload import call_reload`) so tests can monkeypatch `main.call_reload` directly.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_main.py`:

```python
def test_toggle_calls_db_and_reload_then_redirects_home(client, monkeypatch):
    toggle_mock = AsyncMock()
    monkeypatch.setattr(main.db, "toggle_crawler", toggle_mock)
    monkeypatch.setattr(main, "call_reload", AsyncMock(return_value=True))

    res = client.post("/crawlers/5/toggle", follow_redirects=False)

    toggle_mock.assert_awaited_once_with(5)
    assert res.status_code == 303
    assert res.headers["location"] == "/"


def test_toggle_reload_failure_redirects_with_error_flag(client, monkeypatch):
    monkeypatch.setattr(main.db, "toggle_crawler", AsyncMock())
    monkeypatch.setattr(main, "call_reload", AsyncMock(return_value=False))

    res = client.post("/crawlers/5/toggle", follow_redirects=False)

    assert res.headers["location"] == "/?reload_error=1"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v -k toggle
```

Expected: FAIL — `404 Not Found` (route doesn't exist yet).

- [ ] **Step 3: Add the route to `main.py`**

Add near the top, alongside the other imports:

```python
from fastapi.responses import RedirectResponse

from reload import call_reload
```

Add the route below `list_crawlers`:

```python
@app.post("/crawlers/{crawler_id}/toggle")
async def toggle(crawler_id: int):
    await db.toggle_crawler(crawler_id)
    ok = await call_reload(_http_client)
    return RedirectResponse("/" if ok else "/?reload_error=1", status_code=303)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v -k toggle
```

Expected: PASS (2 passed)

- [ ] **Step 5: Run the full suite to check nothing broke**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest -v
```

Expected: all passing

- [ ] **Step 6: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add main.py tests/test_main.py
git commit -m "feat: enabled 토글 + 자동 reload 라우트 추가"
```

---

## Task 7: `GET /crawlers/{id}` — edit form

**Files:**
- Modify: `watch-admin/main.py`
- Create: `watch-admin/templates/edit.html`
- Modify: `watch-admin/tests/test_main.py`

**Interfaces:**
- Consumes: `db.get_crawler(crawler_id)` (Task 4).
- Produces: `_json_dump(value) -> str` helper in `main.py` (used again by Task 8's error path); route `GET /crawlers/{crawler_id}` rendering `edit.html`, 404 if the crawler doesn't exist.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_main.py`:

```python
def test_edit_form_prefills_json_fields(client, monkeypatch):
    monkeypatch.setattr(main.db, "get_crawler", AsyncMock(return_value={
        "id": 3, "name": "wanted", "container": "crawler-wanted", "enabled": True,
        "schedule": "0 7,17 * * *", "batch_group": None,
        "params": {"keyword": "python"}, "filter": None, "post_process": None,
    }))

    res = client.get("/crawlers/3")

    assert res.status_code == 200
    assert '"keyword": "python"' in res.text
    assert "crawler-wanted" in res.text


def test_edit_form_404_when_crawler_missing(client, monkeypatch):
    monkeypatch.setattr(main.db, "get_crawler", AsyncMock(return_value=None))

    res = client.get("/crawlers/999")

    assert res.status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v -k edit_form
```

Expected: FAIL — `404` for the prefill test (route missing), or `AssertionError` on status.

- [ ] **Step 3: Create `templates/edit.html`**

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>{{ crawler.name }} 편집</title>
<style>
  body { font-family: sans-serif; margin: 2rem; max-width: 640px; }
  label { display: block; margin-top: 1rem; font-weight: bold; }
  textarea, input[type=text] { width: 100%; box-sizing: border-box; font-family: monospace; }
  textarea { height: 6rem; }
  .error { color: #b00020; font-size: 0.9rem; }
  .readonly { color: #666; }
</style>
</head>
<body>
<h1>{{ crawler.name }} 편집</h1>
<p class="readonly">id: {{ crawler.id }} / container: {{ crawler.container }}</p>
<form method="post" action="/crawlers/{{ crawler.id }}">
  <label><input type="checkbox" name="enabled" value="on" {{ "checked" if crawler.enabled else "" }}> enabled</label>

  <label for="schedule">schedule (cron)</label>
  <input type="text" id="schedule" name="schedule" value="{{ crawler.schedule }}">

  <label for="batch_group">batch_group</label>
  <input type="text" id="batch_group" name="batch_group" value="{{ crawler.batch_group or '' }}">

  <label for="params">params (JSON)</label>
  <textarea id="params" name="params">{{ params_raw }}</textarea>
  {% if errors.params %}<div class="error">{{ errors.params }}</div>{% endif %}

  <label for="filter">filter (JSON)</label>
  <textarea id="filter" name="filter">{{ filter_raw }}</textarea>
  {% if errors.filter %}<div class="error">{{ errors.filter }}</div>{% endif %}

  <label for="post_process">post_process (JSON)</label>
  <textarea id="post_process" name="post_process">{{ post_process_raw }}</textarea>
  {% if errors.post_process %}<div class="error">{{ errors.post_process }}</div>{% endif %}

  <p><button type="submit">저장</button> <a href="/">취소</a></p>
</form>
</body>
</html>
```

- [ ] **Step 4: Add the route to `main.py`**

Add near the top:

```python
import json

from fastapi import HTTPException
```

Add below the `toggle` route:

```python
def _json_dump(value) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) if value is not None else ""


@app.get("/crawlers/{crawler_id}")
async def edit_form(request: Request, crawler_id: int):
    crawler = await db.get_crawler(crawler_id)
    if crawler is None:
        raise HTTPException(status_code=404)
    return templates.TemplateResponse(
        "edit.html",
        {
            "request": request,
            "crawler": crawler,
            "params_raw": _json_dump(crawler["params"]),
            "filter_raw": _json_dump(crawler["filter"]),
            "post_process_raw": _json_dump(crawler["post_process"]),
            "errors": {},
        },
    )
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v -k edit_form
```

Expected: PASS (2 passed)

- [ ] **Step 6: Run the full suite**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest -v
```

Expected: all passing

- [ ] **Step 7: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add main.py templates/edit.html tests/test_main.py
git commit -m "feat: 크롤러 편집 폼 추가"
```

---

## Task 8: `POST /crawlers/{id}` — save (validate + write + reload)

**Files:**
- Modify: `watch-admin/main.py`
- Modify: `watch-admin/tests/test_main.py`

**Interfaces:**
- Consumes: `validation.parse_json_fields` (Task 2), `db.get_crawler` / `db.update_crawler` (Task 4), `call_reload` (Task 3), `_json_dump` (Task 7).
- Produces: route `POST /crawlers/{crawler_id}`. On validation failure: re-renders `edit.html` with HTTP 400, preserves the user's raw textarea input, shows per-field errors, does not call `db.update_crawler`. On success: writes, calls reload, redirects 303 to `/` or `/?reload_error=1`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_main.py`:

```python
def test_save_invalid_json_does_not_write_and_shows_error(client, monkeypatch):
    monkeypatch.setattr(main.db, "get_crawler", AsyncMock(return_value={
        "id": 3, "name": "wanted", "container": "crawler-wanted", "enabled": True,
        "schedule": "0 7,17 * * *", "batch_group": None,
        "params": {}, "filter": None, "post_process": None,
    }))
    update_mock = AsyncMock()
    monkeypatch.setattr(main.db, "update_crawler", update_mock)

    res = client.post("/crawlers/3", data={
        "schedule": "0 7,17 * * *", "batch_group": "",
        "params": "{not valid json", "filter": "", "post_process": "",
    })

    assert res.status_code == 400
    update_mock.assert_not_awaited()
    assert "{not valid json" in res.text


def test_save_valid_json_writes_and_redirects(client, monkeypatch):
    update_mock = AsyncMock()
    monkeypatch.setattr(main.db, "update_crawler", update_mock)
    monkeypatch.setattr(main, "call_reload", AsyncMock(return_value=True))

    res = client.post("/crawlers/3", data={
        "enabled": "on", "schedule": "0 7,17 * * *", "batch_group": "",
        "params": '{"keyword": "python"}', "filter": "", "post_process": "",
    }, follow_redirects=False)

    assert res.status_code == 303
    assert res.headers["location"] == "/"
    update_mock.assert_awaited_once_with(
        3, enabled=True, schedule="0 7,17 * * *", batch_group=None,
        params={"keyword": "python"}, filter_=None, post_process=None,
    )


def test_save_unchecked_enabled_saves_false(client, monkeypatch):
    update_mock = AsyncMock()
    monkeypatch.setattr(main.db, "update_crawler", update_mock)
    monkeypatch.setattr(main, "call_reload", AsyncMock(return_value=True))

    client.post("/crawlers/3", data={
        "schedule": "0 7,17 * * *", "batch_group": "",
        "params": "", "filter": "", "post_process": "",
    }, follow_redirects=False)

    _, kwargs = update_mock.call_args
    assert kwargs["enabled"] is False
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v -k save
```

Expected: FAIL — `405 Method Not Allowed` (POST route doesn't exist yet).

- [ ] **Step 3: Add the route to `main.py`**

Add near the top:

```python
from fastapi import Form

from validation import parse_json_fields
```

Add below the `edit_form` route:

```python
@app.post("/crawlers/{crawler_id}")
async def save(
    request: Request,
    crawler_id: int,
    enabled: str | None = Form(None),
    schedule: str = Form(...),
    batch_group: str = Form(""),
    params: str = Form(""),
    filter: str = Form(""),
    post_process: str = Form(""),
):
    parsed, errors = parse_json_fields(params, filter, post_process)
    if errors:
        crawler = await db.get_crawler(crawler_id)
        return templates.TemplateResponse(
            "edit.html",
            {
                "request": request,
                "crawler": {
                    **crawler,
                    "enabled": enabled is not None,
                    "schedule": schedule,
                    "batch_group": batch_group or None,
                },
                "params_raw": params,
                "filter_raw": filter,
                "post_process_raw": post_process,
                "errors": errors,
            },
            status_code=400,
        )

    await db.update_crawler(
        crawler_id,
        enabled=enabled is not None,
        schedule=schedule,
        batch_group=batch_group or None,
        params=parsed["params"],
        filter_=parsed["filter"],
        post_process=parsed["post_process"],
    )
    ok = await call_reload(_http_client)
    return RedirectResponse("/" if ok else "/?reload_error=1", status_code=303)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest tests/test_main.py -v -k save
```

Expected: PASS (3 passed)

- [ ] **Step 5: Run the full suite**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
.venv/Scripts/pytest -v
```

Expected: all passing (should be ~19 tests total across all files)

- [ ] **Step 6: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add main.py tests/test_main.py
git commit -m "feat: 크롤러 설정 저장 라우트 추가 (JSON 검증 포함)"
```

---

## Task 9: `watch-admin` CI, README, local Docker smoke test

**Files:**
- Create: `watch-admin/.github/workflows/deploy.yml`
- Create: `watch-admin/README.md`

**Interfaces:** none (this task doesn't add code, only deploy plumbing and docs).

- [ ] **Step 1: Write `.github/workflows/deploy.yml`**

Match the exact pattern used by every other repo in this org (verified against `crawler-saramin`, `crawler-wanted`, `crawler-workhub`, `watch-runner`, `watch-sender` — all identical apart from the service name):

```yaml
name: Deploy

on:
  push:
    branches: [main]
    paths-ignore:
      - '**.md'

jobs:
  deploy:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4

      - name: Build image
        run: docker build -t watch-admin .

      - name: Restart service
        run: docker compose -f $HOME/watch-infra/docker-compose.yml up -d --no-deps watch-admin
```

- [ ] **Step 2: Write `README.md`**

```markdown
# watch-admin

크롤러 제어용 내부 admin 페이지. `crawlers` 테이블을 직접 읽고 쓰며,
enabled 토글이나 설정 저장 후에는 `watch-runner`의 `POST /reload`를 호출해
스케줄러에 즉시 반영한다.

## 페이지

| 경로 | 메서드 | 설명 |
|---|---|---|
| `/` | GET | 크롤러 목록 (활성 여부, 실패 횟수, 마지막 에러, 마지막 실행) |
| `/crawlers/{id}` | GET | 편집 폼 (schedule, batch_group, params/filter/post_process JSON) |
| `/crawlers/{id}` | POST | 편집 저장 — JSON 파싱 실패 시 DB에 쓰지 않고 폼을 에러와 함께 재표시 |
| `/crawlers/{id}/toggle` | POST | enabled 플립, 목록 화면에서 원클릭 |

`params`/`filter`/`post_process`는 raw JSON textarea로 편집한다 — 크롤러마다
구조가 달라 필드별 폼으로 만들면 유지비가 더 들기 때문. `container`는
읽기 전용이다(배포된 Docker 서비스 이름에 고정된 값이라 여기서 바꾸면
존재하지 않는 서비스를 가리킬 수 있음).

## 환경변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `DATABASE_URL` | (필수) | PostgreSQL 연결 문자열 |
| `WATCH_RUNNER_URL` | `http://watch-runner:8080` | 토글/저장 후 reload 호출 대상 |
| `MAX_FAIL_COUNT` | 5 | 목록에서 fail_count를 강조 표시하는 기준 (watch-runner와 동일 값 공유) |

## 인증

없음. 접근 통제는 네트워크 격리로만 한다 — `watch-runner`의 `8001`과 같은
방식으로 포트를 노출하고, 라우터에서 포트포워딩을 하지 않는 한 LAN/Tailscale
안에서만 닿는다.

## 배포 순서 주의

이 repo가 최소 1회 자체 CI로 이미지를 빌드하기 전에는 `watch-infra`의
`docker-compose.yml`에 `watch-admin` 서비스를 추가해서 push하면 안 된다 —
`docker compose up -d`는 `image:`만 있으면 빌드하지 않고 기존 로컬 이미지를
찾으므로, 이미지가 없으면 그 배포가 실패한다.
```

- [ ] **Step 3: Local Docker smoke test (build only — no DB, so don't run it standalone)**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
docker build -t watch-admin .
```

Expected: build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
git add .github/workflows/deploy.yml README.md
git commit -m "docs: watch-admin CI/README 추가"
```

---

## Task 10: `watch-runner` — record `last_error`

**Files:**
- Modify: `watch-runner/db.py`
- Modify: `watch-runner/main.py`
- Create: `watch-runner/tests/conftest.py`
- Create: `watch-runner/tests/test_db.py`
- Create: `watch-runner/pytest.ini`
- Modify: `watch-runner/README.md`

**Interfaces:**
- Modifies: `increment_fail_count(crawler_id: int) -> int` becomes `increment_fail_count(crawler_id: int, error_msg: str) -> int`. `update_success(crawler_id: int)` now also clears `last_error`.
- Both call sites (`run_crawler`, `run_batch` in `main.py`) already have `str(e)` in scope at the point they call `increment_fail_count` — this task only threads that value through.

`watch-runner` has no existing test infrastructure (`README.md`/repo inspection confirmed zero test files). This task adds a minimal `pytest.ini` + fake-pool tests scoped only to the two functions this task touches — not a general test-suite retrofit.

- [ ] **Step 1: Write `pytest.ini`**

```ini
[pytest]
asyncio_mode = auto
```

- [ ] **Step 2: Write the fake-pool fixtures**

`tests/conftest.py`:

```python
import pytest


class FakeConn:
    def __init__(self):
        self.fetchrow_return = None
        self.execute_calls = []
        self.fetchrow_calls = []

    async def fetchrow(self, query, *args):
        self.fetchrow_calls.append((query, args))
        return self.fetchrow_return

    async def execute(self, query, *args):
        self.execute_calls.append((query, args))


class _FakeAcquireCtx:
    def __init__(self, conn):
        self._conn = conn

    async def __aenter__(self):
        return self._conn

    async def __aexit__(self, exc_type, exc, tb):
        return False


class FakePool:
    def __init__(self, conn: FakeConn):
        self._conn = conn

    def acquire(self):
        return _FakeAcquireCtx(self._conn)


@pytest.fixture
def fake_conn():
    return FakeConn()


@pytest.fixture
def fake_pool(fake_conn):
    return FakePool(fake_conn)
```

- [ ] **Step 3: Write the failing tests**

`tests/test_db.py`:

```python
import db


async def test_increment_fail_count_writes_error_message(fake_pool, fake_conn, monkeypatch):
    fake_conn.fetchrow_return = {"fail_count": 3}
    monkeypatch.setattr(db, "_pool", fake_pool)

    result = await db.increment_fail_count(7, "TimeoutError: goto timeout")

    assert result == 3
    query, args = fake_conn.fetchrow_calls[0]
    assert "last_error" in query
    assert args == (7, "TimeoutError: goto timeout")


async def test_update_success_clears_last_error(fake_pool, fake_conn, monkeypatch):
    monkeypatch.setattr(db, "_pool", fake_pool)

    await db.update_success(4)

    query, args = fake_conn.execute_calls[0]
    assert "last_error = NULL" in query
    assert args == (4,)
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-runner
python -m pytest tests/test_db.py -v
```

Expected: FAIL — `TypeError: increment_fail_count() takes 1 positional argument but 2 were given` (current signature only takes `crawler_id`), and the `last_error` assertion fails for `update_success`.

- [ ] **Step 5: Modify `db.py`**

Replace `increment_fail_count` and `update_success` (currently at `db.py:43-57`):

```python
async def update_success(crawler_id: int):
    async with _pool.acquire() as conn:
        await conn.execute(
            "UPDATE crawlers SET last_run = NOW(), fail_count = 0, last_error = NULL WHERE id = $1",
            crawler_id,
        )


async def increment_fail_count(crawler_id: int, error_msg: str) -> int:
    async with _pool.acquire() as conn:
        row = await conn.fetchrow(
            "UPDATE crawlers SET fail_count = fail_count + 1, last_error = $2 "
            "WHERE id = $1 RETURNING fail_count",
            crawler_id, error_msg,
        )
        return row["fail_count"]
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-runner
python -m pytest tests/test_db.py -v
```

Expected: PASS (2 passed)

- [ ] **Step 7: Update the two call sites in `main.py`**

In `run_crawler` (currently `main.py:85-93`), change:

```python
    except Exception as e:
        logger.error("[%s] 오류: %s", crawler_id, e)
        fail_count = await db.increment_fail_count(crawler_id)
```

to:

```python
    except Exception as e:
        logger.error("[%s] 오류: %s", crawler_id, e)
        fail_count = await db.increment_fail_count(crawler_id, str(e))
```

In `run_batch` (currently `main.py:118-120`), change:

```python
        except Exception as e:
            logger.error("[%s] 오류: %s", crawler_id, e)
            await db.increment_fail_count(crawler_id)
```

to:

```python
        except Exception as e:
            logger.error("[%s] 오류: %s", crawler_id, e)
            await db.increment_fail_count(crawler_id, str(e))
```

- [ ] **Step 8: Update `README.md`**

In the "실패 처리" section (currently `README.md:78-80`), change:

```markdown
크롤러 호출/파싱이 예외를 던지면 `fail_count`를 증가시키고 `watch-sender`의 `/error`로 알림을 보낸다. `fail_count`가 `MAX_FAIL_COUNT`에 도달하면 해당 크롤러를 `enabled=false`로 비활성화한다(다음 `/reload` 또는 재시작 시 스케줄러에서 빠짐). 성공 시 `fail_count`는 0으로 리셋된다.
```

to:

```markdown
크롤러 호출/파싱이 예외를 던지면 `fail_count`를 증가시키고 예외 메시지를 `crawlers.last_error`에 기록한 뒤 `watch-sender`의 `/error`로 알림을 보낸다. `fail_count`가 `MAX_FAIL_COUNT`에 도달하면 해당 크롤러를 `enabled=false`로 비활성화한다(다음 `/reload` 또는 재시작 시 스케줄러에서 빠짐). 성공 시 `fail_count`는 0으로 리셋되고 `last_error`도 `NULL`로 지워진다. `last_error`는 `watch-admin`의 크롤러 목록 화면에서 확인할 수 있다.
```

- [ ] **Step 9: Run the full test suite**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-runner
python -m pytest -v
```

Expected: PASS (2 passed — this repo's only tests)

- [ ] **Step 10: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-runner
git add db.py main.py README.md pytest.ini tests/
git commit -m "feat: 크롤러 실패 시 last_error 기록 (watch-admin에서 조회)"
```

---

## Task 11: `watch-infra` — `last_error` migration

**Files:**
- Create: `watch-infra/db/migrations/<timestamp>_add_last_error.sql`

**Interfaces:** none — pure schema change. `watch-admin` (Task 4) and `watch-runner` (Task 10) both already assume this column exists.

- [ ] **Step 1: Determine the migration timestamp**

Follow this repo's existing naming convention (`YYYYMMDDHHMMSS_description.sql`, seen in `db/migrations/20260715150000_destinations_serial_id.sql`). Use a timestamp after the most recent existing migration (`20260715150000`):

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-infra
ls db/migrations/
```

Use `20260820000000_add_crawlers_last_error.sql`.

- [ ] **Step 2: Write the migration**

`db/migrations/20260820000000_add_crawlers_last_error.sql`:

```sql
-- migrate:up
ALTER TABLE crawlers ADD COLUMN last_error TEXT;

-- migrate:down
ALTER TABLE crawlers DROP COLUMN last_error;
```

- [ ] **Step 3: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-infra
git add db/migrations/20260820000000_add_crawlers_last_error.sql
git commit -m "feat: crawlers.last_error 컬럼 추가 마이그레이션"
```

Do **not** push yet — Task 13 pushes this together with the `docker-compose.yml` change, after `watch-admin`'s first image build (per the Global Constraints deployment-order note).

---

## Task 12: `watch-infra` — wire `watch-admin` into `docker-compose.yml` and `README.md`

**Files:**
- Modify: `watch-infra/docker-compose.yml`
- Modify: `watch-infra/README.md`

**Interfaces:** none.

- [ ] **Step 1: Add the `watch-admin` service block**

Add to `docker-compose.yml`, after the `watch-playwright` block (alphabetical-ish grouping doesn't matter here, but keep it near the top with the other non-crawler services for readability):

```yaml
  watch-admin:
    image: watch-admin
    restart: unless-stopped
    init: true
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - WATCH_RUNNER_URL=http://watch-runner:8080
      - MAX_FAIL_COUNT=${MAX_FAIL_COUNT:-5}
    ports:
      - "8002:8080"
```

- [ ] **Step 2: Validate compose syntax**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-infra
DATABASE_URL=postgresql://u:p@h:5432/d YOUTUBE_API_KEY=x GEMINI_API_KEY=x docker compose -f docker-compose.yml config -q && echo VALID
```

Expected: `VALID`

- [ ] **Step 3: Update `README.md` architecture diagram**

In the "인프라 구성" block (currently `README.md:6-24`), add `watch-admin` under the N2+ list:

```
N2+ (메인 앱 서버, ARM64)
├── watch-admin             # 크롤러 제어용 admin 페이지
├── watch-playwright        # 단일 브라우저 서버
├── watch-runner            # 스케줄러 + 중복감지 + 오케스트레이션
├── watch-sender            # 라우팅 + 알림 발송
├── watch-ai                # AI 요약 (Gemini)
├── crawler-kakao-channels  # 카카오 채널 크롤러
├── crawler-yt-channels     # YouTube 채널 크롤러
├── crawler-workhub         # 네이버 카페(SW개발자 취업카페) 크롤러
├── crawler-saramin         # 사람인
└── crawler-wanted          # 원티드
```

- [ ] **Step 4: Update the "외부 노출 포트" sentence**

In the paragraph following the diagram (currently `README.md:26`), change:

```markdown
전부 하나의 ARM64 서버(N2+)에 Docker Compose로 올라가고, DB만 별도 서버(HC4)를 쓴다. 서버가 하나뿐이므로 서비스 간 통신은 전부 Docker 내부 네트워크(서비스명 DNS)로 이뤄지고, 외부에 노출되는 포트는 `watch-runner`의 `8001`(수동 `/reload`, `/status` 호출용) 하나뿐이다.
```

to:

```markdown
전부 하나의 ARM64 서버(N2+)에 Docker Compose로 올라가고, DB만 별도 서버(HC4)를 쓴다. 서버가 하나뿐이므로 서비스 간 통신은 전부 Docker 내부 네트워크(서비스명 DNS)로 이뤄지고, 외부에 노출되는 포트는 `watch-runner`의 `8001`(수동 `/reload`, `/status` 호출용)과 `watch-admin`의 `8002`(크롤러 제어 UI) 두 개뿐이다. 둘 다 앱 레벨 인증은 없고, 라우터에서 포트포워딩을 하지 않는 이상 LAN/Tailscale 안에서만 닿는 걸 전제로 한다.
```

- [ ] **Step 5: Add a "왜 이런 구조인가" entry for `watch-admin`**

Add after the `init: true` entry added in the earlier zombie-process fix (search for `**모든 서비스에 \`init: true\`를 넣은 이유**` in `README.md`):

```markdown
**`watch-admin`을 별도 서비스로 분리한 이유**
크롤러 enabled 토글과 설정 편집을 DB 직접 UPDATE로 처리하다가, 실패 알림이 연속으로 쏟아지는 상황에서 대응이 늦어진 사고가 있었다(2026-08). `watch-runner`가 이미 `:8001`에 HTTP API와 DB 커넥션을 갖고 있었지만, 스케줄링·오케스트레이션이라는 책임에 admin UI를 얹으면 그 책임이 섞인다 — "서비스마다 별도 repo/컨테이너" 컨벤션을 그대로 따라 `watch-admin`을 분리했다. `watch-admin`은 `crawlers` 테이블을 직접 읽고 쓰되, 실제로 스케줄에 반영하는 건 여전히 `watch-runner`의 `POST /reload`에 위임한다 — "중복 감지를 runner가 담당하는 이유"와 같은 맥락으로, 스케줄러 상태를 두 서비스가 따로 들고 있지 않게 하기 위해서다.
```

- [ ] **Step 6: Update the "Docker Compose 서비스" table**

In the table (currently `README.md:51-61`), add a row:

```markdown
| `watch-admin` | 크롤러 제어 admin 페이지 | `8002:8080` | - |
```

- [ ] **Step 7: Update "알려진 미해결 항목" cross-reference (optional context, not required by spec)**

No change needed — the `todo.md` item "fail_count로 자동 비활성화된 크롤러가 복구 후에도 방치됨" is now partially addressed (an operator can now *see and act on* `last_error`/`fail_count` easily) but not fully solved (still no proactive alert on auto-disable). Leave `todo.md` as-is; that's a separate follow-up, not in scope here.

- [ ] **Step 8: Commit**

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-infra
git add docker-compose.yml README.md
git commit -m "feat: watch-admin 서비스를 docker-compose에 추가"
```

Do **not** push yet — see Task 13 for the required deployment order.

---

## Task 13: Deploy

This task is operational, not code. It exists as an explicit step because the deployment order is a real failure mode (see Global Constraints).

**Interfaces:** none.

- [ ] **Step 1: Create the `watch-admin` GitHub repo and push**

Confirm with the user before creating a new remote repo (this is a shared/visible action). Once confirmed:

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-admin
gh repo create bnbnac-watch/watch-admin --private --source=. --remote=origin
git branch -M main
git push -u origin main
```

- [ ] **Step 2: Confirm `watch-admin`'s own CI built the image**

```bash
gh run list --repo bnbnac-watch/watch-admin --limit 3
```

Expected: latest run `completed`, `success`. If the self-hosted runner isn't registered for this new repo, register it first (same process used for the other 9 repos — check the org's runner settings) before this step will succeed.

- [ ] **Step 3: Verify the image exists on N2+**

Ask the user to run on the N2+ host (over their existing SSH access):

```bash
docker images watch-admin
```

Expected: one row, recent `CREATED` timestamp.

- [ ] **Step 4: Push `watch-infra`'s migration + compose changes**

Only after Step 3 confirms the image exists:

```bash
cd /c/Users/sj/Documents/work/code/coft/watch-infra
git push origin main
```

- [ ] **Step 5: Confirm `watch-infra`'s CI applied the migration and started `watch-admin`**

```bash
gh run list --workflow=deploy.yml --repo bnbnac-watch/watch-infra --limit 3
```

Expected: latest run `completed`, `success`.

- [ ] **Step 6: Verify on the server**

Ask the user to run on N2+:

```bash
docker compose ps watch-admin
docker exec watch-infra-watch-admin-1 cat /proc/1/comm   # expect: docker-init (init: true applied)
curl -s http://localhost:8002/health                      # expect: {"status":"ok"}
curl -s http://localhost:8002/ | grep -o '<title>[^<]*'    # expect: <title>watch-admin
```

- [ ] **Step 7: Manual end-to-end check**

Ask the user to open `http://<N2+ LAN or Tailscale IP>:8002/` in a browser, confirm the crawler list renders with real data, toggle one crawler off, and confirm via `docker exec watch-infra-watch-runner-1` + `GET :8001/status` (or the admin page's own next load) that the job disappeared from the scheduler.
