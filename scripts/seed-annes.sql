-- 앤티앤스 데이터셋: 영업시간 + 파트 8개 + 직원 5명 + 알바 3명. 여러 번 실행해도 중복으로 들어가지 않는다.
-- 실행 (매장 코드 기본값 GXM4-RKNQ):
--   sudo docker compose exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" moneybug' < scripts/seed-annes.sql
-- 다른 매장에 넣으려면 앞에 코드를 붙인다:
--   (echo "SET @code='ABCD-EFGH';"; cat scripts/seed-annes.sql) | sudo docker compose exec -T db sh -c '...'
-- 지우기: 맨 아래 주석 참고.
--
-- 직원 근무 파트(store_part.flex · days 컬럼)가 들어간 BE 가 한 번 뜬 뒤에 실행한다.
--
-- 영업: 평일 08~21시, 주말·공휴일 07~21시.
-- 직원 5명: 고정 시간 없는 유동 근무. 근무표 자동 생성이 직원 파트(필요 1명씩)에 고르게 돌려 넣는다.
--   오픈 평일 07~16 · 주말 오픈 06~15 (영업 1시간 전 출근) · 미들 11~20 · 마감 12~21 (퇴근 시각은 가정)
-- 알바 3명: 고정 파트(필요 인원 0 = 빈칸을 직원으로 채우지 않음)
--   평일 마감 : 월~금 15:30~20:30
--   주말 오픈 : 토 07:30~15:30, 일 09:30~16:00
--   주말 마감 : 토 15:30~20:30, 일 16:00~20:30

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

SET @code := COALESCE(@code, 'GXM4-RKNQ');
SET @sid := (SELECT store_id FROM store WHERE code = CONVERT(@code USING utf8mb4) COLLATE utf8mb4_unicode_ci);
SELECT IF(@sid IS NULL, CONCAT('매장 코드를 찾을 수 없어요: ', CONVERT(@code USING utf8mb4)), CONCAT('매장 id ', @sid)) AS info;

UPDATE store SET open_min = 480, close_min = 1260, weekend_open_min = 420, weekend_close_min = 1260
WHERE store_id = @sid;

-- flex = 직원 파트(영업시간으로 자르지 않음), days = 적용 요일(WEEKEND 는 공휴일 포함)
INSERT INTO store_part (store_id, name, start_min, end_min, tone, break_min, need, flex, days)
SELECT @sid, t.name, t.s, t.e, t.tone, t.brk, t.need, t.flex, t.days
FROM (SELECT '오픈' AS name, 420 AS s, 960 AS e, 'OPEN' AS tone, 60 AS brk, 1 AS need, TRUE AS flex, 'WEEKDAY' AS days
      UNION ALL SELECT '주말 오픈', 360, 900, 'OPEN', 60, 1, TRUE, 'WEEKEND'
      UNION ALL SELECT '미들', 660, 1200, 'MIDDLE', 60, 1, TRUE, 'ALL'
      UNION ALL SELECT '마감', 720, 1260, 'CLOSE', 60, 1, TRUE, 'ALL'
      UNION ALL SELECT '알바 마감', 930, 1230, 'CLOSE', 30, 0, FALSE, 'ALL'
      UNION ALL SELECT '알바 토오픈', 450, 930, 'OPEN', 30, 0, FALSE, 'ALL'
      UNION ALL SELECT '알바 일오픈', 570, 960, 'OPEN', 30, 0, FALSE, 'ALL'
      UNION ALL SELECT '알바 일마감', 960, 1230, 'CLOSE', 30, 0, FALSE, 'ALL') t
WHERE @sid IS NOT NULL
ON DUPLICATE KEY UPDATE start_min = VALUES(start_min), end_min = VALUES(end_min), tone = VALUES(tone),
                        break_min = VALUES(break_min), need = VALUES(need), flex = VALUES(flex), days = VALUES(days);

-- 테스트 계정 (카카오 로그인 불가: kakao_id 가 실제 카카오 id 가 아님)
INSERT IGNORE INTO users (kakao_id, name, full_name, phone_consent) VALUES
  ('annes-staff-01', '김서연', '김서연', FALSE),
  ('annes-staff-02', '이준호', '이준호', FALSE),
  ('annes-staff-03', '박지현', '박지현', FALSE),
  ('annes-staff-04', '최유나', '최유나', FALSE),
  ('annes-staff-05', '정민재', '정민재', FALSE),
  ('annes-alba-01', '윤하린', '윤하린', FALSE),
  ('annes-alba-02', '오세진', '오세진', FALSE),
  ('annes-alba-03', '임도윤', '임도윤', FALSE);

INSERT INTO store_worker (store_id, worker_id, hourly_wage, tax_type, status, part, kind,
                          weekly_holiday_auto, premium, tone, fixed_parts, work_hours, joined_at)
SELECT @sid, u.user_id, t.wage, t.tax, 'ACTIVE', t.part, t.kind, TRUE, FALSE, t.tone, t.fixed, NULL, CURDATE()
FROM (
  SELECT 'annes-staff-01' AS kid, 12000 AS wage, '4_INSURANCE' AS tax, '직원' AS part, 'FULLTIME' AS kind,
         'PRIMARY' AS tone, NULL AS fixed
  UNION ALL SELECT 'annes-staff-02', 12000, '4_INSURANCE', '직원', 'FULLTIME', 'ACCENT', NULL
  UNION ALL SELECT 'annes-staff-03', 12000, '4_INSURANCE', '직원', 'FULLTIME', 'INFO', NULL
  UNION ALL SELECT 'annes-staff-04', 12000, '4_INSURANCE', '직원', 'FULLTIME', 'DANGER', NULL
  UNION ALL SELECT 'annes-staff-05', 12000, '4_INSURANCE', '직원', 'FULLTIME', 'PRIMARY', NULL
  -- 평일 마감
  UNION ALL SELECT 'annes-alba-01', 10320, 'BUSINESS_TAX', '알바 마감', 'PART_TIMER', 'DANGER',
         '[["알바 마감"],["알바 마감"],["알바 마감"],["알바 마감"],["알바 마감"],[],[]]'
  -- 주말 오픈
  UNION ALL SELECT 'annes-alba-02', 10320, 'BUSINESS_TAX', '알바 토오픈', 'PART_TIMER', 'ACCENT',
         '[[],[],[],[],[],["알바 토오픈"],["알바 일오픈"]]'
  -- 주말 마감
  UNION ALL SELECT 'annes-alba-03', 10320, 'BUSINESS_TAX', '알바 마감', 'PART_TIMER', 'INFO',
         '[[],[],[],[],[],["알바 마감"],["알바 일마감"]]'
) t
JOIN users u ON u.kakao_id = t.kid
WHERE @sid IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM store_worker w WHERE w.store_id = @sid AND w.worker_id = u.user_id);

-- 사업장 규모가 '자동'이면 재직 인원으로 5인 미만 여부를 다시 맞춘다(앱은 직원 승인 때 맞춘다).
UPDATE store s SET s.is_under_5 =
  ((SELECT COUNT(*) FROM store_worker w WHERE w.store_id = s.store_id AND w.status = 'ACTIVE') < 5)
WHERE s.store_id = @sid AND s.size_mode = 'AUTO';

SELECT name, start_min, end_min, break_min, need, flex, days FROM store_part WHERE store_id = @sid ORDER BY start_min, end_min;
SELECT u.name, w.kind, w.part, w.fixed_parts FROM store_worker w JOIN users u ON u.user_id = w.worker_id
WHERE w.store_id = @sid AND u.kakao_id LIKE 'annes-%' ORDER BY u.kakao_id;

-- 지우기 (출근 기록이 있으면 먼저 지워야 함):
--   DELETE a FROM attendance a JOIN schedule s ON s.schedule_id = a.schedule_id JOIN store_worker w ON w.mapping_id = s.mapping_id
--     JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'annes-%';
--   DELETE s FROM schedule s JOIN store_worker w ON w.mapping_id = s.mapping_id
--     JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'annes-%';
--   DELETE w FROM store_worker w JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'annes-%';
--   DELETE FROM users WHERE kakao_id LIKE 'annes-%';
--   DELETE FROM store_part WHERE store_id = @sid AND (name LIKE '알바 %' OR name = '주말 오픈');
