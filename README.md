# watch-infra

전체 시스템의 배포 매니페스트 저장소. 코드는 없고 `docker-compose.yml`, `schema.sql`, 배포 스크립트만 가진다.
각 서비스는 별도 GitHub repo(`bnbnac-watch` org)에서 개발되고, 이 repo는 그것들을 한 서버에서 묶어서 띄우는 역할만 한다.

## 인프라 구성

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

HC4 (DB 서버, 원격)
└── PostgreSQL
    ├── crawlers DB   ← 이 시스템
    └── photos DB     ← 별개 앱과 공유 (동일 인스턴스, 다른 DB)
```

전부 하나의 ARM64 서버(N2+)에 Docker Compose로 올라가고, DB만 별도 서버(HC4)를 쓴다. 서버가 하나뿐이므로 서비스 간 통신은 전부 Docker 내부 네트워크(서비스명 DNS)로 이뤄지고, 외부에 노출되는 포트는 `watch-runner`의 `8001`(수동 `/reload`, `/status` 호출용)과 `watch-admin`의 `8002`(크롤러 제어 UI) 두 개뿐이다. 둘 다 앱 레벨 인증은 없고, 라우터에서 포트포워딩을 하지 않는 이상 LAN/Tailscale 안에서만 닿는 걸 전제로 한다.

## 왜 이런 구조인가

**크롤러마다 별도 repo/컨테이너로 분리한 이유**
사이트마다 크롤링 방식이 근본적으로 다르다 — 사람인은 SSR이라 `httpx`로 바로 GET하면 되고, 원티드/워크허브/카카오채널은 JS 렌더링이 필요해 `watch-playwright`를 거쳐야 하고, YouTube는 REST API 직접 호출이다. 이 이질성을 하나의 크롤러 프레임워크로 억지로 통합하지 않고, 컨테이너 단위로 격리해서 각자 필요한 만큼만 구현하게 했다. 대신 `watch-contract` 패키지(`Item`, `BaseCrawler`/`RenderCrawler`)로 최소한의 공통 인터페이스만 강제한다.
부수 효과로 GitHub Actions self-hosted runner + `docker compose up -d --no-deps <service>` 조합으로 **서비스 단위 부분 배포**가 가능해진다 — 크롤러 하나 고쳐도 전체를 재기동할 필요가 없다.

**`crawlers` 테이블이 실행 단위, `container`는 엔진이라는 분리**
`crawlers.id`(논리적 인스턴스)와 `crawlers.container`(Docker 서비스명)를 분리해서, 같은 컨테이너를 `params`만 바꿔 여러 인스턴스로 재사용한다. 예: `crawler-yt-channels` 하나가 채널별로 여러 `crawlers` row를 가짐. 채널/키워드 추가가 배포 없이 DB INSERT만으로 끝난다.

**중복 감지를 크롤러가 아니라 runner가 담당하는 이유**
크롤러가 자체적으로 "마지막으로 본 글"을 관리하면, 사이트 구조가 바뀌어 파싱이 실패해 빈 리스트를 반환했을 때 그 상태가 그대로 진행되고, 나중에 크롤러를 고쳐 복구하면 그 사이에 놓친 글이 전부 "새 글"로 오인식되어 알림이 폭탄처럼 쏟아진다. runner가 `seen_items`를 갖고 비교하면 크롤러는 매번 "현재 보이는 것"만 반환하면 되고, 크롤러가 실패해도 `seen_items` 상태는 그대로 보존되어 복구 후 자연스럽게 이어진다.

**`batch_group`이 있는 이유**
채널마다 polling 주기·요약 여부·발송 방식이 달라서 전부 같은 잡으로 묶을 수 없다. `batch_group=null`인 크롤러는 각자 독립 스케줄로 즉시 발송하고, 값이 있는 크롤러는 그룹 전체가 하나의 배치 잡으로 실행되어 채널별 조회 → 요약 → destination 기준 그룹핑 → 일괄 발송 순으로 처리된다(예: `youtube-daily`). 배치 그룹 내 중복 감지는 그룹 전체(`seen_items WHERE crawler_id = ANY(그룹 crawler_ids)`)를 기준으로 읽되, 쓰기는 실제로 새 아이템을 발견한 `crawler_id` 하나에만 한다 — 그룹 크기만큼 `seen_items` row가 N배로 불어나는 걸 막기 위해서다.
**제약**: 같은 `batch_group` 내 모든 row는 `schedule` 값이 동일해야 한다. 배치 잡이 하나뿐이라 `scheduler.py`가 그룹의 첫 row(`group_crawlers[0]`) 값만 읽고, 나머지 row의 `schedule`은 조용히 무시된다. `db.get_enabled_crawlers()`에 `ORDER BY`가 없어 "첫 row"가 무엇인지도 보장되지 않으므로, 그룹 내 스케줄을 다르게 넣으면 원인 파악이 어려운 형태로 오동작한다. (미해결 — `todo.md` 참고)

**`watch-playwright`를 단일 상시 브라우저 서버로 둔 이유**
크롤러마다 각자 Chromium을 띄우면 리소스 통제가 안 된다. 대신 브라우저 서버를 하나 두고 크롤러들이 HTTP로 렌더 요청만 보내면, `watch-playwright` 내부 `Semaphore(MAX_CONCURRENCY)`로 동시 Chromium 인스턴스 수를 한곳에서 강제할 수 있다. `RenderCrawler`는 "무엇을 렌더할지"(`render_request`)와 "렌더 결과를 어떻게 파싱할지"(`parse`)만 구현하고, 브라우저 조종 자체는 하지 않는다.

**모든 서비스에 `init: true`를 넣은 이유**
각 서비스 Dockerfile은 `CMD ["python", "main.py"]`로 컨테이너 안에서 python이 PID 1로 직접 실행된다. 리눅스에서 PID 1은 자신이 직접 spawn하지 않은(재부모화된) 자식 프로세스를 reap하지 않는다는 특성이 있는데, `watch-playwright`가 렌더 요청마다 새로 띄우는 Chromium(+렌더러/GPU 자식 프로세스)이 메모리 압박으로 OOM killer에 죽으면 그 자식들이 python(PID 1)으로 재부모화된 채 좀비로 영구히 쌓인다. 실제로 이게 누적되어 프로세스 테이블/유저 프로세스 한도(`ulimit -u`, `pid_max`)에 도달했고, N2+ 서버가 `fork: retry: Resource temporarily unavailable` 에러로 완전히 응답 불능이 되어 재부팅한 사고가 있었다(2026-08-19). `init: true`는 Docker Compose가 내장 tini를 컨테이너 PID 1로 붙여서, 재부모화된 고아 프로세스를 tini가 대신 `wait()`하게 만드는 표준적인 해법이다.

**`watch-admin`을 별도 서비스로 분리한 이유**
크롤러 enabled 토글과 설정 편집을 DB 직접 UPDATE로 처리하다가, 실패 알림이 연속으로 쏟아지는 상황에서 대응이 늦어진 사고가 있었다(2026-08). `watch-runner`가 이미 `:8001`에 HTTP API와 DB 커넥션을 갖고 있었지만, 스케줄링·오케스트레이션이라는 책임에 admin UI를 얹으면 그 책임이 섞인다 — "서비스마다 별도 repo/컨테이너" 컨벤션을 그대로 따라 `watch-admin`을 분리했다. `watch-admin`은 `crawlers` 테이블을 직접 읽고 쓰되, 실제로 스케줄에 반영하는 건 여전히 `watch-runner`의 `POST /reload`에 위임한다 — "중복 감지를 runner가 담당하는 이유"와 같은 맥락으로, 스케줄러 상태를 두 서비스가 따로 들고 있지 않게 하기 위해서다.

**동시성 제어**: `watch-runner/executor.py`가 크롤러 호출을 `Semaphore(1)`로 제한해 크롤러 컨테이너 호출이 한 번에 하나씩만 나가도록 강제한다. cron 스케줄은 크롤러마다 제각각이다 — 채널 성격에 맞는 폴링 주기를 각자 갖도록 설계된 것이지, 충돌을 피하려고 시각을 흩뿌린 것이 아니다. 실제 운영 DB 기준으로도 BobPlus·Wolf처럼 즉시성이 중요한 채널은 `*/5 * * * *`(5분마다)를, 나머지 대부분(WorkHub, Saramin/Wanted의 SLAM·VIO 배치 그룹, 유튜브 구독 채널들)은 `0 7,17 * * *`(하루 2회, 07:00/17:00 KST)를 공유해서 쓴다 — 즉 같은 스케줄을 쓰는 크롤러 10개가 정확히 같은 순간에 같이 트리거된다. 이 동시 트리거를 실제로 순차화해서 흡수하는 게 위 세마포어다.

## Docker Compose 서비스

| 서비스 | 역할 | 포트 | depends_on |
|---|---|---|---|
| `watch-playwright` | 단일 브라우저 렌더 서버 | - | - |
| `watch-sender` | 라우팅 + 알림 발송 | - | - |
| `watch-runner` | 스케줄러 + 중복감지 + 오케스트레이션 | `8001:8080` | watch-playwright, watch-sender |
| `watch-admin` | 크롤러 제어 admin 페이지 | `8002:8080` | - |
| `watch-ai` | Gemini 기반 영상 요약 | - | - |
| `crawler-workhub` | 네이버 카페 크롤러 | - | watch-playwright |
| `crawler-saramin` | 사람인 크롤러 | - | - |
| `crawler-wanted` | 원티드 크롤러 | - | watch-playwright |
| `crawler-yt-channels` | YouTube 크롤러 | - | - |
| `crawler-kakao-channels` | 카카오 채널 크롤러 | - | watch-playwright |

`image:` 값은 레지스트리 접두어 없는 로컬 태그(예: `watch-runner`)다. 각 repo의 `deploy.yml`이 self-hosted runner에서 `docker build -t <image> .`로 직접 빌드하고 바로 `docker compose -f $HOME/watch-infra/docker-compose.yml up -d --no-deps <service>`로 재기동한다 — 외부 이미지 레지스트리(ghcr.io 등)는 실제로는 쓰지 않는다.

## 환경변수 (`.env`)

`.env.example` 기준. 실제 `.env`는 gitignore 대상.

| 변수 | 용도 |
|---|---|
| `DATABASE_URL` | PostgreSQL 연결 문자열 (HC4) — watch-runner/sender/ai가 사용 |
| `YOUTUBE_API_KEY` | crawler-yt-channels가 사용 |
| `GEMINI_API_KEY` | watch-ai가 사용 |
| `MAX_CONCURRENCY` | watch-playwright의 동시 Chromium 인스턴스 수 (기본 1) |
| `SUMMARIZE_CONCURRENCY` | watch-runner가 watch-ai를 호출하는 동시성 제한 (기본 4) |
| `MAX_FAIL_COUNT` | watch-runner가 크롤러를 자동 비활성화하는 연속 실패 횟수 (기본 5) |
| `RPD_LIMIT` | watch-ai의 일일 요약 요청 한도 (기본 1500) |
| `SUMMARIZER` | watch-ai가 사용할 요약 구현체 (기본 `transcript`) |

검색 키워드(사람인/원티드)는 env가 아니라 `crawlers.params`의 `keyword` 값으로 POST body에 실려 온다 — DB만 바꾸면 배포 없이 검색어를 바꿀 수 있게 하기 위한 설계다.

## DB 스키마

`schema.sql`에 정의된 테이블:

```sql
crawlers            -- 실행 단위. schedule, container, params, filter, post_process, batch_group
seen_items          -- 중복 감지. PK(crawler_id, item_id), ON DELETE CASCADE 없음
destinations        -- 발송 대상. type(discord|slack|telegram), config JSONB
crawler_destinations -- crawler ↔ destination 매핑
```

**테이블 존재 여부는 `schema.sql`과 실제 DB(HC4)가 일치**(`crawlers`, `seen_items`, `destinations`, `crawler_destinations` 4개, 2026-07-11 `\dt` 기준 확인). `pending_notifications`(DND용)는 어느 서비스 코드에서도 참조되지 않는다 — `todo.md`에 계획으로만 존재하며 미구현이다.

**버그**: `watch-ai/db.py`는 `ai_usage` 테이블(RPD 카운터)을 조회하는데, 이 테이블은 `schema.sql`에도 없고 **실제 DB에도 존재하지 않는다**(`relation "ai_usage" does not exist` 직접 확인). `/summarize` 호출마다 이 테이블에 INSERT를 시도하므로 지금 상태로는 요약 요청이 매번 실패할 가능성이 높다 — 문서 누락이 아니라 실제 동작하지 않는 버그다.

## 배포

```bash
./apply.sh   # cd watch-infra && docker compose up -d
```

평소에는 각 서비스 repo의 CI가 알아서 부분 배포하므로 수동 실행은 초기 세팅이나 compose 파일 자체를 바꿨을 때만 필요하다.

```bash
# 특정 서비스만 재기동
docker compose up -d --no-deps <service>
```

## 알려진 미해결 항목

`todo.md` 참고 — batch_group 내 schedule 불일치 무경고 처리, DND(방해금지 시간), destination별 알림 coalescing, watch-ai Gemini fileData API 직접 호출.
