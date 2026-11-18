# 16 health-cert QA 보고서

## 요약

- 실행한 케이스: 82
- 통과: 71
- 발견: 9건. 치명 1, 높음 0, 중간 3, 낮음 5.

테스트 데이터(모두 a16- 접두사):

| label | user_id | 소속 |
|---|---|---|
| a16-ownerA | 136 | 매장 A(store 27, 코드 QYNF-CN5B) 사장님 |
| a16-ownerB | 140 | 매장 B(store 28, 코드 X39T-NS92) 사장님 |
| a16-staff1 | 143 | A 알바(staff 57) |
| a16-staff2 | 148 | A 알바(staff 58), B 알바(staff 61, 테스트 중 퇴사) |
| a16-mgr | 153 | A 매니저(staff 59) |
| a16-pending | 150 | A 가입 신청(staff 60, 테스트 중 거절) |
| a16-none | 155 | 무소속 |

아래 재현에서 `$B=http://127.0.0.1:18080/api/v1`, `$QA` 는 QA 디렉터리다. `<label>` 토큰은 `$($QA/qa-user <label>)` 로 받는다. 이미지 파일은 정상 PNG 1x1(`a.png`)과 JPEG 헤더 파일(`a.jpg`)을 썼다.

## 발견

### [치명] 퇴사·거절된 사람의 새 보건증 사진·만료일을 예전 매장 사장님이 계속 볼 수 있다

- 재현:
  ```sh
  OB=$($QA/qa-user a16-ownerB); OA=$($QA/qa-user a16-ownerA); S2=$($QA/qa-user a16-staff2); P1=$($QA/qa-user a16-pending)
  # B 사장님이 staff2 를 퇴사 처리하고, A 사장님이 신청자를 거절한다
  curl -s -XDELETE $B/stores/28/staff/61 -H "Authorization: Bearer $OB"            # 204, status=LEFT
  curl -s -XPOST   $B/stores/27/staff/60/reject -H "Authorization: Bearer $OA"     # 204, status=REJECTED
  # 그 뒤 두 사람이 새 보건증을 올린다
  curl -s -XPUT $B/me/health-cert -H "Authorization: Bearer $S2" -F expiry=2027-12-31 -F alertDays=30 -F "photo=@b.png;type=image/png"
  curl -s -XPUT $B/me/health-cert -H "Authorization: Bearer $P1" -F expiry=2027-12-31 -F alertDays=30 -F "photo=@b.png;type=image/png"
  # 예전 사장님이 새 사진을 받는다
  curl -s -o x.png -w "%{http_code}\n" $B/stores/28/staff/61/health-cert/photo -H "Authorization: Bearer $OB"
  curl -s -o y.png -w "%{http_code}\n" $B/stores/27/staff/60/health-cert/photo -H "Authorization: Bearer $OA"
  curl -s $B/me/state -H "Authorization: Bearer $OB"   # persons 에 148 의 새 certExpiry
  ```
- 기대: 퇴사(LEFT)·거절(REJECTED)된 사람의 보건증은 그 매장 사장님이 볼 수 없다. 최소한 관계가 끝난 뒤 올린 새 사진은 보이지 않아야 한다. `api_design.md:770` 도 "접근 권한(본인·소속 사장님만)" 이라고 적었다.
- 실제: 둘 다 `200 image/png` 이고, 퇴사·거절 뒤 올린 새 파일(끝이 `SECOND`)이 그대로 내려온다. B 사장님의 `/me/state` `persons` 에도 `{"id":"148","certExpiry":"2027-12-31","certHasPhoto":true}` 가 들어 있다. 대기 중(PENDING)인 신청자의 사진도 승인 전에 `200` 으로 받을 수 있다.
- 원인: `service/DocumentService.java:104-106` `staffCertPhotoPath` 는 `requireOwner` 와 `access.staff(storeId, staffId)` 만 본다. 직원의 상태(ACTIVE 여부)는 보지 않는다. 보건증은 사람(User) 단위라서 store_worker 행이 남아 있으면 지금 사진이 나온다. `/me/state` 도 `service/StateService.java:132-140` 이 사장님에게 모든 상태의 직원을 돌며 `AppStateDto.Person.from(worker)` 로 지금 보건증 정보를 넣는다.
- 영향: 보건증은 건강 관련 개인정보다. 한 번이라도 매장에 신청했거나 일했던 사람은 그 매장을 떠난 뒤에도 새 보건증 사진과 만료일을 예전 사장님에게 계속 보여 준다. 거절당한 신청자도 같다. 사용자는 이를 알 수도, 막을 수도 없다.

### [중간] alertDays 에 빈 항목이 있으면 500

- 재현:
  ```sh
  S2=$($QA/qa-user a16-staff2)
  curl -s -w " <%{http_code}>\n" -XPUT $B/me/health-cert -H "Authorization: Bearer $S2" \
    -F expiry=2027-06-30 -F "alertDays=30,,7" -F "photo=@a.png;type=image/png"
  ```
- 기대: 400 `INVALID_ALERT_DAYS`. 바로 아래 줄에 `d == null` 검사가 있다.
- 실제: `500 {"timestamp":...,"status":500,"error":"Internal Server Error"}`. BE 로그에 `NullPointerException: Cannot read field "value" because "<parameter1>" is null at DocumentService.uploadHealthCert(DocumentService.java:56)` 가 남는다.
- 원인: `service/DocumentService.java:55-57`. `"30,,7"` 은 `[30, null, 7]` 로 바인딩된다. `.sorted(Comparator.reverseOrder())` 가 null 을 비교하다 NPE 를 던진다. null 검사(57줄)는 정렬 뒤에 있어서 닿지 않는다.
- 영향: FE 는 이런 값을 보내지 않는다. 다른 클라이언트나 잘못된 요청이 오면 400 대신 500 이 나고, 오류 응답도 `{code,message}` 모양이 아니다.

### [중간] alertDays 를 저장한 문자열이 50자를 넘으면 500, 업로드한 파일은 남는다

- 재현:
  ```sh
  S2=$($QA/qa-user a16-staff2)
  curl -s -w " <%{http_code}>\n" -XPUT $B/me/health-cert -H "Authorization: Bearer $S2" \
    -F expiry=2027-06-30 -F "alertDays=99999,99998,99997,99996,99995,99994,99993,99992,99991" -F "photo=@a.png;type=image/png"
  $QA/dc exec -T be ls -lt /data/uploads/health-cert/148 | head -3   # 방금 시각의 파일이 생겼지만 DB 는 가리키지 않음
  ```
- 기대: 400 검증 오류. 알림 시점 개수나 값의 범위를 제한해야 한다.
- 실제: `500`. 로그에 `Data truncation: Data too long for column 'cert_alert_days'` 가 남는다. 트랜잭션은 롤백되어 DB 는 바뀌지 않는다. 그런데 `99083ed7-....png` 파일은 디스크에 남고, 어떤 행도 그 파일을 가리키지 않는다. 값이 1~20 이면 정확히 50자라 통과한다.
- 원인: `entity/User.java:63` 컬럼이 `length = 50` 이다. `service/DocumentService.java:55-61` 은 개수·최댓값을 검증하지 않는다. 파일 저장(61줄)이 DB 반영보다 먼저라서 커밋이 실패해도 파일은 지워지지 않는다.
- 영향: 클라이언트가 보낼 수 있는 값으로 500 이 난다. 실패할 때마다 고아 파일이 쌓인다. FE 화면은 4개 중에서만 고르므로 앱 사용자에게는 안 생긴다.

### [중간] 보건증 만료 알림(certAlertDays)이 실제로 발송되지 않는데, FE 는 "자동 발송·발송 완료" 라고 보여 준다

- 재현:
  ```sh
  # 만료 7일 전이 이미 지난 상태를 만든다 (자기 데이터)
  $QA/qa-sql "UPDATE users SET cert_expiry='2026-11-16' WHERE user_id=143"
  $QA/qa-sql "SELECT * FROM notification WHERE to_user_id IN (143,136) AND type='CERT' AND title LIKE '%만료%'"   # 0행
  grep -rn "@Scheduled" donBug_BE/src/main/java   # AttendanceAutoClockOut 하나뿐
  ```
- 기대: 알바생이 등록한 `alertDays`(D-30·14·7·0)에 맞춰 본인 또는 사장님에게 `cert` 알림이 간다. FE `employer_health_cert_alert_screen.dart:24-38` 은 지난 시점은 "발송 완료", 남은 시점은 "자동 발송" 으로 표시한다. 등록 화면(`health_cert_register_screen.dart:165`)도 "만료 알림 받기" 를 고르게 한다.
- 실제: BE 에 certAlertDays 로 알림을 보내는 코드가 없다. `certAlertDays` 는 저장·표시와 대시보드 `certAlerts` 의 임계값(`DashboardService.java:89-95`)으로만 쓰인다. 만료가 지나도 알림은 0건이다.
- 원인: 스케줄러가 없다. `api_design.md:406` 에 "발송 로직이 없으므로 서버 스케줄러가 필요" 라고 적혀 있다. 배포 레포 CLAUDE.md 의 "아직 안 된 것" 에는 이 항목이 없다(거기 있는 것은 FCM/APNs 푸시뿐이다. 이 기능은 앱 안 알림조차 없다).
- 영향: 알바생이 고른 "만료 알림" 설정이 아무 효과가 없다. 사장님 화면은 알림이 "발송 완료" 됐다고 잘못 보여 준다. 보건증이 만료돼도 아무도 알림을 받지 못한다.

### [낮음] 사진을 바꾸거나 업로드가 실패해도 예전 파일을 지우지 않는다

- 재현:
  ```sh
  S1=$($QA/qa-user a16-staff1)
  for i in 1 2 3; do curl -s -o /dev/null -XPUT $B/me/health-cert -H "Authorization: Bearer $S1" -F expiry=2027-06-30 -F alertDays=30 -F "photo=@a.png;type=image/png"; done
  $QA/dc exec -T be sh -c 'ls /data/uploads/health-cert/143 | wc -l'   # 테스트 끝에 20개, DB 는 1개만 가리킴
  ```
- 기대: 교체하면 예전 보건증 사진을 지운다. 실패한 요청의 파일도 지운다.
- 실제: 사용자 143 폴더에 파일 20개가 있고, DB `cert_photo_url` 은 그중 하나만 가리킨다. 위 50자 초과 500 에서 생긴 파일도 남는다.
- 원인: `service/DocumentService.java:61-64` 는 새 경로로 덮어쓰기만 한다. `FileStorage` 에는 삭제 메서드가 없다.
- 영향: 만료된 예전 보건증(개인정보)이 서버에 기한 없이 남고, 디스크가 계속 는다. API 로는 예전 파일을 열 수 없어 바로 노출되지는 않는다.

### [낮음] 'ftyp' 4바이트만 맞으면 HEIC 로 저장한다 (동영상·임의 데이터 통과)

- 재현:
  ```sh
  printf '\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom' > v.mp4
  printf 'AAAAftypBBBB<html><script>alert(1)</script>' > h.png
  curl -s -w " <%{http_code}>\n" -XPUT $B/me/health-cert -H "Authorization: Bearer $S1" -F expiry=2027-06-30 -F alertDays=30 -F "photo=@v.mp4;type=image/png"   # 200
  curl -s -w " <%{http_code}>\n" -XPUT $B/me/health-cert -H "Authorization: Bearer $S1" -F expiry=2027-06-30 -F alertDays=30 -F "photo=@h.png;type=image/png"   # 200
  curl -s -D - -o /dev/null $B/me/health-cert/photo -H "Authorization: Bearer $S1"   # Content-Type: image/heic
  ```
- 기대: 실제 HEIC/HEIF 브랜드(`heic`, `heix`, `mif1` 등)만 받는다.
- 실제: MP4 헤더와 HTML 본문이 모두 `.heic` 로 저장되고 `image/heic` 로 내려간다. 응답에 `X-Content-Type-Options: nosniff` 가 있어서 브라우저가 HTML 로 실행하지는 않는다.
- 원인: `service/FileStorage.java:78` 이 4~7바이트 `ftyp` 만 보고 브랜드는 보지 않는다.
- 영향: 사진 대신 동영상을 고르면 업로드는 성공하지만, 사장님 화면에서 사진이 깨진다. 보안 영향은 nosniff 덕분에 작다.

### [낮음] 앱이 보내는 octet-stream 에서는 확장자 화이트리스트가 매직 바이트 판별보다 먼저 막는다 (.jfif·.heif 거부)

- 재현:
  ```sh
  for n in photo.jfif IMG_1.HEIF; do
    curl -s -w " <%{http_code}>\n" -XPUT $B/me/health-cert -H "Authorization: Bearer $S1" -F expiry=2027-06-30 -F alertDays=30 \
      -F "photo=@a.jpg;type=application/octet-stream;filename=$n"; done   # 둘 다 400 INVALID_FILE_TYPE
  ```
- 기대: 내용이 JPEG 이면 받는다. 바로 다음 단계에서 매직 바이트로 형식을 다시 정한다.
- 실제: 400 `이미지 파일만 올릴 수 있어요`.
- 원인: `service/FileStorage.java:43-44`. FE `api_client.dart:99` 의 `MultipartFile.fromBytes` 는 Content-Type 을 지정하지 않아 항상 `application/octet-stream` 이다. 그래서 확장자가 `jpg|jpeg|png|gif|webp|heic` 가 아니면 내용 검사 전에 막힌다. FE `health_cert_register_screen.dart:76` 은 이미 확장자가 있는 이름(.jfif 등)을 그대로 보낸다.
- 영향: 웹에서 Windows `.jfif` 사진이나 `.heif` 사진을 고르면 실제 이미지인데도 등록하지 못한다.

### [낮음] 같은 매장 알바생에게 동료의 보건증 만료일·사진 여부가 보인다

- 재현:
  ```sh
  S1=$($QA/qa-user a16-staff1)
  curl -s $B/me/state -H "Authorization: Bearer $S1"     # persons 의 148: certExpiry 2027-12-31, certHasPhoto true
  curl -s $B/stores/27/staff -H "Authorization: Bearer $S1"   # 58 의 person.certExpiry·certDaysLeft
  ```
- 기대: 알바생 화면은 동료의 보건증 정보를 쓰지 않는다. 직원 화면 코드에는 `certDaysLeft`·`certExpiry` 를 쓰는 곳이 없고, `web_*`·`employer_*` 화면에서만 쓴다. 그러니 알바생에게는 내려 주지 않는 것이 맞다.
- 실제: 동료의 만료일·알림일·사진 여부가 내려온다. 사진 파일 자체는 403 으로 막힌다.
- 원인: `dto/StaffDto.java:41-49` `forViewer` 가 연락처·시급은 지우지만 cert 필드는 일부러 남긴다. `service/StateService.java:140` 의 `AppStateDto.Person.from` 은 viewer 와 상관없이 cert 를 넣는다.
- 영향: 건강 관련 정보가 필요 이상으로 노출된다. 의도된 설계라면 무시해도 된다.

### [낮음] 만료일·알림일 상한이 없다

- 재현:
  ```sh
  curl -s -XPUT $B/me/health-cert -H "Authorization: Bearer $S2" -F expiry=9999-12-31 -F alertDays=2147483647 -F "photo=@a.png;type=image/png"
  ```
- 기대: 보건증 유효기간은 1년이다. 만료일이 지나치게 먼 값이면 거부한다. 알림일도 만료일까지 남은 일수 정도로 제한한다.
- 실제: 200. `certDaysLeft: 2912122` 가 나온다. 사장님에게 "만료일 9999.12.31" 알림이 간다.
- 원인: `service/DocumentService.java:52` 는 과거 날짜만 막는다. 57줄은 음수만 막는다.
- 영향: 입력 실수(예: 2207년)가 그대로 저장되어 만료 관리가 무력해진다.

## 통과한 케이스

- 정상 PNG 업로드 → 200, `certExpiry`·`certAlertDays`(내림차순)·`certHasPhoto:true`·`certDaysLeft` 응답, DB 반영
- 사진 없음 → 400 `PHOTO_REQUIRED`
- 빈 파일(0바이트) → 400 `PHOTO_REQUIRED`
- text/plain 파일 → 400 `INVALID_FILE_TYPE`
- HTML 본문을 `image/png` 로 위장 → 400 (매직 바이트 검사)
- SVG(스크립트 포함) → 400
- 2바이트 잘린 PNG → 400
- octet-stream + `.jpg`(FE 방식) → 200
- octet-stream + `.txt` → 400
- 대문자 확장자 `photo.JPG` → 200
- `photo.jpg.exe`, `.avif`, `.bmp` → 400
- 경로 조작 파일명 `../../../etc/passwd.png`, `..%2F..%2Fx.png` → 200 이지만 UUID 이름으로 `health-cert/143/` 안에만 저장됨 (루트 밖 파일 없음)
- 한글·이모지 파일명, 300자 파일명 → 200, UUID 로 저장
- 11MB → 413 `FILE_TOO_LARGE` `{code,message}` 모양
- 정확히 10MB(10485760B) → 200, 10MB+1B → 413
- 만료일 오늘(2026-11-17) → 200, `certDaysLeft:0`
- 만료일 어제 → 400 `EXPIRY_IN_PAST`
- 만료일 형식 `2027/06/30`, 없는 날짜 `2027-02-30`, 누락, 빈 문자열 → 400 `VALIDATION_FAILED`
- alertDays 누락 → 400, `-1`·`30,-5` → 400 `INVALID_ALERT_DAYS`, `abc`·`2147483648` → 400
- alertDays 중복 `7,7,30,0` → `[30,7,0]` 중복 제거, 공백 `" 30 , 7"` → `[30,7]`, 필드 반복 `alertDays=30&alertDays=7` → `[30,7]`
- alertDays 20개(정확히 50자) → 200
- `photo` 를 문자열 필드로 → 400
- photo 파트 두 개 → 200 (첫 번째 사용)
- JSON 본문 → 415, POST → 405
- 동시 업로드 8개 → 모두 200, DB 는 한 값으로 일관 (500·락 오류 없음)
- 만료 지난 상태에서 같은 만료일 재등록 → 400, 새 만료일로 갱신 → 200
- 만료 하루 지남(SQL) → `/staff/57` `certDaysLeft:-1`, 대시보드 `certAlerts` 에 `daysLeft:-1`, 미등록 매니저는 `daysLeft:null`
- 갱신 알림: 재직 중인 모든 매장(A·B) 사장님에게 `CERT` "알바이님이 보건증을 갱신했어요" / "만료일 yyyy.MM.dd", refId = 각 매장 staffId
- 대기 중(PENDING) 신청자의 업로드 → 사장님 알림 없음, 퇴사 뒤 업로드 → 퇴사한 매장 사장님 알림 없음
- `GET /me/health-cert/photo` 본인 → 200, 올린 바이트 그대로, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`
- 사진 없는 사용자(매니저·사장님) `/me/health-cert/photo` → 404 `보건증 사진이 없어요`
- 인증 없이 두 사진 엔드포인트 → 401
- A 사장님 → 자기 매장 직원 사진 200, 사진 없는 직원 404
- B 사장님 → A 매장 경로 403, B 경로 + A 직원 id 404
- A 사장님 → A 경로 + B 직원 id 404
- 매니저·동료 알바·본인(직원 경로)·무소속·신청자 → 403
- 없는 매장 404, 없는 직원 404, staffId `abc` 400
- FE 계약: `uploadHealthCertRemote` 의 필드(`expiry` yyyy-MM-dd, `alertDays` "30,14,7,0", 파일 필드 `photo`)가 BE 바인딩과 맞음. `/me/state` Person 의 `certExpiry`(문자열)·`certAlertDays`(int 리스트, 없으면 `[]`)·`certHasPhoto` 가 FE `Person.fromJson` 과 맞음. 오류 응답 `{code,message}` 를 FE `ApiClient._error` 가 읽음 (위 500 두 건 제외)

## 못 한 것

- 웹(Flutter) 컨테이너를 띄우지 않아 화면에서 사진이 보이는지는 확인하지 못했다. 코드로 본 관찰 하나: `employer_staff_documents_screen.dart:41` 의 캐시 키 `?v=${certExpiry}-${alertDays}` 는 사진만 바꾸고 만료일·알림일이 같으면 URL 이 그대로다. 그러면 Flutter `ImageCache` 가 한 세션 동안 예전 사진을 보여 줄 수 있다. 실행해 확인하지 못해 발견으로 올리지 않았다.
- 실제 HEIC 사진을 웹 사장님 화면(Chrome)이 표시할 수 있는지는 FE 를 띄우지 않아 확인하지 못했다.
- 자정(KST) 경계에서 실제 시계가 바뀌는 순간의 `EXPIRY_IN_PAST` 판정은 기다릴 수 없어 확인하지 못했다. 코드상 `TimeUtil.today()`(KST)를 쓰고, `certDaysLeft` 는 `LocalDate.now()` 를 쓰지만 컨테이너 `TZ=Asia/Seoul` 이라 같다.
- 매니저가 직원 보건증을 볼 수 없는 것(403)은 `api_design.md` 의 "사장님" 권한과 맞아서 정상으로 봤다.
- 퇴사·거절 처리, cert-renewal-requests 자체는 04번 영역이라 깊이 보지 않았다.
