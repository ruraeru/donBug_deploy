# 17 contract QA 보고서

## 요약

- 실행한 케이스: 82
- 통과: 74
- 발견: 7건. 치명 0, 높음 1, 중간 3, 낮음 3

테스트 데이터: 매장 A `29`(사장님 `a17-owner`, 알바 `a17-staff1`=staff 65, `a17-staff2`=staff 66, `a17-staff3` 미승인), 매장 B `30`(사장님 `a17-ownerB`, `a17-staffB`=staff 67, `a17-staff1` 의 B 소속=staff 164), 무소속 `a17-outsider`.

공통 준비(아래 재현에서 그대로 쓴다):

```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
OWN=$($QA/qa-user a17-owner); S1=$($QA/qa-user a17-staff1); S2=$($QA/qa-user a17-staff2)
# 4x4 PNG 하나를 sig.png 로 준비
OSIG=$(curl -s -X POST $B/me/signatures -H "Authorization: Bearer $OWN" -F "image=@sig.png;type=image/png" | jq -r .signatureUrl)
S1SIG=$(curl -s -X POST $B/me/signatures -H "Authorization: Bearer $S1" -F "image=@sig.png;type=image/png" | jq -r .signatureUrl)
CT='{"start":"2026-11-20","end":"2027-11-19","wage":10320,"weeklyHours":20,"workDays":"월·수·금","duty":"홀 서빙"}'
```

## 발견

### [높음] 계약서를 시작일을 앞당겨 다시 쓰면, 대체된 계약서의 시급이 이후 날짜에 계속 적용된다

- 재현 (재직 중 직원 66, 오늘 2026-11-17):
  ```sh
  # 1) 12/1 부터 11,000원 계약서 발송
  curl -X PUT $B/stores/29/staff/66/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' \
    -d '{"start":"2026-12-01","end":"2027-11-30","wage":11000,"weeklyHours":20,"workDays":"월·수·금","duty":"홀 서빙"}'
  # 2) 잘못 보냈다고 보고 11/20 부터 10,320원으로 다시 작성 (이것이 현재 계약서)
  curl -X PUT $B/stores/29/staff/66/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' -d "$CT"
  $QA/qa-sql "select effective_from, wage from staff_wage where mapping_id=66 order by effective_from, wage_id"
  ```
- 기대: 현재 계약서(11/20~, 10,320원)가 계약 기간 전체의 시급이 된다. 대체된 계약서의 시급 단계는 사라지거나 무시된다.
- 실제: 둘 다 200. `staff_wage` 에 `2026-11-20 10320` 과 `2026-12-01 11000` 이 같이 남는다. `/me/state` 의 `wages` 도 `[..., {"from":"2026-11-20","wage":10320}, {"from":"2026-12-01","wage":11000}]`. 그래서 12/1 부터는 현재 계약서와 다른 11,000원이 적용된다. 직원 65 에서도 같은 현상을 봤다(11/20 계약 10,320 → 11/01 계약 10,500 으로 재작성 → `wages` 가 `11-01 10500, 11-20 10320` 이 되어 11/20 부터 10,320).
- 원인: `DocumentService.java:155` 가 계약서마다 `wages.record(sw, start, wage)` 로 시급 단계를 추가만 한다. `StaffWageService.java:22-28` 은 이전 계약서가 넣은 단계를 지우지 않고, `StaffWageService.java:43-54`·FE `models.dart:488-494`(`wageOn`) 는 날짜가 가장 늦은 단계를 고른다. 같은 시작일로 다시 쓰면 id 가 큰 행이 이겨서 괜찮지만, 시작일을 앞당기면 옛 단계가 뒤에 남는다. 서명 전에 대체된 계약서도 단계를 남긴다.
- 영향: FE 급여 명세(`app_store.dart:612` `wageOn: staff.wageOn`)와 근무표 인건비(`MonthScheduleService.java:536`)가 계약서와 다른 시급으로 계산된다. 사장님이 시급 오타를 고치려고 시작일을 바꿔 다시 보내면 틀린 시급이 고칠 방법 없이 남는다(시급 이력 삭제 API 없음). 참고로 BE `PayrollCalculator.java:61` 은 이력 대신 `hourlyWage` 하나만 써서 FE 계산과도 어긋난다(18번 영역).

### [중간] 서명 요청에 계약서 id 가 없어서, 직원이 본 적 없는 새 계약서에 서명된다

- 재현:
  ```sh
  curl -X PUT $B/stores/29/staff/65/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' \
    -d "{\"start\":\"2026-11-01\",\"end\":\"2027-11-19\",\"wage\":10500,\"weeklyHours\":20,\"workDays\":\"월·수·금\",\"duty\":\"홀 서빙\",\"ownerSignatureUrl\":\"$OSIG\"}"
  curl $B/me/state -H "Authorization: Bearer $S1"   # 직원이 화면에서 보는 계약서: id 6, 10,500원, 주 20시간, 홀 서빙
  # 직원이 서명 화면을 보는 동안 사장님이 다시 작성
  curl -X PUT $B/stores/29/staff/65/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' \
    -d "{\"start\":\"2026-11-20\",\"end\":\"2027-11-19\",\"wage\":10320,\"weeklyHours\":40,\"workDays\":\"월~토\",\"duty\":\"주방 전체\",\"ownerSignatureUrl\":\"$OSIG\"}"
  curl -X POST $B/stores/29/staff/65/contract/sign -H "Authorization: Bearer $S1" -H 'Content-Type: application/json' -d "{\"signatureUrl\":\"$S1SIG\"}"
  ```
- 기대: 직원이 본 계약서(id 6)가 아니면 409 같은 오류로 다시 확인하게 한다.
- 실제: 200, `{"id":"17","wage":10320,"weeklyHours":40,"workDays":"월~토","duty":"주방 전체",...,"signed":true}`. 직원은 10,500원·주 20시간을 보고 서명했는데 10,320원·주 40시간 계약서에 서명한 것으로 기록된다.
- 원인: `ContractDto.java:83-88` `SignRequest` 에 `signatureUrl` 만 있고, `DocumentService.java:177` 이 서명 시점의 최신 계약서를 골라 서명한다. FE `app_store.dart:1889` 도 계약서 id 를 보내지 않는다.
- 영향: 전자 서명 계약서의 내용이 서명자가 확인한 내용과 다를 수 있다. 법적 증빙으로 쓰기 어렵다.

### [중간] 같은 서명 요청을 동시에 보내면 여러 번 성공하고 알림이 중복된다

- 재현:
  ```sh
  curl -X PUT $B/stores/29/staff/65/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' -d "$CT"
  for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code} " -X POST $B/stores/29/staff/65/contract/sign \
    -H "Authorization: Bearer $S1" -H 'Content-Type: application/json' -d "{\"signatureUrl\":\"$S1SIG\"}" & done; wait
  $QA/qa-sql "select notification_id,title,ref_id,to_user_id from notification where store_id=29 and type='CONTRACT' and ref_id=18"
  ```
- 기대: 1개만 200, 나머지 409 `ALREADY_SIGNED`. 사장님 알림 1건.
- 실제: `200 200 409 409 200 409 409 409 409 409`. 사장님에게 "알바하나님이 근로계약서에 서명했어요" 알림 3건(727·728·729). `employee_signed_at` 은 마지막으로 커밋된 요청 값으로 덮인다.
- 원인: `DocumentService.java:179-186` 이 읽고-확인하고-쓰는데 잠금(`@Version`, `SELECT ... FOR UPDATE`, 조건부 UPDATE)이 없다. `Contract.java` 에 버전 필드가 없다.
- 영향: 서명 버튼 두 번 탭·네트워크 재시도에서 중복 알림, 서명 시각·서명 이미지·IP 증빙이 나중 요청 값으로 바뀐다.

### [중간] 존재하지 않는 서명 이미지 경로로도 서명·작성이 완료된다

- 재현:
  ```sh
  curl -X PUT $B/stores/29/staff/66/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' \
    -d '{"start":"2026-11-20","end":"2027-11-19","wage":10320,"weeklyHours":20,"workDays":"월·수·금","duty":"홀 서빙","ownerSignatureUrl":"signatures/<사장님 user_id>/fake.png"}'
  # 위는 사장님 서명 이미지 없이 200. 직원도 업로드 없이 서명 가능:
  curl -X POST $B/stores/29/staff/66/contract/sign -H "Authorization: Bearer $S2" -H 'Content-Type: application/json' \
    -d '{"signatureUrl":"signatures/<직원 user_id>/does-not-exist.png"}'
  curl -o /dev/null -w '%{http_code}\n' $B/stores/29/staff/66/contract/signature/employee -H "Authorization: Bearer $S2"
  ```
- 기대: 실제로 올린 서명 파일이 아니면 400 `INVALID_SIGNATURE`.
- 실제: 작성 200, 서명 200 `"signed":true`. DB `employee_signature_url = signatures/166/does-not-exist.png`. 서명 이미지 조회는 404 `파일을 찾을 수 없어요`.
- 원인: `DocumentService.java:88-93` `requireOwnSignature` 가 문자열 접두사(`signatures/{userId}/`)와 `..` 만 보고 파일이 있는지 확인하지 않는다.
- 영향: 서명 이미지 없이 "양쪽 서명 완료" 계약서가 생긴다. 대시보드·서류 화면은 완료로 표시하지만 서명 증빙(이미지)이 없다. `ownerSignatureUrl` 은 아예 생략해도 된다(선택값, `DocumentService.java:148-152`). FE 는 항상 보내므로 API 직접 호출에서만 생긴다.

### [낮음] 잘못된 `who` 값이 400 대신 직원 서명 이미지를 돌려준다

- 재현:
  ```sh
  curl -o /dev/null -w '%{http_code} %{content_type}\n' $B/stores/29/staff/65/contract/signature/foo -H "Authorization: Bearer $OWN"
  curl -o /dev/null -w '%{http_code} %{content_type}\n' $B/stores/29/staff/65/contract/signature/OWNER -H "Authorization: Bearer $OWN"
  ```
- 기대: 400 (who = `owner` | `employee` 만).
- 실제: 둘 다 `200 image/png` 이고 직원 서명 이미지다(`OWNER` 도 사장님이 아니라 직원 서명).
- 원인: `DocumentService.java:124` `"owner".equals(who) ? owner : employee`.
- 영향: 권한은 지켜지므로 노출은 없다. 호출 실수가 다른 이미지로 조용히 성공한다.

### [낮음] 계약서·서명 API 일부 오류가 FE 가 읽는 모양이 아니거나 메시지가 안내가 안 된다

- 재현:
  ```sh
  curl -X PUT $B/stores/29/staff/65/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' \
    -d '{"start":"2026-11-20","end":"2027-11-19","wage":10319,"weeklyHours":20,"workDays":"월"}'
  curl -X PUT $B/stores/29/staff/65/contract -H "Authorization: Bearer $OWN" -H 'Content-Type: application/json' \
    -d '{"start":"2026-02-30","end":"2027-11-19","wage":10320,"weeklyHours":20,"workDays":"월"}'
  curl -X POST $B/me/signatures -H "Authorization: Bearer $S1" -F "x=@sig.png"
  ```
- 기대: `{code, message}` 모양, 한국어 안내(예: `WAGE_BELOW_MINIMUM` "시급은 2026 최저임금 10,320원 이상이어야 해요").
- 실제: 최저임금 미만은 400 `VALIDATION_FAILED` "요청 값이 올바르지 않아요", details 는 영어 `must be greater than or equal to 10320`. 서비스의 한국어 `WAGE_BELOW_MINIMUM`(`DocumentService.java:140-143`)과 `INVALID_CONTRACT_PERIOD`(`:144-146`)는 DTO 검증(`ContractDto.java:38`, `:58-61`)에 먼저 걸려 도달하지 않는다. 날짜 `2026-02-30`·`wage:"abc"`·`wage` int 범위 초과·`image` 필드 누락·비숫자 staffId 는 Spring 기본 본문 `{"timestamp","status","error","path"}` 로, `message` 가 없어 FE `api_client.dart:174-175` 가 "요청을 처리하지 못했어요" 만 보인다.
- 원인: 위 줄. 컨트롤러 예외 처리기가 `HttpMessageNotReadableException`·`MissingServletRequestPartException`·`MethodArgumentTypeMismatchException` 을 공통 모양으로 바꾸지 않는다(23번 영역과 겹침).
- 영향: FE 가 클라이언트에서 먼저 막으므로 일반 사용자는 거의 보지 않는다. 버전이 다른 앱·직접 호출에서 원인을 알 수 없는 메시지가 나온다.

### [낮음] 계약서 숫자·길이 범위 검증이 어색하다

- 재현:
  ```sh
  curl -X PUT $B/stores/29/staff/66/contract ... -d '{..."weeklyHours":1000...}'      # 200
  curl -X PUT $B/stores/29/staff/66/contract ... -d '{..."wage":2147483647...}'      # 200
  curl -X PUT $B/stores/29/staff/66/contract ... -d '{..."duty":"😀 x100"...}'        # 400 duty size
  ```
- 기대: 주 소정근로시간은 168 이하(법정 한도로는 52), 시급은 상식적인 상한. 업무 내용 100자는 글자 수 기준.
- 실제: 주 1000시간·시급 2,147,483,647원 계약서가 저장되고 시급 이력(`staff_wage`)에 영구히 남는다. 이모지 100개(100글자)는 Java UTF-16 길이 200 으로 계산돼 400. DB 컬럼은 `varchar(100)` 글자 기준이라 저장할 수 있다.
- 원인: `ContractDto.java:37-43` 에 `@Max` 없음. `ContractDto.java:50` `@Size(max=100)` 가 UTF-16 code unit 을 센다.
- 영향: 오타 하나로 시급 이력이 오염되고(위 높음 항목 때문에 지우기도 어렵다), FE 주휴 판단(`app_store.dart:600` `contract.weeklyHours*60`)이 실제와 무관하게 항상 충족된다.

## 통과한 케이스

서명 업로드 `POST /me/signatures`
- 사장님·알바·무소속 사용자 PNG 업로드 200, `signatures/{userId}/{uuid}.png`
- `application/octet-stream` + `.png` 파일명 200 (앱 multipart 대응)
- 이미지가 아닌 내용(확장자 png) 400 `INVALID_FILE_TYPE`
- 빈 파일 400 `IMAGE_REQUIRED`
- 인증 없음 401
- JSON 본문 415
- 파일명 `../../etc/x.png` 무시, 서버 uuid 경로로 저장

작성 `PUT .../contract`
- 미승인(PENDING) 직원 409 `NOT_ACTIVE`
- 퇴사 직원 409 `NOT_ACTIVE`
- 알바생 본인·매니저(kind=manager)·다른 매장 사장님·무소속 403
- 다른 매장 사장님이 자기 storeId 경로에 남의 staffId 404
- 없는 staffId 404, 숫자가 아닌 staffId 400
- 최저임금 미만 400, 종료일=시작일·종료일<시작일 400, start 누락 400, weeklyHours 0 400, workDays 공백 400, workDays 51자 400, duty 101자 400, ownerSignatureUrl 501자 400
- 남이 올린 서명(`signatures/165/...`)·`..` 포함 경로 400 `INVALID_SIGNATURE`
- 정상 작성 200, `ownerSignedAt` 서버 시각(KST), `employeeSignedAt` null, `signed:false`
- 서명 완료 뒤 재작성 → 새 계약서가 현재 계약서가 되고 `signed:false`, 직원에게 "근로계약서 서명 요청" 알림
- duty null → `""`, HTML 문자열 그대로 저장(FE 는 Text 로 그려 실행 안 됨)
- 먼 과거·먼 미래 기간 저장

서명 `POST .../contract/sign`
- 계약서 없을 때 404, 두 번째 서명 409 `ALREADY_SIGNED`
- 다른 직원·사장님이 서명 403, 남의 서명 이미지 400, `app-signature` 문자열 400, 빈 문자열 400
- 다른 매장 경로로 서명 404
- 퇴사 뒤 서명 409
- 정상 서명 200: `employee_signature_url`·`employee_signed_ip`·`terms_version=v1` 기록, 사장님에게 "{이름}님이 근로계약서에 서명했어요" 알림
- 두 매장 소속 직원이 매장 B 계약서에 같은 서명 이미지로 서명 200 (본인 이미지라 허용)

서명 이미지 `GET .../contract/signature/{who}`
- 사장님·계약 당사자 직원 owner/employee 200 `image/png`
- 같은 매장 다른 알바·매니저(미승인 직원 계약)·다른 매장 사장님·무소속 403, 인증 없음 401
- 계약서 없음 404, 서명 이미지 없는 계약서 404, 없는 매장 404, who 비움 404
- 직원 A 의 매장 B 계약 서명을 매장 A 사장님이 열람 403, 반대도 403

상태 반영
- `/me/state` 의 `staff[].contract` 키가 FE `Contract.fromJson`(start·end·wage·weeklyHours·workDays·duty·ownerSignedAt·employeeSignedAt)과 맞고 id 는 문자열, 날짜는 `yyyy-MM-dd`, 시각은 ISO
- 알바생 `/me/state`·직원 목록에서 동료 계약서는 null, 시급 0 으로 가려짐. 동료 상세 GET 403

## 못 한 것

- FE 화면 동작(서명 패드 → PNG, 서명 화면의 확인 체크)은 웹 컨테이너가 없어 API 로만 확인했다.
- 계약서 서명 이미지를 FE 가 보여 주는 곳이 없다(`contract/signature` 를 부르는 FE 코드 없음). 화면 대조는 못 했고, 버그가 아니라 기능 공백으로 본다.
- 계약 기간이 끝난 계약서의 처리(만료 알림·상태)는 BE·FE 어디에도 로직이 없어 테스트할 대상이 없었다.
- 서명 이미지 업로드 크기 한도(10MB 초과)는 16번(health-cert)이 같은 multipart 설정을 보므로 반복하지 않았다.
- 급여 금액에 대한 시급 이력 영향은 `/me/state` `wages` 와 `wageOn` 코드로 확인했다. 출근 기록을 만들어 명세 금액까지 비교하는 것은 18번(payroll) 영역에 맡겼다.
