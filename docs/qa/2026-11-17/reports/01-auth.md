# 01 auth QA 보고서

## 요약

- 실행한 케이스: 128개 (토큰 로그인 21, refresh 17, logout 8, JWT 변조·만료 25, 삭제된 사용자 10, 웹 카카오 login/callback 14, CORS 11, 인증 없는 경로 22)
- 통과: 120개
- 발견: 8건 (치명 0, 높음 0, 중간 3, 낮음 5)

공통 준비:

```sh
B=http://127.0.0.1:18080
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
```

참고: 로컬 환경은 `DEV_LOGIN_ENABLED=true`, `TEST_LOGIN_TOKEN=qa-local-test-login-token-123456`, 카카오 REST 키는 비어 있다(`client_id=`).

## 발견

### [중간] 같은 refresh 토큰을 동시에 보내면 1개만 200, 나머지는 500

- 재현:
  ```sh
  R=$(curl -s -X POST $B/api/auth/kakao/token -H 'Content-Type: application/json' -d '{"accessToken":"test_token"}' | jq -r .refreshToken)
  for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/api/auth/refresh -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$R\"}" & done; wait
  ```
- 기대: 1개 200, 나머지 401 `Invalid refresh token` (이미 쓴 토큰과 같은 응답).
- 실제: `1×200, 9×500` (Spring 기본 에러 본문 `{"timestamp":..,"status":500,"error":"Internal Server Error"}`). 로그: `ObjectOptimisticLockingFailureException: Unexpected row count (expected row count 1 but was 0) [delete from refresh_token where id=?]`. 진 요청이 만든 새 refresh 토큰은 롤백돼 DB 에 남지 않는다. 토큰이 중복 발급되지는 않는다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/auth/AuthService.java:96-98`. 잠금 없이 `findByTokenHash` 로 읽은 뒤 `delete(stored)` 한다. 커밋할 때 다른 트랜잭션이 이미 행을 지웠으면 `StaleStateException` 이 나고, 아무도 처리하지 않아서 500 이 된다. `deleteByTokenHash` 의 지운 행 수로 판단하거나 이 예외를 `AuthException` 으로 바꾸면 401 이 된다.
- 영향: FE `api_client.dart:164-165` 는 401/400 이면 "갱신 실패"로 보고 로그인 화면으로 보낸다. 500 이면 예외를 던져 화면에 "요청을 처리하지 못했어요" 를 띄운다. 한 클라이언트 안의 동시 갱신은 `_refreshing` 으로 하나로 묶인다. 하지만 같은 토큰을 공유하는 웹 탭 여러 개가 동시에 401 을 받으면 진 탭은 500 오류를 본다. 24번(concurrency) 영역과 겹친다.

### [중간] 새 사용자의 첫 로그인이 동시에 들어오면 일부가 500 (Duplicate entry)

- 재현: 첫 로그인을 만들려고 테스트알바 계정(kakao_id `-2`, 연결 데이터 0건)을 지운 뒤 동시에 로그인했다.
  ```sh
  $QA/qa-sql "DELETE FROM users WHERE kakao_id='-2'"
  for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/api/auth/kakao/token -H 'Content-Type: application/json' -d '{"accessToken":"qa-local-test-login-token-123456"}' & done; wait
  ```
- 기대: 10개 모두 200, 같은 사용자 하나.
- 실제: `8×200, 2×500`. 로그: `DataIntegrityViolationException: Duplicate entry '-2' for key 'users.UKk4ycaj27putgcujmehwbsrmmc'`. unique 제약 때문에 사용자 행은 1개만 생겼다(`user_id=366`). 데이터는 손상되지 않았다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/auth/AuthService.java:115-129`. `findByKakaoId(...).orElseGet(new User)` 뒤 `save` 하는 조회 후 생성 방식이다. 같은 kakao_id 로 동시에 들어오면 둘 다 "없음"을 보고 INSERT 하고, 진 쪽의 unique 위반을 처리하지 않는다.
- 영향: 카카오 첫 로그인에서 로그인 버튼을 두 번 누르거나 앱·웹이 동시에 로그인하면 한쪽이 "로그인하지 못했어요"(웹 콜백은 `error=login_failed`)를 본다. 다시 시도하면 된다.

### [중간] 카카오 토큰 자리에 한글·이모지·개행·NUL 이 있으면 401 대신 500

- 재현:
  ```sh
  curl -s -w " %{http_code}\n" -X POST $B/api/auth/kakao/token -H 'Content-Type: application/json' -d '{"accessToken":"한글토큰"}'
  curl -s -w " %{http_code}\n" -X POST $B/api/auth/kakao/token -H 'Content-Type: application/json' -d '{"accessToken":"abc\r\nX-Evil: 1"}'
  curl -s -w " %{http_code}\n" -X POST $B/api/auth/kakao/token -H 'Content-Type: application/json' -d '{"accessToken":"😀"}'
  ```
- 기대: 401 `Invalid Kakao access token` (ASCII 오답 토큰 `wrong-token`·숫자 `123`·20KB 문자열은 401 이 나온다).
- 실제: 500. 로그: `java.lang.IllegalArgumentException: invalid header value: "Bearer abc..."`, `at KakaoClient.fetchUser(KakaoClient.java:111)`. JDK 가 CRLF 헤더를 막아서 카카오로 가는 요청에 헤더가 주입되지는 않는다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/auth/kakao/KakaoClient.java:110` 에서 토큰을 그대로 `Authorization` 헤더에 넣는다. `:122` 의 catch 는 `RestClientException` 만 잡는다. 헤더를 만들 때 나는 `IllegalArgumentException` 은 빠져나간다. `verifyAppId`(`:97`, `:102`)도 같은 구조다(로컬은 `app-id` 가 비어 있어 실행되지 않음).
- 영향: 앱 로고를 길게 눌러 여는 테스트 로그인 창(`mobile_boot.dart:84-118`)에서 한글을 잘못 입력하면 "테스트 로그인 실패: 요청을 처리하지 못했어요"가 뜨고 서버 로그에 ERROR 스택이 남는다. 자격 증명 오류가 아니라 서버 오류로 집계된다.

### [낮음] 인증 오류 본문이 `{"error": ...}` 라서 FE 가 메시지를 못 읽음

- 재현:
  ```sh
  curl -s -X POST $B/api/auth/kakao/token -H 'Content-Type: application/json' -d '{"accessToken":"wrong-token"}'
  curl -s -X POST $B/api/auth/refresh -H 'Content-Type: application/json' -d '{"refreshToken":"abc"}'
  ```
- 기대: 다른 API 와 같은 `{code, message, details}` (설계서 §1.5, `ApiExceptionHandler`).
- 실제: `401 {"error":"Invalid Kakao access token"}`, `401 {"error":"Invalid refresh token"}`, `401 {"error":"Refresh token expired"}`. 메시지도 영어다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/auth/AuthExceptionHandler.java:15`. FE `donBug_FE/lib/data/api_client.dart:173-175` 는 `j['code']`·`j['message']` 만 읽는다. 키가 없으면 `'요청을 처리하지 못했어요'` 를 쓴다.
- 영향: 테스트 계정 로그인에서 틀린 토큰을 넣으면 "테스트 로그인 실패: 요청을 처리하지 못했어요"가 뜬다. "토큰이 틀렸다"는 안내가 나오지 않는다.

### [낮음] 삭제된 사용자: refresh 토큰이 계속 새 토큰을 발급하고, access 토큰은 401 이 아니라 404·200 을 받음

- 재현:
  ```sh
  T=$($QA/qa-user a01-del 삭제될사람)
  U=$($QA/qa-sql "SELECT user_id FROM users WHERE kakao_id='qa-a01-del'" | tail -1)
  R=a01delrefreshtoken0123456789abcdefXYZ; H=$(printf %s "$R" | shasum -a 256 | cut -d' ' -f1)
  $QA/qa-sql "INSERT INTO refresh_token (user_id, token_hash, expires_at) VALUES ($U, '$H', UTC_TIMESTAMP(6) + INTERVAL 1 DAY)"
  $QA/qa-sql "DELETE FROM users WHERE user_id=$U"
  curl -s -w " %{http_code}\n" $B/api/v1/me/state -H "Authorization: Bearer $T"
  curl -s -w " %{http_code}\n" $B/api/v1/me/today -H "Authorization: Bearer $T"
  curl -s -w " %{http_code}\n" -X POST $B/api/auth/refresh -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$R\"}"
  ```
- 기대: 없는 사용자의 토큰은 401. refresh 도 401 이고 그 사용자의 refresh 토큰은 무효.
- 실제: `/me`, `/me/state`, `POST /stores` 는 `404 {"code":"NOT_FOUND","message":"사용자를 찾을 수 없어요"}` 이다. `/me/today` 는 `200 {"todayShift":null,...}`, `/me/notifications` 는 `200 {"items":[]}` 이다. `/auth/refresh` 는 `200` 이고 `sub` 가 지운 user_id 인 새 access/refresh 토큰을 준다. 회전하므로 refresh 토큰 수명(14일)마다 계속 이어진다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/auth/jwt/JwtAuthenticationFilter.java:30-32` 는 서명만 보고 사용자 존재를 확인하지 않는다. `donBug_BE/src/main/java/com/example/moneybug/auth/AuthService.java:95-102` 의 `refresh` 도 사용자 존재를 확인하지 않는다. `refresh_token.user_id` 에는 FK 가 없어 사용자를 지워도 토큰 행이 남는다.
- 영향: 지금은 회원 탈퇴 API 가 없다. 그래서 DB 에서 사용자를 지운 경우에만 생긴다. 이때 FE 는 404 를 세션 만료로 보지 않는다. 그래서 `onUnauthorized` 가 불리지 않는다. 웹은 로그인 화면에 "사용자를 찾을 수 없어요"를 띄우지만 토큰은 지우지 않는다(`web_boot.dart:77-83`). 탈퇴 기능을 만들 때 같이 고쳐야 한다.

### [낮음] 웹 콜백에서 state 쿠키와 state 파라미터가 둘 다 빈 문자열이면 state 검증 통과

- 재현:
  ```sh
  curl -s -D - -o /dev/null "$B/api/auth/kakao/callback?state=&code=x" -H 'Cookie: kakao_state=' | grep -i ^location
  ```
- 기대: `error=invalid_state`.
- 실제: `Location: http://localhost:3004/#/auth?error=login_failed`. state 검증을 통과해 카카오 코드 교환까지 갔다. 쿠키가 없거나 값이 다르면 `invalid_state` 가 정상으로 나온다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/auth/AuthController.java:94`. `expectedState == null` 만 막는다. 빈 문자열 쿠키는 `"".equals("")` 로 통과한다.
- 영향: 공격자가 피해자 브라우저에 빈 `kakao_state` 쿠키를 심을 수 있을 때만 로그인 CSRF 방어가 뚫린다. 예를 들어 `ruraeru.xyz` 의 다른 서브도메인에서 `Domain=ruraeru.xyz` 쿠키를 심는 경우다. 현실 위험은 낮다. `isBlank` 검사 한 줄로 막을 수 있다.

### [낮음] 로그인 실패 코드가 사용자 화면에 그대로 보임

- 재현: `curl -s -D - -o /dev/null "$B/api/auth/kakao/callback?code=x&state=y" | grep -i ^location` → `#/auth?error=invalid_state`. 앱은 `donbug://auth?error=login_failed` 를 받는다.
- 기대: "로그인 시간이 지났어요. 다시 시도해 주세요" 같은 한국어 안내.
- 실제: 웹은 `WebLoginScreen` 에 `invalid_state` / `kakao_denied` / `missing_code` / `login_failed` 를 그대로 보여 준다. 앱은 "로그인하지 못했어요: Exception: login_failed" 토스트를 띄운다.
- 원인: `donBug_FE/lib/screens/web/web_boot.dart:52` (`_error = q['error']`), `donBug_FE/lib/screens/mobile_boot.dart:66-67` (`throw Exception(q['error'])`). FE 에 코드별 문구 변환이 없다(`grep invalid_state lib` 결과 0건).
- 영향: 카카오 동의 화면에서 "취소"하거나 5분 넘게 머문 사용자가 영어 코드만 보게 된다.

### [낮음] 쓰이지 않은 refresh 토큰 행이 영원히 남음

- 재현: `test_token` 으로 여러 번 로그인한 뒤 `$QA/qa-sql "SELECT COUNT(*) FROM refresh_token WHERE user_id=2"` 를 실행하면 로그인 횟수만큼 늘어난다. 만료된 행을 지우는 작업은 없다. `@Scheduled` 는 `AttendanceAutoClockOut` 하나뿐이다.
- 기대: 만료된 refresh 토큰은 주기적으로 지워진다.
- 실제: 행은 `refresh` 로 소비되거나 `logout` 할 때만 지워진다. 앱을 지우거나 로그아웃 없이 브라우저 저장소를 지우면 그 행이 남는다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/auth/AuthService.java:94-108` (만료 행은 그 토큰이 다시 제시될 때만 지운다). 정리 스케줄러가 없다.
- 영향: 기능 문제는 없다. `refresh_token` 테이블이 계속 커진다.

## 통과한 케이스

토큰 로그인 `POST /api/auth/kakao/token`
- `test_token`(개발 사용자) → 200, `{accessToken, refreshToken, tokenType:"Bearer", expiresIn:1800}`
- 테스트 토큰 `qa-local-test-login-token-123456` → 200, 테스트알바
- 테스트 토큰보다 1글자 짧은 값, 앞에 공백이 붙은 `" test_token"` → 401 (정확히 같은 값일 때만 우회)
- 틀린 ASCII 토큰, 숫자 `123`, 20KB 문자열 → 401 `Invalid Kakao access token`
- `""`, `{}`, `null` → 400 `VALIDATION_FAILED`
- 본문 없음, 깨진 JSON, 배열, 객체 값 → 400
- `text/plain` → 415, `GET` → 405
- 같은 계정 재로그인 → 같은 user_id, 이름·이메일 덮어쓰지 않음

refresh `POST /api/auth/refresh`
- 정상 회전 → 200, 새 refresh 발급, 이전 refresh 는 바로 401 (재사용 거부)
- 회전 뒤 이전 access 토큰은 만료 전까지 유효 (stateless JWT, 30분)
- 만료된 refresh (`expires_at` = UTC 기준 1초 전) → 401 `Refresh token expired`, 행 삭제, 다시 보내면 `Invalid refresh token`
- 만료 5초 전 refresh → 200
- 임의 문자열, access 토큰을 refresh 로, 100KB 문자열, 한글·이모지·NUL, 숫자 → 401
- 빈 문자열 → 400 `VALIDATION_FAILED`, 본문 없음 → 400
- 동시 10개에서 200 은 1개뿐 (토큰 중복 발급 없음, 진 요청의 새 토큰은 롤백됨)

logout `POST /api/auth/logout`
- 정상 → 204, 그 뒤 refresh → 401
- 두 번 로그아웃, 없는 토큰 → 204 (멱등)
- 빈 문자열 → 400, 본문 없음 → 400
- 동시 5개 → 모두 204
- 로그아웃 뒤 access 토큰은 만료까지 유효 (설계상, stateless)

JWT (`GET /api/v1/me`)
- 정상 → 200
- `bearer`(소문자), `Bearer` 뒤 공백 없음, 공백 두 칸, 헤더 없음, `Basic` 헤더, `Bearer ` 만, 쓰레기 문자열 → 401
- 다른 비밀키 서명, 만료(1000초 전·1초 전), `nbf` 미래 → 401
- `sub` 숫자 아님, `sub` 없음, `sub` long 범위 초과 → 401
- `alg:none`(서명 없음), 헤더만 `HS512` 로 바꾼 토큰, payload 바꿔치기, 서명 제거, 서명 마지막 글자 변경 → 401
- 없는 `sub`(99999999, -1) → 404 `NOT_FOUND` (위 "삭제된 사용자" 항목 참고)
- 401 응답 본문은 비어 있음. FE `_error` 는 JSON 파싱에 실패하면 "다시 로그인해 주세요"로 처리하므로 문제없음

웹 카카오 login / callback
- `GET /kakao/login` → 302 카카오 authorize URL. `state` 는 16바이트 랜덤. `kakao_state` 쿠키는 HttpOnly·SameSite=Lax·Path=/api/auth/kakao·5분, `kakao_app` 은 비움
- `?app=true` → `kakao_app=1` 쿠키. `POST /kakao/login` → 405
- 콜백에서 쿠키 없음, 파라미터 없음, state 불일치 → `#/auth?error=invalid_state`
- `error=access_denied` → `error=kakao_denied`. state 확인 전에 처리되지만 토큰을 발급하지 않으므로 문제없음
- state 맞고 code 없음·공백 → `error=missing_code`, 틀린 code → `error=login_failed`
- `kakao_app=1` 쿠키 → `donbug://auth?error=...` 로 같은 분기
- 콜백은 매번 두 쿠키를 지움 (state 재사용 불가)
- 리다이렉트 대상은 설정값 `frontendUrl` / `donbug://auth` 고정. 요청 값으로 바꿀 수 있는 파라미터가 없어 open redirect 없음

보안 설정 · CORS
- preflight: 허용 origin(`http://localhost:3004`, `http://127.0.0.1:5000`) → 200 + `Access-Control-Allow-Origin`
- 허용되지 않은 origin(`https://evil.com`, `http://localhost.evil.com`, `null`) → 403, 허용 헤더 없음
- 허용되지 않은 요청 헤더(`x-custom`), 메서드(`TRACE`) → 403
- `Access-Control-Allow-Credentials` 없음 (쿠키 미허용)
- 인증 없이 `/`, `/error`, `/actuator`, `/actuator/health`, `/swagger-ui.html`, `/swagger-ui/index.html`, `/v3/api-docs`, `/uploads/x`, `/favicon.ico`, `/api/v1/me/`, `/API/v1/me` → 401 (Swagger 꺼짐 확인)
- `/api/auth`, `/api/auth/foo`, `/api/auth/kakao` → 404 (permitAll 범위에 다른 핸들러 없음)
- 경로 우회 `/api/auth/..%2Fv1/me`, `/api/auth/kakao/token/../../v1/me`, `/api/v1/../auth/refresh`, `/api/v1/me;x=1` → 400 (StrictHttpFirewall)
- 인증이 필요한 API 를 `/api/auth/**` 밑으로 돌려 부를 수 있는 경로 없음

## 참고 (버그는 아니지만 알아 둘 것)

- refresh 재사용 탐지 없음: 이미 쓴 refresh 토큰을 다시 보내면 401 이 난다. 그 토큰에서 회전해 나온 새 토큰은 계속 유효하다(토큰 family 폐기 없음). 탈취된 refresh 토큰을 공격자가 먼저 쓰면 정상 사용자만 로그아웃된다.
- `exp` 가 없거나(`{"sub":"2"}`) 아주 먼 미래인 JWT 도 받는다(`JwtProvider.java:44`). 비밀키가 있어야 만들 수 있다. 그래서 비밀키가 새지 않으면 문제가 없다.
- `Authorization: Bearer <토큰> ` 처럼 끝에 공백이 붙어도 200 이다(jjwt 가 trim).
- 같은 초에 같은 사용자로 두 번 발급하면 access 토큰 문자열이 완전히 같다(iat/exp 초 단위, jti 없음). 기능 문제는 없다.
- `refresh_token.expires_at` 은 UTC 로 저장된다. DB 세션 시간대는 KST(`SYSTEM`)다. 그래서 `NOW()` 와 비교하면 9시간 어긋난다. 앱은 일관되게 동작한다. 다만 수동 조회나 SQL 작업에서 `UTC_TIMESTAMP()` 를 써야 한다. 처음에 `NOW()` 로 만료를 만들었을 때 만료되지 않았다.

## 못 한 것

- 실제 카카오 로그인 성공 경로(`loginWithKakaoCode`, 실제 카카오 access token): 로컬 카카오 REST 키가 비어 있고(`client_id=`), 실제 카카오 계정·인가 코드가 없다. 콜백 성공 리다이렉트(`?access=..&refresh=..`) 모양은 코드로만 확인했다(`AuthController.java:109-111`).
- `KAKAO_APP_ID` 를 설정했을 때의 `verifyAppId` 거부: 로컬 설정이 비어 있다. 컨테이너 환경을 바꾸면 안 된다.
- `DEV_LOGIN_ENABLED=false`·`TEST_LOGIN_TOKEN` 16자 미만일 때 우회가 꺼지는지: 서버 재시작이 필요하다. 코드로는 `AuthService.java:62-63, 75, 78` 에서 꺼지는 것을 확인했다.
- 운영의 `Secure` 쿠키: `frontendUrl` 이 https 일 때만 켜진다(`AuthController.java:49`). 로컬은 http 라 `Secure` 가 없는 것만 확인했다.
- access 토큰 자연 만료(30분 대기): 만료 시각을 지난 토큰을 직접 서명해 401 을 확인했다.
- 롱 폴링 중 토큰 만료: 21번 영역이다.

## 데이터 변경 기록

- 테스트알바 계정(kakao_id `-2`, 기존 user_id 3, 연결 데이터 0건)을 동시 첫 로그인 재현을 위해 지웠다. 지금은 user_id 366 으로 다시 생겼다.
- `qa-a01-del` 사용자를 만들고 지웠다. 그 사용자의 `refresh_token` 행은 남아 있다(위 발견 항목의 재현 결과).
- `qa-a01-u1` 사용자를 만들었다.
