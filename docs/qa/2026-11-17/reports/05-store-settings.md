# 05 store-settings QA 보고서

## 요약

- 실행한 케이스: 78
- 통과: 70
- 발견: 7건. 치명 0, 높음 1, 중간 3, 낮음 3

테스트 데이터: 사장님 `a05-owner`, 매장 10(`BR8W-A6GL`). 다른 사장님 `a05-owner2`, 매장 14. 직원 `a05-staff1`~`a05-staff4`, 매니저 `a05-mgr`(매장 10).

공통 준비:

```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
T=$($QA/qa-user a05-owner)
r() { m=$1; p=$2; shift 2; curl -s -w ' [%{http_code}]\n' -X$m "$B$p" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "$@"; }
```

## 발견

### [높음] 파트 필요 인원(need)에 상한이 없음. 큰 값을 넣으면 근무표 만들기 요청 하나가 CPU 를 수십 분 점유함

- 재현:
  ```sh
  r PUT /stores/10/parts/needs -d '{"needs":[1,1,10000000]}'      # 200. PUT /parts 의 "need" 도 같다(9999 저장 확인)
  time r POST /stores/10/schedule-plans -d '{"from":"2026-12-14","to":"2026-12-14","needs":[],"copyLastWeek":false}'
  # → 200 "unfilled":10000001. 하루·파트 하나에 3.5초 걸림
  r PUT /stores/10/parts/needs -d '{"needs":[1,1,1]}'             # 원복
  ```
- 측정: need 100,000 이면 0.05초, 10,000,000 이면 3.5초로 시간이 need 에 비례한다. `need=2147483647` 도 저장된다(확인함). 이 값이면 하루·파트 하나에 약 750초가 걸릴 것으로 계산된다. 한 달·파트 3개면 수 시간이다. 서버를 지키려고 최댓값으로는 실행하지 않았다.
- 기대: need 에 현실적인 상한이 있어야 한다(FE 입력칸은 `clamp(0, 99)`, `web_settings_screen.dart:464`). 채울 사람이 없으면 루프가 바로 끝나야 한다.
- 실제: 저장 단계에서 하한(0)만 검사한다. 배정 루프는 후보가 없어도 `need` 번 끝까지 돈다.
- 원인:
  - `StoreService.java:195`(PUT parts)와 `StoreService.java:323`(`applyNeeds`)에 음수 검사만 있다.
  - `ShiftService.java:553` 의 `for (long k = have; k < need; k++)` 는 `stopWhenEmpty=false`(`ShiftService.java:295`, schedule-plans)일 때 후보가 없으면 `unfilled++` 하고 `continue` 한다(`:569`).
  - 같은 루프는 요청 본문 `needs` 로도 탈 수 있다(08 영역).
- 영향: 로그인한 누구나 매장을 만들 수 있다. 그래서 아무 사용자나 요청 몇 개로 BE 작업 스레드와 CPU 를 오래 붙잡을 수 있다. 서비스 지연이나 중단으로 이어질 수 있다. `unfilled` 숫자도 비현실적으로 커져 화면에 그대로 나온다.

### [중간] 파트를 지워도 그 파트의 근무와 템플릿에 옛 파트 이름이 남음. 같은 이름 파트를 다시 만들면 옛 근무가 새 파트에 붙음 (FE 안내와 다름)

- 재현:
  ```sh
  # 파트 28 오픈 / 29 미들 / 30 마감 상태에서
  r POST /stores/10/shifts -d '{"date":"2026-12-08","startMin":1020,"endMin":1320,"part":"마감","staffIds":[17]}'   # id 52
  r POST /stores/10/schedule-templates -d '{"name":"a05 템플릿","month":"2026-12"}'                                # 템플릿 8
  r PUT /stores/10/parts -d '{"parts":[{"id":"28","name":"오픈",...},{"id":"29","name":"미들",...}]}'                  # 마감 삭제
  $QA/qa-sql "SELECT schedule_id, part FROM schedule WHERE schedule_id=52"      # → 마감 (그대로)
  $QA/qa-sql "SELECT pattern_json FROM schedule_template WHERE template_id=8"   # → "part":"마감" 그대로
  r PUT /stores/10/parts -d '{"parts":[...오픈, 미들, {"name":"마감","tone":"close","startMin":1080,"endMin":1320}]}'  # 새 파트 "마감"
  # → schedule 52 는 이제 새 "마감" 파트(18:00~) 근무로 보인다. 시각은 17:00~22:00 그대로다.
  ```
- 기대: FE 의 삭제 확인 창 문구를 따른다. 문구는 "저장하면 이 파트로 잡힌 근무는 파트 없는 근무로 바뀌고, 직원의 고정 근무 파트에서도 빠져요."(`web_settings_screen.dart:174`)다. 근무의 `part` 가 비워져야 하고, 템플릿 패턴의 파트도 비워져야 한다.
- 실제: 고정 파트와 직원 기본 파트는 정리된다(통과). 근무(`schedule.part`)와 템플릿 `pattern_json` 의 `part` 는 옛 이름 그대로다.
- 원인: `StoreService.java:274` `dropDeletedParts` 는 직원만 고친다. 메서드 주석과 `savePartList` 주석도 "근무의 part 문자열은 그대로"라고 적혀 있다. 이름 변경 전파(`propagateRenames`)는 근무와 템플릿을 고치지만, 삭제는 고치지 않는다.
- 영향:
  - 지금은 FE 가 모르는 파트 이름을 유동(보라색) 근무로 보여 줘서 겉보기에는 비슷하다(`web_schedule_views.dart:35`).
  - 같은 이름 파트를 다시 만들면 지난 근무와 템플릿 근무가 새 파트로 다시 묶인다. 그러면 파트별 인원 집계, 자동 채우기의 "이미 있음" 계산(`ShiftService.java:547`), 근무 색이 틀어진다.
  - 템플릿을 적용하면 없는 파트 이름의 근무가 계속 만들어진다.

### [중간] 대소문자·전각 문자만 다른 파트 이름이 검증을 통과한 뒤 DB 에서 500

- 재현:
  ```sh
  r PUT /stores/10/parts -d '{"parts":[<기존 3개>,{"name":"Night","startMin":1320,"endMin":1500},{"name":"night","startMin":1320,"endMin":1500}]}'
  # → 500 {"timestamp":..,"status":500,"error":"Internal Server Error"}
  r PUT /stores/10/parts -d '{"parts":[<기존 3개>,{"name":"A","startMin":1320,"endMin":1500},{"name":"Ａ","startMin":1320,"endMin":1500}]}'
  # → 500
  ```
- 기대: 400 `DUPLICATE_PART` "파트 이름이 겹쳐요".
- 실제: 500. BE 로그 `Duplicate entry '10-night' for key 'store_part.uk_store_part_name'`. 트랜잭션은 롤백되어 데이터는 그대로다(확인함).
- 원인:
  - `StoreService.java:198` 의 중복 검사는 Java `HashSet<String>`(대소문자·전각 구분)이다.
  - 그런데 `store_part` 의 유니크 키 `uk_store_part_name`(`entity/StorePart.java:11`)은 `utf8mb4_unicode_ci` 비교다. 이 비교는 대소문자와 전각/반각을 같은 이름으로 본다.
  - FE `saveParts`(`app_store.dart` 2059~)도 `Set<String>` 이라 막지 못한다.
- 영향: 사장님이 영문 파트를 대소문자만 다르게 두 개 만들면 "요청을 처리하지 못했어요"만 뜬다. 왜 저장이 안 되는지 알 수 없다. 웹 저장은 설정 PATCH 다음에 파트 PUT 을 따로 보낸다. 그래서 영업시간 등은 이미 저장되고 파트만 실패한다.

### [중간] `parts` 배열에 `null` 원소가 있으면 500 (NPE)

- 재현: `r PUT /stores/10/parts -d '{"parts":[{"id":"28","name":"오픈","startMin":480,"endMin":720},null]}'`
- 기대: 400 `VALIDATION_FAILED` 또는 `INVALID_PART`.
- 실제: 500. 로그 `NullPointerException: Cannot invoke "...StorePartDto$Item.name()" because "it" is null`, `StoreService.savePartList(StoreService.java:188)`.
- 원인: `StorePartDto.SaveRequest(@NotNull List<Item> parts)` 는 원소 null 을 막지 않는다. `StoreService.java:187` 루프는 원소를 바로 역참조한다. `needs` 쪽은 null 원소를 400 으로 처리한다(`StoreService.java:323`).
- 영향: FE 는 null 을 보내지 않는다. 잘못된 클라이언트 요청이 500 으로 기록된다.

### [낮음] 파트 시각 범위가 FE·근무 API 와 다름 (BE 는 끝 2880, 길이 48시간까지 허용)

- 재현:
  ```sh
  r PUT /stores/10/parts -d '{"parts":[...,{"name":"48h","startMin":0,"endMin":2880}]}'          # 200, 48시간 파트 저장
  r PUT /stores/10/parts -d '{"parts":[{"name":"야간","tone":"close","startMin":1320,"endMin":1560,"breakMin":30,"need":1}]}'  # 200
  r POST /stores/10/schedule-plans -d '{"from":"2026-12-15","to":"2026-12-15","needs":[1],"copyLastWeek":false}'
  # → 미리보기 근무 "startMin":1320,"endMin":1560
  ```
- 기대:
  - 영업시간은 24시간 이하로 막는다(`validateHours`). 파트도 같은 상한(길이 ≤ 1440)이 있어야 한다.
  - FE 설정 화면은 파트 시각을 24:00 까지만 고르게 한다(`web_settings_screen.dart` `newPartRow` 주석).
  - 근무 API 는 `endMin ≤ 1439` 이고 `end <= start` 를 야간으로 본다(`ShiftCommandDto.CreateRequest`).
- 실제:
  - 파트는 `endMin ≤ 2880` 만 검사한다(`StoreService.java:192`). 길이 제한도 휴게(breakMin 999 on 60분 파트 → 200)와 길이 비교도 없다.
  - 이런 파트로 근무표를 만들면 `endMin` 1560 근무가 생긴다. 이런 근무는 단건 근무 API 로는 만들거나 수정할 수 없는 모양이다.
- 영향: FE 로는 만들 수 없는 값이라 지금 사용자 영향은 작다. 다른 클라이언트나 직접 호출로 넣으면 근무 시간과 휴게가 0 이하인 근무가 생길 수 있다.

### [낮음] 본문 파싱 오류(타입 오류·잘못된 enum·깨진 JSON)는 `{code,message}` 가 아닌 Spring 기본 오류 본문

- 재현:
  ```sh
  r PATCH /stores/10/settings -d '{"openMin":"abc"}'         # 400 {"timestamp":..,"status":400,"error":"Bad Request","path":..}
  r PATCH /stores/10/settings -d '{"sizeMode":"bogus"}'      # 같음
  r PUT /stores/10/parts -d '{"parts":[{"name":"x","tone":"pink","startMin":0,"endMin":60}]}'  # 같음
  r PUT /stores/10/parts/needs -d '{"needs":"x"}'            # 같음
  ```
- 기대: `ApiException` 과 같은 `{code, message, details}` 모양.
- 실제: Spring 기본 본문이다. FE `ApiClient._error`(`api_client.dart:174`)는 `code` 없음을 상태 코드로, `message` 없음을 "요청을 처리하지 못했어요"로 대체한다. 그래서 FE 가 죽지는 않는다.
- 원인: `controller/ApiExceptionHandler.java`(38줄)에 `HttpMessageNotReadableException` 처리기가 없다(`ApiException`, `MaxUploadSizeExceeded`, `BindException` 만 있다).
- 영향: 오류 문구가 뭉뚱그려진다. 23(robustness) 영역과 겹칠 수 있다.

### [낮음] 소수 시각이 조용히 잘림

- 재현: `r PATCH /stores/10/settings -d '{"openMin":1.5}'` → 200, `"openMin":1`.
- 기대: 400 (정수 아님).
- 실제: Jackson 이 실수를 Integer 로 잘라서 받는다(`StoreDto.SettingsRequest` 의 `Integer openMin`).
- 영향: FE 는 정수만 보내므로 영향은 거의 없다.

## 통과한 케이스

- 설정 PATCH 정상: 평일 10:00~익일 02:00(1560), 주말 9:00~23:00 저장 → 응답·`/me/state` 반영
- openMin -1 / 1440 / closeMin 2881 → 400 `INVALID_HOURS` "0:00~다음 날 24:00"
- open=close → 400 "평일 영업 종료 시각은…"
- 길이 > 24h(100~1600, 1439~2880) → 400 "24시간을 넘을 수 없습니다"
- 0~1440(정확히 24h) → 200
- 주말 시각 검증도 같은 규칙(코드·FE `validateHours` 문구 일치)
- openMin "abc", 99999999999, `{bad` 깨진 JSON, 빈 본문 → 400 (본문 모양은 위 낮음 건)
- openMin null, `{}` → 200, 아무것도 안 바뀜
- sizeMode over5 → isSmall false, under5 → true, auto → 재직 인원으로 계산
- sizeMode + isSmall 같이 → sizeMode 우선
- isSmall 만(구 앱) → sizeMode over5/under5 로 바뀜(의도된 호환)
- sizeMode "OVER5"(대문자)도 받음, "bogus" → 400
- 자동 규모: 재직 4명 true → 5명째 승인 시 false → 퇴사 처리로 4명 → true. auto 상태에서 under5 → auto 로 돌아오면 다시 계산
- name 공백·빈 문자열 → 400 `STORE_REQUIRED_FIELDS`, 101자 → 400 `VALIDATION_FAILED`
- name 앞뒤 공백 trim, 이모지·HTML 조각 그대로 저장
- defaultDeduction none/biz33 정상, "xx" → 400
- noticeRequiredDefault·substitutePush false 저장, 문자열 "yes" → 400
- 권한: 알바생·매니저·다른 매장 사장님 → settings/parts/needs 모두 403 `FORBIDDEN`. 토큰 없음 → 401. 없는 매장 → 404. storeId "abc" → 400
- 다른 매장 사장님은 매장 10 GET 도 403
- PUT parts: FE 처럼 숫자 id(`28`)·문자열 id(`"29"`) 모두 수정으로 처리
- 문자열 id `part-open` → 새 파트로 추가
- 다른 매장 파트 id(40) → 404, 다른 매장 파트는 안 바뀜
- 같은 id 두 번 → 400 `DUPLICATE_PART`, 같은 이름(trim 뒤) → 400
- parts null·누락 → 400 `VALIDATION_FAILED`
- 이름 51자 → 400, 빈 이름 → 400
- end≤start, start 1440, end 2881 → 400 `INVALID_PART`
- breakMin·need 음수 → 400, tone "pink" → 400
- 이름 변경(오픈→Opening): 근무·직원 기본 파트·고정 파트·템플릿 모두 새 이름으로 전파
- 이름 맞바꾸기(오픈↔미들): 유니크 키 충돌 없이 200, 근무도 맞게 바뀜
- 파트 삭제: 직원 기본 파트 → 남은 첫 파트, 고정 파트에서 빠짐
- 파트 전부 삭제(`[]`) → 200, 직원 part "" / fixedParts 비움, 그 뒤 가입 신청도 정상(part "")
- 생략한 tone 은 기존 값 유지, breakMin·need 생략 시 0·1(PUT 의미)
- 이모지·HTML 파트 이름 저장, `/me/state` 의 parts 모양(id 문자열, tone `.name`) 정상
- PUT needs: 파트 수보다 짧으면 앞만 반영, 길면 남는 값 무시
- needs -1·null → 400 `INVALID_NEED`, 400 일 때 앞 원소도 롤백됨([5,-1] 뒤 need 2 유지)
- needs 누락 → 400
- 400·500 오류 뒤 데이터 롤백 확인(파트 목록 그대로)
- 같은 PUT parts 5개 동시 요청: 2개 200, 3개 500(Duplicate entry), 최종 데이터는 파트 하나만(중복 행 없음). FE 는 저장 중 버튼을 막아 실제로는 안 생기는 상황이라 따로 보고하지 않음(24 영역)

## 못 한 것

- `need=2147483647` 로 근무표 만들기를 실제로 실행하지 않았다. 공유 QA 서버를 수십 분 점유하기 때문이다. 1e5·1e7 측정값으로 외삽했다.
- 월 근무표 자동 채우기(`/schedules/{month}/autofill`, GapFiller)에 큰 need 를 넣는 경우는 코드만 봤다. 후보가 없으면 `break` 하므로 같은 문제는 없어 보인다. 실행은 08 영역에 맡겼다.
- 영업시간 변경이 이미 있는 근무·자동 생성 결과에 주는 영향은 08·10 영역에서 확인할 일이라 깊게 보지 않았다.
- 웹 화면(Flutter)은 띄우지 않았다. FE 동작은 코드로만 대조했다.
