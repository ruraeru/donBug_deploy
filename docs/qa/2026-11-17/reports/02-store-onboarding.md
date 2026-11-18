# 02 store-onboarding QA 보고서

## 요약
- 실행한 케이스: 82
- 통과: 79
- 발견: 3건. 치명 0, 높음 0, 중간 0, 낮음 3
- 매장 만들기·조회·수정·코드 조회의 권한 검사는 모두 맞았다. `/me`·`/me/state` 의 session 역할 결정도 맞았다(사장님 N매장, 알바생, 가입 대기, 둘 다인 사용자, 퇴사자). 매장 코드 형식과 유일성에도 문제가 없었다.
- 사용한 사용자: `a02-owner`(매장 3·6·7·8·9·66), `a02-owner2`(매장 11, 매장 3 알바), `a02-staff`(매장 3 알바, 매장 32 사장님), `a02-pending`, `a02-stranger`, `a02-newbie`, `a02-leaver`, `a02-conc`(동시 생성 매장 10개)

## 발견

### [낮음] 본문 파싱·타입 오류의 오류 응답이 `{code, message}` 모양이 아니다
- 재현:
  ```sh
  T=$(qa-user a02-owner)
  curl -s -X POST http://127.0.0.1:18080/api/v1/stores -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"a","address":"a","isSmall":"yes"}'
  curl -s -X POST http://127.0.0.1:18080/api/v1/stores -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"a","address":"a","defaultDeduction":"weird"}'
  curl -s -X POST http://127.0.0.1:18080/api/v1/stores -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d 'not json'
  curl -s http://127.0.0.1:18080/api/v1/stores/abc -H "Authorization: Bearer $T"
  curl -s "http://127.0.0.1:18080/api/v1/me/state?storeId=abc" -H "Authorization: Bearer $T"
  ```
- 기대: 400 `{"code":"...","message":"...","details":...}` (설계서 §1.5, `ApiExceptionHandler` 주석의 "통일")
- 실제: 400 `{"timestamp":"...","status":400,"error":"Bad Request","path":"/api/v1/stores"}`. 이것은 Spring 기본 오류 본문이다. 숫자 범위를 넘는 경로 id(`/stores/99999999999`)도 같은 결과다. `PATCH /stores/{id}` 에 `{"defaultDeduction":"bad"}` 를 보내도 같다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/controller/ApiExceptionHandler.java:17-44` 는 `ApiException`·`MaxUploadSizeExceededException`·`BindException` 만 처리한다. `HttpMessageNotReadableException`(깨진 JSON, enum·Boolean 변환 실패)과 `MethodArgumentTypeMismatchException`(경로·쿼리 숫자 변환 실패)은 처리하지 않는다.
- 영향: FE `ApiClient._error`(`donBug_FE/lib/data/api_client.dart:171-175`)는 `code` 를 `"400"` 으로, 메시지를 "요청을 처리하지 못했어요" 로 바꿔 보여 준다. FE 화면은 이 엔드포인트에 정상 값만 보내므로 지금 사용자가 볼 일은 드물다. 다른 클라이언트나 이후 버전에서 원인을 알 수 없는 안내가 나온다. 모든 엔드포인트에 공통인 문제다(23 robustness 와 겹칠 수 있다).

### [낮음] 상호명 100자·주소 255자 초과를 FE 가 막지 않는다. BE 는 영어 상세와 일반 문구만 돌려준다
- 재현:
  ```sh
  T=$(qa-user a02-owner)
  N=$(printf 'a%.0s' $(seq 101))
  curl -s -X POST http://127.0.0.1:18080/api/v1/stores -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"name\":\"$N\",\"address\":\"a\"}"
  ```
- 기대: "상호명은 100자 이하로 입력해 주세요" 같은 안내, 또는 FE 입력칸 길이 제한
- 실제: 400 `{"code":"VALIDATION_FAILED","message":"요청 값이 올바르지 않아요","details":{"name":"size must be between 0 and 100"}}`. 주소 256자는 `details.address` 가 `"size must be between 0 and 255"` 다. 앞뒤 공백도 길이에 들어간다. 공백 2자 + 100자 + 공백 2자는 저장값이 100자인데도 거절된다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/dto/StoreCreateRequest.java:21,26` 의 `@Size(max = 100)`·`@Size(max = 255)` 에 message 가 없고, trim 하기 전 값을 검사한다. FE `donBug_FE/lib/screens/employer/store_create_screen.dart:93-95` 와 `screens/web/web_create_store_screen.dart` 의 입력칸에는 `maxLength`·`inputFormatters` 가 없다. FE 는 `ApiException.message` 만 토스트로 보여 준다(`store_create_screen.dart:63`).
- 영향: 이름이나 주소가 긴 사장님이 매장 만들기에서 "요청 값이 올바르지 않아요" 만 보고 무엇이 틀렸는지 모른다. `PATCH /stores/{id}` 와 `PATCH /settings` 의 `name` 도 같다(`StoreDto.java:28,32,46`).

### [낮음] 매장 이름에 NUL·줄바꿈 같은 제어문자가 그대로 저장된다
- 재현:
  ```sh
  T=$(qa-user a02-owner)
  curl -s -X POST http://127.0.0.1:18080/api/v1/stores -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"name":"<script>alert(1)</script>\u0000\n탭","address":"a\u0007"}'
  qa-sql "SELECT store_name FROM store WHERE store_id=9"
  ```
- 기대: 제어문자를 거절하거나 제거한다.
- 실제: 201. `name` 은 `"<script>alert(1)</script>\u0000\n탭"` 으로 저장된다(DB `store_name` = `<script>alert(1)</script>\0\n탭`). 주소 끝의 `\u0007` 은 `trim()` 으로 지워졌다. HTML 조각은 Flutter `Text` 로만 그리므로 XSS 는 아니다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/dto/StoreCreateRequest.java:41` 은 `trim()` 만 하고 문자열 가운데의 제어문자는 검사하지 않는다. `StoreService.update`(`StoreService.java:99`)도 같다.
- 영향: 매장 전환 목록과 공유 문구(`store_code_screen.dart:89` 의 `[돈벌래] ${st.name} 매장 코드`)가 깨지거나 여러 줄로 보인다. 알림 제목과 AI 프롬프트에도 그대로 들어간다.

## 참고 (미검증, 버그로 세지 않음)
- 이름 첫 글자가 BMP 밖의 이모지인 매장(`🍰케이크하우스`, 매장 66)을 BE 가 저장하고 돌려주는 것은 확인했다. FE `owner_store_switch_screen.dart:51` 은 `LetterAvatar(st.name.substring(0, 1))` 로 UTF-16 코드 단위 하나만 잘라 쓴다. 그래서 짝 없는 서로게이트가 그려진다. Flutter 화면을 띄우지 못해 깨진 글자로 보이는지 예외가 나는지는 확인하지 못했다.
- 직원과 남의 매장에서 `GET /stores/{id}` 는 403이고 없는 id 는 404다. 그래서 매장 id 의 존재 여부를 알 수 있다. id 가 연속 숫자이고 내용은 노출되지 않아 발견으로 세지 않았다.
- 알바생이 매장을 만들면 그 뒤 storeId 없이 부른 `/me/state` 의 기본 역할은 `employer` 다(`StateService.java:101`). FE 는 첫 로드 때 저장된 사장님 매장을 고른다(`app_store.dart:195`). 설계가 "소유 매장이 있으면 사장님" 이므로 의도된 동작으로 봤다.

## 통과한 케이스
- 새 사용자 `/me`: `ownedStoreId:null`, `ownedStoreIds:[]`, `memberships:[]`
- 새 사용자 `/me/state`: `v:4`, `role:employee`, `employeeStoreId:""`, `ownerStoreId:""`, 빈 배열들
- `POST /stores` 정상: 201, 앞뒤 공백 trim, 이모지 ☕ 저장, 코드 `XXXX-XXXX`, 기본 파트 오픈/미들/마감(480–720/720–1020/1020–1320, need 1, 휴게 30), id 문자열
- `isSmall:true` → sizeMode `under5`. 생략 → `auto`, isSmall true
- `defaultDeduction` `biz33`(FE 값)·`BUSINESS_TAX`(하위 호환) 허용. 생략 → `biz33`
- `{}`, name 만, address 만, 빈 문자열, 공백만, `null` → 400 `VALIDATION_FAILED` 와 필드별 details
- `name: 123` → 문자열 "123" 으로 저장(Jackson 강제 변환, 문제 없음)
- 상호명 100자·주소 255자(한글) 경계값 → 201
- 같은 이름의 매장을 같은 사장님이 여러 개 만들기 → 허용. 코드가 달라 전환 목록에서 구분된다
- `POST /stores` 동시 10개(같은 사용자) → 201 10개, 매장 10개, 코드 10개 모두 다름, 매장마다 파트 3개
- DB 매장 38개 전체가 9자 `XXXX-XXXX` 형식이고, 정규화(대문자·하이픈 제거) 값도 38개 모두 다름. `code` 에 unique 인덱스가 있다
- 코드 문자 집합에 헷갈리는 I·O·0·1 이 없다(`Store.java:19`)
- 인증 없이 `GET /stores/3`·`POST /stores` → 401
- `GET /stores/{id}`: 사장님 200(코드 포함). 재직 알바 200(`code:""`, `monthlyTotals:{}`). 가입 대기자·무소속·다른 매장 사장님 403
- `GET /stores/{id}/code`: 사장님 200. 알바·대기자·무소속·다른 매장 사장님 403
- `PATCH /stores/{id}`: 사장님만 200. 알바·대기자·무소속·다른 매장 사장님 403
- 없는 매장 999999 / -1: GET·code·PATCH → 404 `NOT_FOUND`
- `PATCH` `{}` → 변경 없음 200. name·address 빈 값·공백 → 400 `STORE_REQUIRED_FIELDS`. 앞뒤 공백 trim
- `PATCH` `isSmall:false` → `over5`. `isSmall:null` → 그대로. `defaultDeduction` insurance/none/biz33 반영(DB `4_INSURANCE` 등)
- `PATCH` 로 `code`·`ownerPersonId` 를 보내도 무시된다(코드 변경·소유자 탈취 불가)
- 사장님 N매장 `/me/state`: 기본 `ownerStoreId` = 가장 작은 id(3). `?storeId=7` → employer/7. `?storeId=` 빈 값 → 기본
- `/me/state?storeId=` 다른 사장님 매장·없는 매장 → 403 (FE `reload` 가 4xx 면 storeId 없이 다시 읽는다)
- `/me` 사장님: `ownedStoreId` 첫 매장, `ownedStoreIds` id 순
- 알바생 `/me/state`: employee, `employeeStoreId:3`, 매장 코드 `""`, 다른 직원의 PENDING 행은 안 보임
- 가입 대기자 `/me/state`: employee, `employeeStoreId:3`(대기 매장), 매장 정보와 자기 직원 행만. `/me` memberships `pending`
- 사장님 겸 알바(owner2): 기본 employer(ownerStoreId 11, employeeStoreId 3). `?storeId=3` → employee. `?storeId=11` → employer. 매장 3 은 코드 없이 한 번만 나온다
- 알바가 매장을 만든 뒤: employer, ownerStoreId 새 매장, employeeStoreId 3 유지
- 사장님이 자기 매장 코드로 가입 신청 → 409 `alreadyMember`
- 퇴사자: `/me/state?storeId=3` → 403. 기본 `/me/state` 는 매장·직원 없음. `GET /stores/3` 403
- FE 계약: `createStoreRemote` 의 요청(`name`·`address`·`isSmall`·`defaultDeduction: deduction.name`)과 응답 `id` 사용이 BE 와 맞다. Store 응답 키가 `Store.fromJson` 과 맞다(`ownerPersonId`·`isSmall`·`parts`·`monthlyTotals` 등)
- 테스트 중 내 요청으로 생긴 500 없음(BE 로그 확인)

## 못 한 것
- FE 화면 실행(Flutter): 웹 컨테이너를 띄우지 않았다. 이모지 아바타, 매장 전환 UI, 저장된 `ownerStoreKey` 로 첫 로드하는 동작은 코드로만 확인했다.
- 매장 만들기 뒤 같은 사장님의 다른 기기에 새 매장이 바로 보이는지(`/me/changes` 신호): `POST /stores` 경로에 storeId 가 없어 `StoreChangeInterceptor` 가 신호를 보내지 않는 것은 코드로만 봤다. 실시간 반영은 21번 영역이라 깊게 보지 않았다.
- 확정된 월별 인건비(`monthlyTotals`): 지난달 Payroll 확정 데이터를 API 로 만들 수 없어 비어 있는 경우만 봤다(18번 영역).
- 삭제된 사용자의 토큰으로 매장 만들기: 01번 영역.
