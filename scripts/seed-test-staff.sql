-- 근무표 생성 테스트용 직원 8명을 매장에 넣는다. 여러 번 실행해도 중복으로 들어가지 않는다.
-- 실행 (매장 코드를 바꿔서):
--   (echo "SET @code='ABCD-EFGH';"; cat scripts/seed-test-staff.sql) \
--     | sudo docker compose exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" moneybug'
-- 지우기: scripts/seed-test-staff.sql 맨 아래 주석 참고.

SET @sid := (SELECT store_id FROM store WHERE code = @code);
SELECT IF(@sid IS NULL, CONCAT('매장 코드를 찾을 수 없어요: ', @code), CONCAT('매장 id ', @sid)) AS info;

-- 매장 파트를 시작 시각 순으로 (기본: 오픈 · 미들 · 마감)
SET @p1 := (SELECT name FROM store_part WHERE store_id = @sid ORDER BY start_min LIMIT 1);
SET @p2 := (SELECT name FROM store_part WHERE store_id = @sid ORDER BY start_min LIMIT 1 OFFSET 1);
SET @p3 := (SELECT name FROM store_part WHERE store_id = @sid ORDER BY start_min LIMIT 1 OFFSET 2);
SET @p2 := COALESCE(@p2, @p1);
SET @p3 := COALESCE(@p3, @p2);

-- 테스트 계정 (카카오 로그인 불가: kakao_id 가 실제 카카오 id 가 아님)
INSERT IGNORE INTO users (kakao_id, name, full_name, phone_consent) VALUES
  ('test-staff-1', '김매니저', '김매니저', FALSE),
  ('test-staff-2', '이정직', '이정직', FALSE),
  ('test-staff-3', '박오픈', '박오픈', FALSE),
  ('test-staff-4', '최미들', '최미들', FALSE),
  ('test-staff-5', '정마감', '정마감', FALSE),
  ('test-staff-6', '한주말', '한주말', FALSE),
  ('test-staff-7', '윤저녁', '윤저녁', FALSE),
  ('test-staff-8', '서연소', '서연소', FALSE);

-- 근무 설정: fixed_parts = 월~일 고정 파트(알바생), work_hours = 월~일 출퇴근 분(직원)
INSERT INTO store_worker (store_id, worker_id, hourly_wage, tax_type, status, part, kind,
                          weekly_holiday_auto, premium, tone, fixed_parts, work_hours, joined_at)
SELECT @sid, u.user_id, t.wage, 'BUSINESS_TAX', 'ACTIVE', t.part, t.kind, TRUE, FALSE, t.tone,
       t.fixed_parts, t.work_hours, CURDATE()
FROM (
  SELECT 'test-staff-1' AS kid, 12000 AS wage, '직원' AS part, 'MANAGER' AS kind, 'PRIMARY' AS tone,
         NULL AS fixed_parts,
         CAST(JSON_ARRAY(JSON_OBJECT('startMin', 540, 'endMin', 1080), JSON_OBJECT('startMin', 540, 'endMin', 1080),
                         JSON_OBJECT('startMin', 540, 'endMin', 1080), JSON_OBJECT('startMin', 540, 'endMin', 1080),
                         JSON_OBJECT('startMin', 540, 'endMin', 1080), NULL, NULL) AS CHAR) AS work_hours
  UNION ALL
  SELECT 'test-staff-2', 11000, '직원', 'FULLTIME', 'INFO', NULL,
         CAST(JSON_ARRAY(NULL, JSON_OBJECT('startMin', 720, 'endMin', 1260), JSON_OBJECT('startMin', 720, 'endMin', 1260),
                         JSON_OBJECT('startMin', 720, 'endMin', 1260), JSON_OBJECT('startMin', 720, 'endMin', 1260),
                         JSON_OBJECT('startMin', 720, 'endMin', 1260), NULL) AS CHAR)
  UNION ALL
  SELECT 'test-staff-3', 10320, @p1, 'PART_TIMER', 'ACCENT',
         CAST(JSON_ARRAY(JSON_ARRAY(@p1), JSON_ARRAY(), JSON_ARRAY(@p1), JSON_ARRAY(),
                         JSON_ARRAY(@p1), JSON_ARRAY(@p1, @p2), JSON_ARRAY()) AS CHAR), NULL
  UNION ALL
  SELECT 'test-staff-4', 10320, @p2, 'PART_TIMER', 'PRIMARY',
         CAST(JSON_ARRAY(JSON_ARRAY(@p2), JSON_ARRAY(@p2), JSON_ARRAY(), JSON_ARRAY(@p2),
                         JSON_ARRAY(@p2), JSON_ARRAY(), JSON_ARRAY()) AS CHAR), NULL
  UNION ALL
  SELECT 'test-staff-5', 10500, @p3, 'PART_TIMER', 'DANGER',
         CAST(JSON_ARRAY(JSON_ARRAY(@p3), JSON_ARRAY(@p3), JSON_ARRAY(@p3), JSON_ARRAY(@p3),
                         JSON_ARRAY(@p3), JSON_ARRAY(), JSON_ARRAY()) AS CHAR), NULL
  UNION ALL
  SELECT 'test-staff-6', 10320, @p1, 'PART_TIMER', 'INFO',
         CAST(JSON_ARRAY(JSON_ARRAY(), JSON_ARRAY(), JSON_ARRAY(), JSON_ARRAY(),
                         JSON_ARRAY(), JSON_ARRAY(@p1, @p2), JSON_ARRAY(@p1, @p2)) AS CHAR), NULL
  UNION ALL
  SELECT 'test-staff-7', 10320, @p3, 'PART_TIMER', 'ACCENT',
         CAST(JSON_ARRAY(JSON_ARRAY(), JSON_ARRAY(), JSON_ARRAY(@p3), JSON_ARRAY(@p3),
                         JSON_ARRAY(), JSON_ARRAY(@p3), JSON_ARRAY(@p2, @p3)) AS CHAR), NULL
  UNION ALL
  SELECT 'test-staff-8', 10320, @p2, 'MINOR', 'PRIMARY',
         CAST(JSON_ARRAY(JSON_ARRAY(), JSON_ARRAY(@p2), JSON_ARRAY(), JSON_ARRAY(@p2),
                         JSON_ARRAY(), JSON_ARRAY(@p2), JSON_ARRAY()) AS CHAR), NULL
) t
JOIN users u ON u.kakao_id = t.kid
WHERE @sid IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM store_worker w WHERE w.store_id = @sid AND w.worker_id = u.user_id);

SELECT u.name, w.kind, w.part, w.status FROM store_worker w JOIN users u ON u.user_id = w.worker_id
WHERE w.store_id = @sid AND u.kakao_id LIKE 'test-staff-%' ORDER BY w.mapping_id;

-- 지우기 (근무·출근 기록이 있으면 먼저 지워야 함):
--   DELETE s FROM schedule s JOIN store_worker w ON w.mapping_id = s.mapping_id
--     JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'test-staff-%';
--   DELETE w FROM store_worker w JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'test-staff-%';
--   DELETE FROM users WHERE kakao_id LIKE 'test-staff-%';
