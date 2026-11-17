-- 매장 설정(영업 08~23시, 오픈·미들·마감) + 매니저 1명 + 알바 10명. 여러 번 실행해도 중복으로 들어가지 않는다.
-- 실행 (매장 코드를 바꿔서):
--   (echo "SET @code='ABCD-EFGH';"; cat scripts/seed-shop.sql) \
--     | sudo docker compose exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" moneybug'
-- 지우기: 맨 아래 주석 참고.
--
-- 배치 (fixed_parts 는 월~일 순)
--   월화조   : 오픈 1 · 미들 1 · 마감 1 (월·화)
--   수목금조 : 오픈 1 · 미들 1 · 마감 1 (수·목·금)
--   토일조   : 오픈 2 · 미들 1 · 마감 1 (토·일)
--   매니저   : 월~금 08~17시

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

SET @sid := (SELECT store_id FROM store WHERE code = CONVERT(@code USING utf8mb4) COLLATE utf8mb4_unicode_ci);
SELECT IF(@sid IS NULL, CONCAT('매장 코드를 찾을 수 없어요: ', @code), CONCAT('매장 id ', @sid)) AS info;

-- 영업시간 08:00~23:00(주말 같음), 사업장 규모 5인 이상
UPDATE store SET open_min = 480, close_min = 1380, weekend_open_min = 480, weekend_close_min = 1380,
                 size_mode = 'OVER5', is_under_5 = FALSE
WHERE store_id = @sid;

-- 파트. 필요 인원은 요일 구분이 없어 오픈도 1명; 주말 오픈 2명째는 고정 파트로 넣는다.
INSERT INTO store_part (store_id, name, start_min, end_min, tone, break_min, need)
SELECT @sid, t.name, t.s, t.e, t.tone, 30, 1
FROM (SELECT '오픈' AS name, 480 AS s, 780 AS e, 'OPEN' AS tone
      UNION ALL SELECT '미들', 720, 1080, 'MIDDLE'
      UNION ALL SELECT '마감', 1020, 1380, 'CLOSE') t
WHERE @sid IS NOT NULL
ON DUPLICATE KEY UPDATE start_min = VALUES(start_min), end_min = VALUES(end_min), tone = VALUES(tone),
                        break_min = VALUES(break_min), need = VALUES(need);

-- 테스트 계정 (카카오 로그인 불가: kakao_id 가 실제 카카오 id 가 아님)
INSERT IGNORE INTO users (kakao_id, name, full_name, phone_consent) VALUES
  ('shop-staff-00', '김매니저', '김매니저', FALSE),
  ('shop-staff-01', '월화오픈', '월화오픈', FALSE),
  ('shop-staff-02', '월화미들', '월화미들', FALSE),
  ('shop-staff-03', '월화마감', '월화마감', FALSE),
  ('shop-staff-04', '수목금오픈', '수목금오픈', FALSE),
  ('shop-staff-05', '수목금미들', '수목금미들', FALSE),
  ('shop-staff-06', '수목금마감', '수목금마감', FALSE),
  ('shop-staff-07', '주말오픈A', '주말오픈A', FALSE),
  ('shop-staff-08', '주말오픈B', '주말오픈B', FALSE),
  ('shop-staff-09', '주말미들', '주말미들', FALSE),
  ('shop-staff-10', '주말마감', '주말마감', FALSE),

SET @mgr := '[{"startMin":480,"endMin":1020},{"startMin":480,"endMin":1020},{"startMin":480,"endMin":1020},{"startMin":480,"endMin":1020},{"startMin":480,"endMin":1020},null,null]';

INSERT INTO store_worker (store_id, worker_id, hourly_wage, tax_type, status, part, kind,
                          weekly_holiday_auto, premium, tone, fixed_parts, work_hours, joined_at)
SELECT @sid, u.user_id, t.wage, 'BUSINESS_TAX', 'ACTIVE', t.part, t.kind, TRUE, FALSE, t.tone,
       t.fixed, t.wh, CURDATE()
FROM (
  SELECT 'shop-staff-00' AS kid, 12000 AS wage, '직원' AS part, 'MANAGER' AS kind, 'PRIMARY' AS tone,
         NULL AS fixed, @mgr AS wh
  UNION ALL SELECT 'shop-staff-01', 10320, '오픈', 'PART_TIMER', 'ACCENT',  '[["오픈"],["오픈"],[],[],[],[],[]]', NULL
  UNION ALL SELECT 'shop-staff-02', 10320, '미들', 'PART_TIMER', 'PRIMARY', '[["미들"],["미들"],[],[],[],[],[]]', NULL
  UNION ALL SELECT 'shop-staff-03', 10320, '마감', 'PART_TIMER', 'DANGER',  '[["마감"],["마감"],[],[],[],[],[]]', NULL
  UNION ALL SELECT 'shop-staff-04', 10320, '오픈', 'PART_TIMER', 'ACCENT',  '[[],[],["오픈"],["오픈"],["오픈"],[],[]]', NULL
  UNION ALL SELECT 'shop-staff-05', 10320, '미들', 'PART_TIMER', 'PRIMARY', '[[],[],["미들"],["미들"],["미들"],[],[]]', NULL
  UNION ALL SELECT 'shop-staff-06', 10320, '마감', 'PART_TIMER', 'DANGER',  '[[],[],["마감"],["마감"],["마감"],[],[]]', NULL
  UNION ALL SELECT 'shop-staff-07', 10320, '오픈', 'PART_TIMER', 'ACCENT',  '[[],[],[],[],[],["오픈"],["오픈"]]', NULL
  UNION ALL SELECT 'shop-staff-08', 10320, '오픈', 'PART_TIMER', 'INFO',    '[[],[],[],[],[],["오픈"],["오픈"]]', NULL
  UNION ALL SELECT 'shop-staff-09', 10320, '미들', 'PART_TIMER', 'PRIMARY', '[[],[],[],[],[],["미들"],["미들"]]', NULL
  UNION ALL SELECT 'shop-staff-10', 10320, '마감', 'PART_TIMER', 'DANGER',  '[[],[],[],[],[],["마감"],["마감"]]', NULL
) t
JOIN users u ON u.kakao_id = t.kid
WHERE @sid IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM store_worker w WHERE w.store_id = @sid AND w.worker_id = u.user_id);

SELECT name, start_min, end_min, need FROM store_part WHERE store_id = @sid ORDER BY start_min;
SELECT u.name, w.kind, w.part, w.fixed_parts FROM store_worker w JOIN users u ON u.user_id = w.worker_id
WHERE w.store_id = @sid AND u.kakao_id LIKE 'shop-staff-%' ORDER BY u.kakao_id;

-- 지우기 (출근 기록이 있으면 먼저 지워야 함):
--   DELETE a FROM attendance a JOIN schedule s ON s.schedule_id = a.schedule_id JOIN store_worker w ON w.mapping_id = s.mapping_id
--     JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'shop-staff-%';
--   DELETE s FROM schedule s JOIN store_worker w ON w.mapping_id = s.mapping_id
--     JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'shop-staff-%';
--   DELETE w FROM store_worker w JOIN users u ON u.user_id = w.worker_id WHERE u.kakao_id LIKE 'shop-staff-%';
--   DELETE FROM users WHERE kakao_id LIKE 'shop-staff-%';
