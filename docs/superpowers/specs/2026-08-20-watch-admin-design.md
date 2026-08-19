# watch-admin 설계

## 배경

2026-08 중순, `crawler-kakao-channels`가 5분 간격으로 실패하면서 Slack에 에러 알림이
약 160회 연속 발송됐다. 운영자가 140번째쯤 알아챘고, 끄는 데 DB에 직접
`UPDATE crawlers SET enabled = false`를 친 뒤 `watch-runner`의 `POST /reload`를
별도로 호출해야 했다 — 이 두 단계를 수동으로 처리하느라 대응이 늦어졌다.

크롤러를 끄고/켜고 설정을 바꾸는 걸 UI로 편하게 하기 위한 admin page를 만든다.

## 목표

- 크롤러 목록과 상태(활성 여부, 실패 횟수, 마지막 에러, 마지막 실행 시각)를 한 화면에서 확인
- `enabled` 토글 한 번으로 DB 반영 + 스케줄러 reload까지 즉시 적용 (지금의 2단계 수동 작업 제거)
- `schedule`/`batch_group`/`params`/`filter`/`post_process` 편집을 UI에서 처리 (지금은 DB 직접 UPDATE)

## 비목표

- 앱 레벨 인증/로그인 (네트워크 격리로 충분하다고 판단 — 아래 "네트워크 노출" 참고)
- `destinations`/`crawler_destinations` 관리 (이번 트리거가 된 문제와 무관, 필요해지면 별도 스펙)
- `params`/`filter`/`post_process`의 구조화된 필드별 폼 (크롤러마다 구조가 달라 raw JSON textarea로 충분)
- `container` 필드 편집 (배포된 Docker 서비스 이름에 고정된 값이라 UI에서 바꾸면 존재하지 않는 서비스를 가리킬 위험)

## 전체 구조

3개 repo가 얽힌다.

- **`watch-admin`** (신규 repo) — FastAPI + Jinja2 서버렌더 HTML(빌드 스텝 없음, 기존
  스택과 통일). asyncpg로 `crawlers` 테이블 직접 CRUD, `httpx`로 `watch-runner`의
  `/reload` 호출.
- **`watch-runner`** — 에러 발생 시 `crawlers.last_error`에 메시지를 기록하도록
  `db.py`/`main.py` 소폭 수정.
- **`watch-infra`** — `crawlers.last_error` 마이그레이션 1개, `docker-compose.yml`에
  `watch-admin` 서비스 블록 추가, README 갱신.

```
N2+
├── watch-admin (신규)      # FastAPI + 서버렌더 HTML, DB 직접 접근, :8002 노출
├── watch-runner            # 기존 그대로 (스케줄링), last_error 기록만 추가
└── ... (나머지 8개 서비스 그대로)
```

## 데이터 모델 변경

`watch-infra/db/migrations/`에 마이그레이션 추가:

```sql
-- migrate:up
ALTER TABLE crawlers ADD COLUMN last_error TEXT;

-- migrate:down
ALTER TABLE crawlers DROP COLUMN last_error;
```

`watch-runner` 수정 범위:

- `db.py`
  - `increment_fail_count(crawler_id, error_msg)` — `fail_count + 1`과 함께
    `last_error = $2` 기록하도록 시그니처 확장.
  - `update_success(crawler_id)` — 성공 시 `last_error = NULL`로 리셋(재발 시 옛
    에러 메시지가 화면에 남아 헷갈리는 것 방지).
- `main.py`
  - `run_crawler()`, `run_batch()`의 `except` 블록에서 이미 잡고 있는 `str(e)`를
    `increment_fail_count` 호출에 같이 넘기기만 하면 됨. 그 외 로직 흐름은 안 바뀜.

## `watch-admin` 라우트

```
GET  /                      크롤러 목록
GET  /crawlers/{id}         편집 폼
POST /crawlers/{id}         편집 저장
POST /crawlers/{id}/toggle  enabled 플립 (목록 화면에서 원클릭)
```

### `GET /` — 목록

| 컬럼 | 내용 |
|---|---|
| name | 크롤러 이름 |
| enabled | on/off 토글 버튼 (누르면 즉시 `POST /crawlers/{id}/toggle`) |
| fail_count | 숫자, `MAX_FAIL_COUNT` 이상이면 강조 표시 |
| last_error | 있으면 한 줄로 표시(길면 잘라서, 전체는 title 툴팁) |
| last_run | 타임스탬프 |
| batch_group | 있으면 표시 |
| — | "편집" 링크 → `/crawlers/{id}` |

reload 실패 시 배너(아래 참고)를 상단에 표시.

### `GET /crawlers/{id}` — 편집 폼

- `enabled` 체크박스
- `schedule` — cron 텍스트 입력
- `batch_group` — 텍스트 입력 (빈 값이면 독립 job)
- `params` / `filter` / `post_process` — 각각 raw JSON textarea, 현재 값을
  `json.dumps(indent=2)`로 프리필
- `id`, `name`, `container` — 읽기 전용 표시만

## 저장/토글 흐름

**`POST /crawlers/{id}/toggle`**
1. `UPDATE crawlers SET enabled = NOT enabled WHERE id = $1`
2. `POST http://watch-runner:8080/reload`
3. `/`로 리다이렉트

**`POST /crawlers/{id}`**
1. `params`/`filter`/`post_process` textarea 3개를 서버에서 `json.loads()` 시도.
   하나라도 파싱 실패하면 **DB에 아무것도 쓰지 않고** 폼을 에러 메시지와 함께
   그대로 다시 렌더링(입력값 유지).
2. 파싱 성공하면 한 번의 `UPDATE`로 모든 필드 반영.
3. `POST http://watch-runner:8080/reload`.
4. `/`로 리다이렉트.

**reload 호출 자체가 실패하는 경우** (예: `watch-runner` 재시작 중): DB 업데이트는
이미 커밋됐으므로 되돌리지 않는다. 대신 리다이렉트 후 `/` 상단에 "설정은
저장됐지만 reload 실패 — watch-runner 상태 확인 필요" 배너를 표시한다(flash
메시지 또는 쿼리스트링으로 전달). DB 값과 실제 스케줄러 상태가 잠깐 어긋날 수
있다는 걸 운영자가 알아야 한다.

## 배포/네트워크 노출

`watch-infra/docker-compose.yml`에 추가:

```yaml
  watch-admin:
    image: watch-admin
    restart: unless-stopped
    init: true
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - WATCH_RUNNER_URL=http://watch-runner:8080
    ports:
      - "8002:8080"
```

reload 호출은 Docker 내부 네트워크로 `http://watch-runner:8080`을 쓴다(컨테이너
간 통신, 기존 서비스들도 쓰는 패턴). `8002`는 `watch-runner`의 기존 `8001`과
같은 노출 방식 — 라우터에서 별도 포트포워딩을 하지 않는 한 LAN/Tailscale
안에서만 닿는다. 앱 레벨 인증은 두지 않는다(비목표 참고).

README의 "외부에 노출되는 포트는 watch-runner의 8001 하나뿐이다" 문장을
"8001, 8002 두 개"로 갱신한다.

`watch-admin` repo 자체는 다른 크롤러 repo들과 동일한 패턴을 따른다:
`Dockerfile`(`python:3.11-slim`, `CMD ["python", "main.py"]` — Compose에서
`init: true`를 주므로 PID1 문제 없음), `.github/workflows/deploy.yml`
(self-hosted runner에서 `docker build` 후 `docker compose up -d --no-deps watch-admin`).

**배포 순서 주의점**: `watch-infra`의 compose 파일에 `watch-admin` 블록을 먼저
push하면, `watch-infra`의 CI(`apply.sh` → `docker compose up -d`)가 돌 때
`watch-admin` 이미지가 로컬에 아직 없어 실패한다(compose는 `image:` 필드만
있으면 build 하지 않고 기존 로컬 이미지를 찾는다). 따라서:

1. `watch-admin` repo 생성, 최소 1회 자체 CI로 이미지 빌드
2. 그다음 `watch-infra`에 compose 블록 + 마이그레이션 추가 push

순서로 진행해야 한다.

## 에러 처리 요약

| 상황 | 처리 |
|---|---|
| 편집 폼의 JSON 파싱 실패 | DB 쓰기 없이 폼 재렌더링, 에러 메시지 표시, 입력값 유지 |
| `watch-runner` reload 호출 실패 | DB는 이미 커밋, `/`에 경고 배너 표시 |
| DB 연결 실패 | FastAPI 기본 500 에러로 충분 (내부 도구, 별도 에러 페이지 불필요) |

## 테스트

- `watch-admin`: 라우트 핸들러(JSON 파싱 검증, UPDATE 쿼리, reload 호출) 단위
  테스트. DB는 테스트용 SQLite/mock 대신 실제 로직이 asyncpg에 묶여 있으니
  쿼리 문자열과 파라미터 바인딩을 검증하는 수준으로 충분.
- `watch-runner`: `increment_fail_count`/`update_success` 시그니처 변경에 대한
  기존 테스트가 있다면 업데이트. 없다면 이번 범위에서 새로 추가하지 않음
  (기존 repo에 테스트 스위트가 없는 것으로 보임 — 있다면 구현 단계에서 재확인).
- 수동 테스트: 로컬 docker compose로 9개(+watch-admin) 기동 후, 토글 → 실제
  스케줄러 job 제거 확인(`GET /status`), JSON 오타 입력 시 저장 거부 확인.
