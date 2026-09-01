# 요약 비동기 job/콜백 설계

## 배경

2026-08-22 동시성 감사(`coft 동시성 감사`)에서 확인된 진단 ③: `watch-runner`는
`SUMMARIZE_CONCURRENCY`(기본 4)로 `watch-ai`의 `/summarize`를 동시에 여러 개
호출하지만, `watch-ai`는 자체 `AI_CONCURRENCY`(기본 2) 세마포어로만 처리한다.
`SUMMARIZE_TIMEOUT_S`(110초)는 세마포어 획득 **이후**에만 적용되고 대기 시간은
어디에도 안 잡혀서, 뒤쪽 요청은 대기+처리에 최대 220초가 걸릴 수 있다.
`watch-runner`의 클라이언트 타임아웃은 120초라 먼저 끊고 포기하는데, `watch-ai`는
계속 작업을 진행해 Gemini 쿼터만 쓰고 결과는 아무도 받지 않는다.

동일 cron(`44 9 * * *`)에 요약 대상 크롤러(YouTube 채널 5개)가 몰려 있어 이
경합은 새 영상이 며칠에 한 번만 겹쳐도 재현된다. 감사 문서에서 검토한 대안
(세마포어 숫자 정렬, 즉시-거절 fast-fail, 콜백 아키텍처) 중, 이 문제가 가장
시급하다고 판단해 근본 해결책인 콜백 아키텍처로 간다.

**추가 확인(2026-08-30, 계획 수립 중 발견)**: 감사 이후 `watch-runner`에
`pending_summaries` 테이블 기반 재시도 로직이 이미 추가됐다(`db.py:68-84`,
`main.py:55-126`). 요약이 실패하면 그 크롤 사이클에선 발송하지 않고 스킵하고
(`mark_seen`도 안 함), 다음 크롤 사이클에 "새 글"로 다시 잡혀 재시도되며,
`MAX_SUMMARY_ATTEMPTS`(기본 3)회 연속 실패해야 포기하고 요약 없이 발송한다.
자막 없음처럼 재시도해도 의미없는 실패는 `_PermanentSummaryFailure`로 구분해
이 재시도 대상에서 제외된다. 그래서 지금은 "영구 유실"이 아니라 "최대
`MAX_SUMMARY_ATTEMPTS`일만큼 늦게 발송"으로 이미 완화된 상태다 — 다만 근본
원인(타임아웃 경합 때 watch-ai가 계속 작업해 Gemini 쿼터만 낭비하는 것)은
그대로다. 이 발견 덕분에 아래 변경 범위는 `_call_summarize_api`(실제 watch-ai
호출부) 하나로 좁아진다 — 바깥쪽 재시도 계층(`_resolve_summaries`,
`pending_summaries`, `_PermanentSummaryFailure`)은 그대로 두고, 우리 설계의
300초 타임아웃을 기존과 동일한 "실패"로만 인식시키면 된다.

## 목표

- `watch-runner`가 `watch-ai` 응답을 기다리다 클라이언트 타임아웃으로 결과를
  유실시키는 경로를 구조적으로 제거한다.
- `watch-ai`의 `AI_CONCURRENCY` 큐잉 자체는 그대로 두되(용량을 늘리는 게 아니라
  유실을 없애는 것이 목표), 큐잉이 더 이상 데이터 손실로 이어지지 않게 한다.
- 후속에 다른 job 종류가 생겨도 테이블을 새로 만들 필요가 없도록 스키마에
  최소한의 여유(`kind` 컬럼)만 둔다.

## 비목표

- `pending_summaries` 기반 크롤 사이클 간 재시도 로직 변경 없음 — `watch-runner`의
  `_resolve_summaries`/`_PermanentSummaryFailure`/`MAX_SUMMARY_ATTEMPTS`는
  그대로 두고, 그 아래 계층(`_call_summarize_api`)만 교체한다.

- `crawler-kakao-channels` ↔ `watch-playwright` 경로(진단 ⑦)는 이번 스코프
  아니다. 이 경로는 이미 실패 시 빈 리스트로 우아하게 성능 저하될 뿐 데이터
  유실이 없고, 두 서비스 다 stateless(DB 연결 없음)라 같은 방식을 적용하려면
  별도 설계가 필요하다.
- 알림 타이밍 변경 없음 — 한 크롤러의 새 아이템은 지금처럼 요약까지 다 모은
  뒤 한 번에 발송한다. `watch-sender`/포맷터는 건드리지 않는다.
- 여러 job 종류에 대한 실제 디스패치 로직 — 이번엔 `kind='summarize'` 하나만
  구현한다. 스키마만 좁게 짓지 않을 뿐, 범용 job 프레임워크를 만들지 않는다.
- `watch-ai`의 `AI_CONCURRENCY`/`RPD_LIMIT` 정책 변경 없음.

## 전체 구조

3개 repo가 얽힌다.

- **`watch-infra`** — `async_jobs` 테이블 마이그레이션 1개, `docker-compose.yml`/
  `.env.example`에서 `SUMMARIZE_CONCURRENCY` 제거.
- **`watch-ai`** — `/summarize`가 동기 처리 대신 job을 만들고 즉시 202를
  반환하도록 변경. 백그라운드에서 실제 처리 후 결과를 테이블에 쓰고 NOTIFY.
  오래된 pending job을 정리하는 스윕 루프 추가.
- **`watch-runner`** — 전용 LISTEN 커넥션 신설, 재연결 supervisor 추가.
  `_summarize()`를 job 생성 + 콜백 대기 방식으로 재작성. `_summarize_sem`,
  `SUMMARIZE_CONCURRENCY` 제거.

## 데이터 모델

`watch-infra/db/migrations/`에 마이그레이션 추가:

```sql
-- migrate:up
CREATE TABLE async_jobs (
    id          uuid PRIMARY KEY,
    kind        text NOT NULL,
    payload     jsonb NOT NULL,
    status      text NOT NULL DEFAULT 'pending',  -- pending | done | failed
    result      jsonb,
    error       text,
    retryable   boolean NOT NULL DEFAULT true,  -- false면 재시도해도 의미없는 영구 실패(예: 자막 없음)
    created_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz
);
CREATE INDEX async_jobs_kind_status_created_idx
    ON async_jobs (kind, status, created_at);

-- migrate:down
DROP TABLE async_jobs;
```

`kind`는 지금은 `'summarize'`만 쓰지만, 다른 job 종류가 생겨도 테이블을 새로
만들지 않기 위한 최소한의 여유다.

## `watch-ai` 변경

**`POST /summarize`** — 응답 계약이 바뀐다 (동기 결과 → job 접수):

```python
@app.post("/summarize")
async def summarize_video(req: SummarizeRequest):
    job_id = uuid4()
    await db.create_job(job_id, kind="summarize", payload={"url": req.url})
    asyncio.create_task(_process_job(job_id, req.url))
    return JSONResponse({"job_id": str(job_id)}, status_code=202)
```

`_process_job`은 지금 핸들러 안에 있던 로직(세마포어, RPD 체크, 타임아웃)을
그대로 옮긴 것 — 세마포어/타임아웃/RPD 정책은 안 바뀐다:

```python
async def _process_job(job_id: uuid.UUID, url: str):
    async with app.state.semaphore:
        count = await db.increment_usage()
        if count > RPD_LIMIT:
            await db.fail_job(job_id, "RPD 한도 초과", retryable=True)
            return
        try:
            result = await asyncio.wait_for(
                app.state.summarizer.summarize(url), timeout=SUMMARIZE_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            await db.fail_job(job_id, "요약 시간 초과", retryable=True)
            return
        if result is None:
            await db.fail_job(job_id, "자막 없음", retryable=False)
            return
        await db.complete_job(job_id, {"result": result})
```

`retryable`은 `watch-runner`가 `_PermanentSummaryFailure`를 판단하는 근거다 —
지금은 HTTP 404로 구분하던 것을 이 컬럼으로 옮긴 것뿐, 판단 기준(자막 없음만
영구 실패) 자체는 그대로다.

`db.complete_job`/`db.fail_job`은 같은 트랜잭션에서 row를 갱신하고
`pg_notify('async_job_done', job_id)`를 호출한다 — 트랜잭션이 커밋돼야 NOTIFY도
실제로 나가므로, 결과 쓰기와 알림이 항상 같이 성공하거나 같이 실패한다.

**스윕 루프** — `watch-gallery`의 `_sweep_loop`과 동일 패턴으로 추가. 1시간 이상
`pending`으로 남아있는 job은 `watch-ai`가 죽었다 재시작됐거나 백그라운드
task가 유실된 경우이므로 `failed`로 정리한다(관측용 — 이 시점엔 이미 아무도
기다리고 있지 않을 가능성이 높다).

## `watch-runner` 변경

**`lifespan`** — 기존 커넥션 풀과 별개로, 앱 수명 동안 유지되는 전용 LISTEN
커넥션을 하나 연다. 끊기면 감지해서 재연결 후 재`LISTEN`하는 supervisor task를
같이 띄운다.

**`jobs.py`(신규)** — pending future 관리:

```python
_pending: dict[str, asyncio.Future] = {}

def on_notify(job_id: str, row: dict):
    fut = _pending.pop(job_id, None)
    if fut and not fut.done():
        fut.set_result(row)

async def wait_for_job(job_id: str, timeout: int = 300) -> dict | None:
    fut = asyncio.get_event_loop().create_future()
    _pending[job_id] = fut
    try:
        row = await db.get_job(job_id)
        if row["status"] != "pending":       # NOTIFY보다 먼저 끝난 경우
            _pending.pop(job_id, None)
            return row
        return await asyncio.wait_for(fut, timeout=timeout)
    except asyncio.TimeoutError:
        logger.warning("job 대기 타임아웃 (%s)", job_id)
        return None
    finally:
        _pending.pop(job_id, None)
```

`on_notify`는 asyncpg 리스너 콜백(`conn.add_listener(channel, callback)`)이
직접 호출하는 함수가 아니다 — asyncpg 콜백은 `(conn, pid, channel, payload)`를
받고 `payload`가 곧 `job_id`이므로, 그 콜백이 (전용 리스너 커넥션이 아니라
기존 DB 풀로) `await db.get_job(job_id)`를 한 번 조회해 row를 얻은 뒤
`on_notify(job_id, row)`를 호출하는 얇은 래퍼를 하나 둔다.

리스너 콜백이 오기 전에 이미 끝난 job(빠르게 처리된 경우)을 놓치지 않도록
future 등록 직후 한 번 더 상태를 확인한다. 이 체크를 건너뛰어도 아래
폴백 폴링이 있어 정합성은 깨지지 않지만, 반영 지연을 줄여준다.

**폴백 폴링** — 리스너 커넥션이 끊긴 동안 NOTIFY를 놓칠 수 있으므로, `_pending`에
남아있는 job들을 30초 주기로 직접 조회해 상태가 바뀌었으면 같은 방식으로
resolve하는 백그라운드 루프를 둔다. push(NOTIFY)가 정상 경로, poll은 순수
안전망이다.

**`main.py`** — 바뀌는 건 `_call_summarize_api()`뿐이다. 그 위 계층
(`_summarize`, `_resolve_item_summary`, `_resolve_summaries`,
`_PermanentSummaryFailure`, `pending_summaries` 재시도)은 전혀 손대지 않는다 —
이 함수가 지금처럼 "성공 시 요약 문자열 반환, 영구 실패 시
`_PermanentSummaryFailure` 발생, 그 외 실패 시 `None` 반환"이라는 계약만
지키면 위 계층은 그대로 동작한다. `_summarize_sem`, `SUMMARIZE_CONCURRENCY`는
삭제 — job 생성은 가볍고 빨라서 클라이언트 쪽에서 동시성을 제한할 이유가
없어진다.

```python
async def _call_summarize_api(url: str) -> str | None:
    try:
        res = await _http_client.post(f"{WATCH_AI_URL}/summarize", json={"url": url}, timeout=10)
        res.raise_for_status()
        job_id = res.json()["job_id"]
    except Exception as e:
        logger.error("watch-ai 요청 실패 (%s): %s", url, e)
        return None

    row = await jobs.wait_for_job(job_id, timeout=300)
    if row is None:
        return None  # 300초 대기 초과 — pending_summaries가 다음 크롤에서 재시도
    if row["status"] == "done":
        return row["result"]["result"]
    if not row["retryable"]:
        raise _PermanentSummaryFailure(row["error"])
    return None
```

job 생성 요청 자체의 타임아웃은 10초로 충분하다(가벼운 INSERT + 202 응답).
`_summarize()`(`main.py:78-82`)와 `_resolve_item_summary()`(`main.py:85-91`)는
지금처럼 `_call_summarize_api`를 호출하고 `_PermanentSummaryFailure`를 각자의
방식으로 처리하면 되므로 수정이 필요 없다.

## 장애/복구 요약

| 상황 | 처리 |
|---|---|
| 리스너 커넥션 끊김 | 재연결 supervisor가 감지 후 재`LISTEN`. 끊긴 동안은 30초 폴백 폴링이 대신 커버 |
| NOTIFY 유실(리스너 다운 중 발생) | 폴백 폴링이 최대 30초 지연으로 따라잡음 |
| `watch-ai`가 job 처리 중 재시작됨 | 백그라운드 task 유실 → row는 `pending`에 멈춤 → 스윕 루프가 1시간 후 `failed`로 정리, `watch-runner`는 300초 타임아웃으로 이미 포기하고 요약 없이 진행한 상태 |
| `watch-runner` 재시작됨 | in-memory `_pending`/future 전부 소실. 재시작 시점에 대기 중이던 크롤 job 자체도 중단된 것이므로 다음 cron tick에 자연 재시도 |
| job 대기 300초 초과 | 요약 없이 해당 아이템 진행(현재도 동일한 성능 저하 방식) |

## 테스트

- `watch-ai`: `/summarize` 호출 시 즉시 202+`job_id` 응답 검증, 이후 row가
  `done`/`failed`로 전이하는지, RPD 초과·타임아웃 시 `retryable=true`로,
  자막 없음일 때 `retryable=false`로 기록되는지.
- `watch-runner`: NOTIFY 수신 시 올바른 future만 resolve되는지(엉뚱한 job_id
  무시), future 등록 전에 이미 끝난 job을 놓치지 않는지, `retryable=false`
  결과가 `_PermanentSummaryFailure`로 정확히 변환되는지.
- 폴백 폴링: 리스너 커넥션을 강제로 끊은 상태에서 job이 완료돼도 30초 안에
  결과를 받아오는지.
- 유실 재현 테스트: `AI_CONCURRENCY=1`로 낮추고 동시에 요청 2개를 보내 뒤쪽
  요청이 큐잉되면서도 300초 안에 결과를 정상 수신하는지(기존 버그가 재현되지
  않음을 확인).

## 배포 순서

1. `watch-infra` 마이그레이션(`async_jobs` 테이블) 먼저 적용.
2. `watch-ai` 배포. `/summarize` 응답 계약이 바뀌므로, 아직 옛 코드인
   `watch-runner`가 호출하면 `res.json().get("result")`가 `None`이 되어 그
   짧은 창구 동안은 요약이 안 붙는 정도로 저하된다(예외 없이 안전).
3. `watch-runner` 배포. 가능한 한 2번 직후에 붙여서 비호환 창구를 짧게 유지.
4. `watch-infra`의 `docker-compose.yml`/`.env.example`에서
   `SUMMARIZE_CONCURRENCY` 제거는 3번 이후 아무 때나.
