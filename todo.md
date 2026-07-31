# TODO

### batch_group 내 schedule 불일치 시 조용히 무시됨
- `scheduler.py:23` `_add_batch_job()`이 그룹의 batch job을 등록할 때 `group_crawlers[0]["schedule"]`, 즉 그룹 내 **첫 번째 row의 schedule만** 사용함. 나머지 row의 `schedule` 컬럼 값은 batch job 등록에 전혀 반영되지 않음 — 에러/경고 없이 조용히 무시됨.
- `db.get_enabled_crawlers()`에 `ORDER BY`가 없어서 "몇 번째가 첫 번째냐"도 보장된 순서가 아님.
- 실패 시나리오: 같은 batch_group의 row 하나만 schedule을 바꾸면(예: `사람인-VIO`만 스케줄 변경), 바뀐 값은 무시되고 그룹은 여전히 다른 row의 schedule로 돎 — 의도한 시간에 안 도는데 원인 파악이 어려움.
- [ ] `sync_jobs`/`create_scheduler`에서 그룹 내 row들의 schedule이 서로 다르면 로그 경고 (최소한 눈에 띄게)
- [ ] 또는 애플리케이션 레벨에서 같은 batch_group 내 schedule 불일치를 막는 검증 추가 (INSERT/UPDATE 시점 또는 reload 시점)

### destination 방해금지 시간 (DND)
- [ ] destinations.config에 `dnd: {"start": "23:00", "end": "08:00", "tz": "Asia/Seoul"}` 필드 추가
- [ ] DB: `pending_notifications` 테이블 추가 (destination_id, message, payload, send_after)
- [ ] watch-sender: `_dispatch()`에서 DND 체크 → DND 중이면 pending_notifications insert
- [ ] watch-sender: flush job (APScheduler, 1분마다) → send_after 지난 pending 일괄 발송

### watch-sender destination별 알림 coalescing (debounce)
- 배경: 같은 시간 슬롯에 여러 crawler가 동시 실행되면 동일 destination으로 메시지가 연속 발송됨. runner는 "이 슬롯의 job이 모두 끝났다"는 신호를 갖지 않으므로 runner-side 통합은 어렵다.
- 방향: watch-sender가 N초 내에 도착한 동일 destination 알림을 버퍼링 후 한 번에 합쳐서 발송 (debounce)
- DND의 `pending_notifications` 테이블 확장으로 구현 가능 → DND 구현 시 함께 검토
- [ ] `pending_notifications` 테이블에 `send_after` 외 "같은 destination, N초 이내" 묶음 로직 추가
- [ ] watch-sender: 새 알림 수신 시 동일 destination의 pending이 있으면 합산 후 `send_after` 갱신 (debounce 연장)
- [ ] flush job에서 합산된 메시지 단건 발송

### summarizers/gemini_native.py: Gemini fileData API 직접 호출
- 추후 구글측 토큰 완화 시 구현 (260702 현재 약 40분짜리 영상 정도 감당 가능)
- [ ] `watch-ai/summarizers/gemini_native.py`: Gemini fileData API 직접 호출 (`BaseSummarizer` 구현)

### fail_count로 자동 비활성화된 크롤러가 복구 후에도 방치됨
- 배경: Wolf 크롤러(id=5)가 2026-07-11경 원인 불명 실패 6회 후 `MAX_FAIL_COUNT`(5) 초과로 `enabled=false` 자동 전환. 정작 원인(API/네트워크 등)은 그 직후 해소됐지만, 자동 재활성화 로직이 없어 20일간 알림이 안 나간 채 방치됨. 실패 당시 로그도 도커 로그 로테이션으로 유실돼 원래 원인은 특정 못 함.
- watch-runner는 실패 시 자동 OFF만 있고, 임계치 근접/도달이나 실제 비활성화 발생을 알리는 경로가 전혀 없어서 사람이 우연히 눈치채기 전까지 무한정 방치될 수 있음.
- [ ] fail_count가 임계치에 도달해 `enabled=false`로 전환되는 시점에 Discord(또는 별도 destination)로 경고 발송
- [ ] 또는 주기적으로 `enabled=false`인 크롤러 목록을 점검해 알려주는 헬스체크 job 추가

### 컨테이너 로그를 SD카드가 아닌 원격(DB 호스트)으로
- 배경: odroid N2+가 SD카드로 부팅/운영 중이라 로그 write가 누적되면 SD 수명에 안 좋음. 실제로 Wolf 이슈 조사 때도 로컬 로그 로테이션 주기가 짧아서 실패 당시 로그가 이미 유실돼 있었음.
- DB가 있는 호스트(HC4)엔 SSD/HDD가 있으니, 거기로 로그를 포워딩하면 SD 마모와 로그 유실 문제를 같이 줄일 수 있음.
- [ ] docker `syslog` 로깅 드라이버로 HC4의 rsyslog에 포워딩 (컨테이너 추가 없이 가장 가벼운 방법)
- [ ] 네트워크/호스트 단절 시 유실 허용 범위를 어느 정도로 볼지 결정 필요
