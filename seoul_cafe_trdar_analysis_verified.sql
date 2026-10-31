-- ============================================================
-- 같은 상권, 다른 성장 신호 : 서울시 커피-음료 상권 분석 (DuckDB)
-- 원천: 서울시 상권분석서비스 추정매출-상권 / 점포-상권 (2024, 2025)
-- 사전 처리: CP949 -> UTF-8 변환
-- ============================================================

-- 0. 적재 ---------------------------------------------------------
CREATE OR REPLACE TABLE raw_store_2024 AS SELECT * FROM read_csv('store_2024.csv', all_varchar = true);
CREATE OR REPLACE TABLE raw_store_2025 AS SELECT * FROM read_csv('store_2025.csv', all_varchar = true);
CREATE OR REPLACE TABLE raw_sales_2024 AS SELECT * FROM read_csv('sales_2024.csv', all_varchar = true);
CREATE OR REPLACE TABLE raw_sales_2025 AS SELECT * FROM read_csv('sales_2025.csv', all_varchar = true);

-- [검증 0] 2025 점포 파일만 컬럼명이 영문 -> 한글 스키마로 통일 후 UNION
CREATE OR REPLACE TABLE store AS
SELECT * FROM raw_store_2024
UNION ALL
SELECT stdr_yyqu_cd          AS 기준_년분기_코드,
       trdar_se_cd           AS 상권_구분_코드,
       trdar_se_cd_nm        AS 상권_구분_코드_명,
       trdar_cd              AS 상권_코드,
       trdar_cd_nm           AS 상권_코드_명,
       svc_induty_cd         AS 서비스_업종_코드,
       svc_induty_cd_nm      AS 서비스_업종_코드_명,
       stor_co               AS 점포_수,
       similr_induty_stor_co AS 유사_업종_점포_수,
       opbiz_rt              AS 개업_율,
       opbiz_stor_co         AS 개업_점포_수,
       clsbiz_rt             AS 폐업_률,
       clsbiz_stor_co        AS 폐업_점포_수,
       frc_stor_co           AS 프랜차이즈_점포_수
FROM raw_store_2025;

CREATE OR REPLACE TABLE sales AS
SELECT * FROM raw_sales_2024 UNION ALL SELECT * FROM raw_sales_2025;

-- 1. 정합성 검증 ---------------------------------------------------

-- [검증 1] 키 중복 (분기 x 상권 x 업종)
SELECT 'store' AS tbl, count(*) AS dup_keys
FROM (SELECT 기준_년분기_코드, 상권_코드, 서비스_업종_코드
      FROM store GROUP BY ALL HAVING count(*) > 1)
UNION ALL
SELECT 'sales', count(*)
FROM (SELECT 기준_년분기_코드, 상권_코드, 서비스_업종_코드
      FROM sales GROUP BY ALL HAVING count(*) > 1);

-- [검증 2] NULL / 숫자 변환 실패 / 0 이하 값
SELECT count(*) FILTER (WHERE TRY_CAST(당월_매출_금액 AS DOUBLE) IS NULL) AS sales_null,
       count(*) FILTER (WHERE TRY_CAST(당월_매출_건수 AS DOUBLE) IS NULL) AS txn_null,
       count(*) FILTER (WHERE 당월_매출_금액::DOUBLE <= 0)               AS sales_le0
FROM sales;

-- [검증 3] 분모 정의: 유사_업종_점포_수 = 점포_수 + 프랜차이즈_점포_수 인가?
--   -> 전 행 일치. 점포_수는 프랜차이즈 제외값이므로 분모는 유사_업종_점포_수 사용
SELECT count(*) FILTER (WHERE
  TRY_CAST(유사_업종_점포_수 AS INTEGER)
  = TRY_CAST(점포_수 AS INTEGER)
  + TRY_CAST(프랜차이즈_점포_수 AS INTEGER)
) AS matched, count(*) AS total FROM store;

-- [검증 4] 매출 합계 구조: 주중+주말 = 총액 (일치), 성별 합 = 총액 (불일치 -> 총액 컬럼만 사용)
SELECT count(*) FILTER (WHERE abs(당월_매출_금액::DOUBLE - (주중_매출_금액::DOUBLE + 주말_매출_금액::DOUBLE)) > 1) AS wd_we_mismatch,
       count(*) FILTER (WHERE abs(당월_매출_금액::DOUBLE - (남성_매출_금액::DOUBLE + 여성_매출_금액::DOUBLE)) > 1) AS gender_mismatch,
       count(*) AS total
FROM sales;

-- [검증 5] JOIN 커버리지: 점포는 있으나 추정매출 행이 없는 커피 상권
WITH s AS (SELECT 기준_년분기_코드 q, 상권_코드 cd FROM store
           WHERE 서비스_업종_코드 = 'CS100010' AND 유사_업종_점포_수::INT > 0),
     m AS (SELECT 기준_년분기_코드 q, 상권_코드 cd FROM sales
           WHERE 서비스_업종_코드 = 'CS100010')
SELECT s.q, count(*) FILTER (WHERE m.cd IS NULL) AS store_only, count(*) AS store_rows
FROM s LEFT JOIN m USING (q, cd)
GROUP BY 1 ORDER BY 1;

-- [검증 6] 상권 코드 연도 간 일치 (2024Q4 vs 2025Q4)
WITH a AS (SELECT DISTINCT 상권_코드 cd, 상권_코드_명 nm FROM store WHERE 기준_년분기_코드 = '20244'),
     b AS (SELECT DISTINCT 상권_코드 cd, 상권_코드_명 nm FROM store WHERE 기준_년분기_코드 = '20254')
SELECT (SELECT count(*) FROM a WHERE cd NOT IN (SELECT cd FROM b)) AS dropped,
       (SELECT count(*) FROM b WHERE cd NOT IN (SELECT cd FROM a)) AS added,
       (SELECT count(*) FROM a JOIN b USING (cd) WHERE a.nm <> b.nm) AS renamed;

-- 2. 분석 마트 -----------------------------------------------------
CREATE OR REPLACE TABLE cafe_q AS
SELECT s.기준_년분기_코드            AS q,
       s.상권_코드                  AS cd,
       s.상권_코드_명               AS nm,
       s.상권_구분_코드_명          AS tp,
       s.유사_업종_점포_수::INT     AS n_store,
       s.개업_점포_수::INT          AS n_open,
       s.폐업_점포_수::INT          AS n_close,
       m.당월_매출_금액::DOUBLE     AS sales,
       m.당월_매출_건수::DOUBLE     AS txn
FROM store s
JOIN sales m USING (기준_년분기_코드, 상권_코드, 서비스_업종_코드)
WHERE s.서비스_업종_코드 = 'CS100010';

-- 3. KPI (2024Q4 -> 2025Q4) ---------------------------------------
--   점포당 매출 = 점포당 거래건수 x 거래당 매출
CREATE OR REPLACE TABLE kpi AS
WITH a AS (SELECT * FROM cafe_q WHERE q = '20244'),
     b AS (SELECT * FROM cafe_q WHERE q = '20254'),
     op AS (SELECT 상권_코드 AS cd,
                   sum(개업_점포_수::INT) AS open25,
                   sum(폐업_점포_수::INT) AS close25
            FROM store
            WHERE 서비스_업종_코드 = 'CS100010' AND 기준_년분기_코드 LIKE '2025%'
            GROUP BY 1)
SELECT b.cd, b.nm, b.tp,
       a.n_store AS s0, b.n_store AS s1,
       a.sales AS m0, b.sales AS m1, a.txn AS t0, b.txn AS t1,
       b.sales / a.sales - 1                                   AS g_sales,
       b.n_store::DOUBLE / a.n_store - 1                       AS g_store,
       (b.sales / b.n_store) / (a.sales / a.n_store) - 1       AS g_ps,      -- 점포당 매출 성장률
       (b.txn / b.n_store) / (a.txn / a.n_store) - 1           AS g_txn_ps,  -- 점포당 거래건수 성장률
       (b.sales / b.txn) / (a.sales / a.txn) - 1               AS g_atv,     -- 거래당 매출 성장률 (가격과 동일하지 않음)
       op.open25::DOUBLE  / a.n_store                          AS open_rt,
       op.close25::DOUBLE / a.n_store                          AS close_rt
FROM a
JOIN b  USING (cd)
JOIN op USING (cd)
WHERE a.n_store > 0 AND b.n_store > 0      -- 0 분모 제거
  AND a.sales > 0 AND a.txn > 0 AND b.txn > 0;

-- 서울 전체 지표 분해
SELECT sum(m1) / sum(m0) - 1                                     AS g_sales,
       sum(s1)::DOUBLE / sum(s0) - 1                             AS g_store,
       (sum(m1) / sum(s1)) / (sum(m0) / sum(s0)) - 1             AS g_ps,
       (sum(t1) / sum(s1)) / (sum(t0) / sum(s0)) - 1             AS g_txn_ps,
       (sum(m1) / sum(t1)) / (sum(m0) / sum(t0)) - 1             AS g_atv
FROM kpi;

-- 4. 순위 비교 (최소 점포 수 민감도: 5 / 10 / 20) -------------------
WITH f AS (SELECT * FROM kpi WHERE s0 >= 10 AND s1 >= 10),  -- 양쪽 연도 모두 기준 충족. 5, 20으로 바꿔 재실행
r AS (
  SELECT *,
         ROW_NUMBER()  OVER (ORDER BY g_sales  DESC) AS r_sales,
         ROW_NUMBER()  OVER (ORDER BY g_ps     DESC) AS r_ps,
         ROW_NUMBER()  OVER (ORDER BY g_txn_ps DESC) AS r_txn,
         PERCENT_RANK() OVER (ORDER BY g_ps)         AS pr_ps,
         count(*)      OVER ()                       AS n
  FROM f)
SELECT max(n)                                                    AS n_trdar,
       count(*) FILTER (WHERE r_sales <= 20 AND r_ps  <= 20)     AS overlap_sales_ps,
       count(*) FILTER (WHERE r_sales <= 20 AND pr_ps < 0.5)     AS top_sales_bottom_half_ps,
       corr(r_sales, r_ps)                                       AS spearman_sales_ps,
       count(*) FILTER (WHERE r_sales <= 20 AND r_txn <= 20)     AS overlap_sales_txn,
       corr(r_sales, r_txn)                                      AS spearman_sales_txn,
       count(*) FILTER (WHERE g_sales > 0)                       AS sales_up,
       count(*) FILTER (WHERE g_sales > 0 AND g_txn_ps < 0)      AS sales_up_demand_down
FROM r;

-- 5. 기간 안정성: Q4 단일 분기 vs 연간 합계 TOP 20 비교 -------------
CREATE OR REPLACE TABLE kpi_y AS
WITH y AS (
  SELECT cd, left(q, 4) AS yr,
         avg(n_store) AS ns, sum(sales) AS m,
         sum(txn) AS t, count(*) AS nq
  FROM cafe_q GROUP BY 1, 2)
SELECT a.cd, a.ns AS s0,
       b.m / a.m - 1                   AS g_sales,
       (b.m / b.ns) / (a.m / a.ns) - 1 AS g_ps,
       (b.t / b.ns) / (a.t / a.ns) - 1 AS g_txn_ps
FROM y a
JOIN y b ON a.cd = b.cd
        AND a.yr = '2024' AND b.yr = '2025'
WHERE a.nq = 4 AND b.nq = 4
  AND a.ns > 0 AND b.ns > 0 AND a.m > 0
  AND b.m > 0 AND a.t > 0 AND b.t > 0;

WITH pop AS (SELECT cd FROM kpi WHERE s0 >= 10 AND s1 >= 10),   -- 동일 모집단
     q4 AS (SELECT cd FROM kpi   WHERE cd IN (SELECT cd FROM pop) ORDER BY g_sales DESC LIMIT 20),
     yr AS (SELECT cd FROM kpi_y WHERE cd IN (SELECT cd FROM pop) ORDER BY g_sales DESC LIMIT 20)
SELECT count(*) AS overlap_q4_vs_annual FROM q4 JOIN yr USING (cd);

-- 6. 상권 유형별 분해 ----------------------------------------------
SELECT tp, count(*) AS n,
       sum(m1) / sum(m0) - 1                                  AS g_sales,
       sum(s1)::DOUBLE / sum(s0) - 1                          AS g_store,
       (sum(t1) / sum(s1)) / (sum(t0) / sum(s0)) - 1          AS g_txn_ps,
       (sum(m1) / sum(t1)) / (sum(m0) / sum(t0)) - 1          AS g_atv
FROM kpi WHERE s0 >= 10 AND s1 >= 10
GROUP BY 1 ORDER BY n DESC;

-- ============================================================
-- 7. 04페이지: 현장 조사 우선 후보 20곳 선정 (통합 기준)
-- 모집단: 2024Q4, 2025Q4 점포 각각 10개 이상 + 양 연도 4개 분기 매출 관측
-- 신규 개업 기회: 2025 개업 >= 3, 개업 > 폐업
-- 거래 활성도: 연간 점포당 거래건수 성장률 > 0
-- 지속성: 4개 분기 중 3개 분기 이상 전년 동기 대비 거래건수/점포 증가
-- 폐업 위험: 선정 조건 X, 2025 폐업 점포 합계 / 2025 평균 점포 수
-- 주 비교: 연간 총매출 성장률 TOP 20 / 보조 비교: Q4 총매출 성장률 TOP 20
-- ============================================================
CREATE OR REPLACE TABLE cand_base AS
WITH pop AS (
    SELECT cd FROM kpi WHERE s0 >= 10 AND s1 >= 10
),
qyoy AS (
    SELECT b.cd,
           count(*) FILTER (
               WHERE (b.txn / NULLIF(b.n_store, 0)) > (a.txn / NULLIF(a.n_store, 0))
           ) AS up_q,
           count(*) AS nq
    FROM cafe_q a
    JOIN cafe_q b
      ON a.cd = b.cd
     AND left(a.q, 4) = '2024'
     AND left(b.q, 4) = '2025'
     AND right(a.q, 1) = right(b.q, 1)
    WHERE a.n_store > 0 AND b.n_store > 0 AND a.txn > 0 AND b.txn > 0
    GROUP BY 1
),
oc AS (
    SELECT 상권_코드 AS cd,
           sum(개업_점포_수::INT) AS open25,
           sum(폐업_점포_수::INT) AS close25,
           avg(유사_업종_점포_수::DOUBLE) AS avg_store25,
           count(*) AS n_store_q25
    FROM store
    WHERE 서비스_업종_코드 = 'CS100010'
      AND 기준_년분기_코드 LIKE '2025%'
    GROUP BY 1
)
SELECT k.cd, k.nm, k.tp, k.s0, k.s1,
       k.g_sales                        AS g_sales_q4,
       y.g_sales                        AS g_sales_y,
       y.g_ps                           AS g_ps_y,
       y.g_txn_ps                       AS g_txn_ps_y,
       qy.up_q, qy.nq,
       oc.open25, oc.close25,
       oc.avg_store25,
       oc.open25::DOUBLE / NULLIF(oc.avg_store25, 0) AS open_rt,
       oc.close25::DOUBLE / NULLIF(oc.avg_store25, 0) AS close_rt
FROM kpi k
JOIN pop USING (cd)
JOIN kpi_y y USING (cd)
JOIN qyoy qy USING (cd)
JOIN oc USING (cd)
WHERE qy.nq = 4
  AND oc.n_store_q25 = 4
  AND oc.avg_store25 > 0;

-- 분석 모집단, 통합 조건 충족 수
SELECT count(*) AS population,
       count(*) FILTER (
           WHERE open25 >= 3 AND open25 > close25
             AND g_txn_ps_y > 0 AND up_q >= 3
       ) AS passed
FROM cand_base;

-- 신규 기준 TOP 20
CREATE OR REPLACE TABLE new20 AS
SELECT cd FROM cand_base
WHERE open25 >= 3
  AND open25 > close25
  AND g_txn_ps_y > 0
  AND up_q >= 3  -- 2/4, 4/4로 바꿔 민감도 분석
ORDER BY open25 DESC, g_txn_ps_y DESC, cd
LIMIT 20;

-- 기존 기준: 같은 555개 상권에서 기간만 달리 비교
CREATE OR REPLACE TABLE old20_y AS
SELECT cd FROM cand_base
ORDER BY g_sales_y DESC, cd LIMIT 20;

CREATE OR REPLACE TABLE old20 AS
SELECT cd FROM cand_base
ORDER BY g_sales_q4 DESC, cd LIMIT 20;

SELECT (SELECT count(*) FROM new20 JOIN old20_y USING (cd)) AS overlap_annual,
       (SELECT count(*) FROM new20 JOIN old20   USING (cd)) AS overlap_q4,
       (SELECT count(*) FROM old20_y JOIN old20 USING (cd)) AS overlap_old_annual_q4;

-- [폐업 리스크] '2025 폐업 점포 합계 / 2025 연평균 점포 수' 기준
-- 공식 서비스의 '분기별 폐업률'과는 다른 자체 위험 비교 지표
WITH risk AS (
    SELECT median(close_rt) AS median_close_rt FROM cand_base
)
SELECT c.nm, c.open25, c.close25,
       round(c.avg_store25, 2) AS avg_store_2025,
       round(c.close_rt * 100, 2) AS annual_closure_to_avg_store_pct,
       c.close_rt > risk.median_close_rt AS high_close_risk
FROM cand_base c JOIN new20 USING (cd) CROSS JOIN risk
ORDER BY c.open25 DESC, c.g_txn_ps_y DESC, c.cd;

-- 두 목록 특성 비교: 차이는 선정 목적의 차이이며 실제 영업 성과 검증이 아님
WITH med AS (SELECT median(close_rt) AS m FROM cand_base),
lists AS (
    SELECT '기존: 연간 매출 성장률' AS list, cd FROM old20_y
    UNION ALL
    SELECT '기존: Q4 매출 성장률', cd FROM old20
    UNION ALL
    SELECT '신규: 개업·거래·지속성', cd FROM new20
)
SELECT l.list,
       count(*) FILTER (WHERE c.g_txn_ps_y <= 0) AS annual_txn_per_store_non_growth,
       count(*) FILTER (WHERE c.up_q < 3) AS quarterly_growth_lt3,
       count(*) FILTER (WHERE c.close_rt > med.m) AS closure_risk_above_median,
       sum(c.open25) AS opened_store_count,  -- 정렬 기준과 연결된 '설계상 결과'. 성과 증거로 사용 금지
       median(c.s1) AS stores_q4_2025_median,
       round(median(c.g_sales_q4) * 100, 1) AS median_q4_sales_growth_pct,
       round(median(c.g_sales_y) * 100, 1) AS median_annual_sales_growth_pct
FROM lists l JOIN cand_base c USING (cd) CROSS JOIN med
GROUP BY 1;

-- Tableau용 전체 후보 CSV: 최종 결과 내보내기
COPY (
    WITH risk AS (SELECT median(close_rt) AS m FROM cand_base)
    SELECT c.*,
           c.close_rt > risk.m AS high_close_risk,
           (c.cd IN (SELECT cd FROM new20)) AS is_new20,
           (c.cd IN (SELECT cd FROM old20_y)) AS is_old20_annual,
           (c.cd IN (SELECT cd FROM old20)) AS is_old20_q4
    FROM cand_base c CROSS JOIN risk
    ORDER BY c.cd
) TO 'cafe_candidates_verified_for_tableau.csv' (HEADER, DELIMITER ',');

-- ============================================================
-- 8. 03페이지: 04페이지와 같은 모집단(cand_base 555곳), 연간 합계 기준으로 재계산
--   (4번 섹션은 Q4 단일 분기·557곳 기준이므로 03페이지 수치는 이 섹션을 사용)
-- ============================================================
CREATE OR REPLACE TABLE p03 AS
WITH y AS (
    SELECT cd, left(q, 4) AS yr, avg(n_store) AS ns, sum(sales) AS m, sum(txn) AS t
    FROM cafe_q GROUP BY 1, 2
)
SELECT c.cd, c.nm, c.tp,
       a.ns AS ns0, b.ns AS ns1, a.m AS m0, b.m AS m1, a.t AS t0, b.t AS t1,
       c.g_sales_y, c.g_ps_y, c.g_txn_ps_y,
       b.ns / a.ns - 1                         AS g_store_y,
       (b.m / b.t) / (a.m / a.t) - 1           AS g_atv_y   -- 거래당 매출 (가격과 동일하지 않음)
FROM cand_base c
JOIN y a ON a.cd = c.cd AND a.yr = '2024'
JOIN y b ON b.cd = c.cd AND b.yr = '2025';

-- [03-1] 초기 가설 검증: 총매출 vs 점포당 매출 / 점포당 거래건수 순위
WITH r AS (
    SELECT *,
           ROW_NUMBER() OVER (
             ORDER BY g_sales_y DESC, cd) AS r_sales,
           ROW_NUMBER() OVER (
             ORDER BY g_ps_y DESC, cd) AS r_ps,
           ROW_NUMBER() OVER (
             ORDER BY g_txn_ps_y DESC, cd) AS r_txn,
           PERCENT_RANK() OVER (
             ORDER BY g_ps_y) AS pr_ps
    FROM p03
)
SELECT count(*)                                              AS n_trdar,              -- 555
       count(*) FILTER (WHERE r_sales <= 20 AND r_ps <= 20)  AS overlap_sales_ps,     -- 15
       count(*) FILTER (WHERE r_sales <= 20 AND pr_ps < 0.5) AS top_sales_bottom_half,-- 0
       round(corr(r_sales, r_ps), 2)                         AS spearman_sales_ps,    -- 0.86
       count(*) FILTER (WHERE r_sales <= 20 AND r_txn <= 20) AS overlap_sales_txn,    -- 13
       round(corr(r_sales, r_txn), 2)                        AS spearman_sales_txn    -- 0.68
FROM r;

-- [03-2] 가설이 기각된 이유: 점포 수 변화의 산포가 매출 변화보다 훨씬 작음
SELECT round(stddev(g_store_y) * 100, 1) AS sd_store_pct,   -- 8.2
       round(stddev(g_sales_y) * 100, 1) AS sd_sales_pct    -- 34.7
FROM p03;

-- [03-3] KPI 분해 (서울 커피 상권 전체 / 상권 유형별)
--   총매출 = 점포 수 x 점포당 매출,  점포당 매출 = 점포당 거래건수 x 거래당 매출
SELECT 'Seoul' AS grp, count(*) AS n,
       round(100 * (sum(m1) / sum(m0) - 1), 2)                               AS g_sales,
       round(100 * (sum(ns1) / sum(ns0) - 1), 2)                             AS g_store,
       round(100 * ((sum(m1) / sum(ns1)) / (sum(m0) / sum(ns0)) - 1), 2)     AS g_ps,
       round(100 * ((sum(t1) / sum(ns1)) / (sum(t0) / sum(ns0)) - 1), 2)     AS g_txn_ps,
       round(100 * ((sum(m1) / sum(t1)) / (sum(m0) / sum(t0)) - 1), 2)       AS g_atv
FROM p03
UNION ALL
SELECT tp, count(*),
       round(100 * (sum(m1) / sum(m0) - 1), 2),
       round(100 * (sum(ns1) / sum(ns0) - 1), 2),
       round(100 * ((sum(m1) / sum(ns1)) / (sum(m0) / sum(ns0)) - 1), 2),
       round(100 * ((sum(t1) / sum(ns1)) / (sum(t0) / sum(ns0)) - 1), 2),
       round(100 * ((sum(m1) / sum(t1)) / (sum(m0) / sum(t0)) - 1), 2)
FROM p03 GROUP BY tp
ORDER BY n DESC;

-- [03-4] 문제 재정의: 총매출 x 점포당 거래건수 2x2
SELECT count(*) FILTER (WHERE g_sales_y >  0 AND g_txn_ps_y >  0) AS sales_up_txn_up,     -- 147
       count(*) FILTER (WHERE g_sales_y >  0 AND g_txn_ps_y <= 0) AS sales_up_txn_down,   -- 67
       count(*) FILTER (WHERE g_sales_y <= 0 AND g_txn_ps_y >  0) AS sales_down_txn_up,   -- 78
       count(*) FILTER (WHERE g_sales_y <= 0 AND g_txn_ps_y <= 0) AS sales_down_txn_down  -- 263
FROM p03;

-- ============================================================
-- 9. 02·04페이지 보조 검증
-- ============================================================

-- [02-1] 분모 효과: 555개 상권, 2024→2025 연간 기준
--   점포_수(프랜차이즈 제외)를 분모로 쓰면 점포당 거래건수 증감 부호가 바뀌는 상권 수
CREATE OR REPLACE TABLE denom_check AS
WITH c AS (
    SELECT s.기준_년분기_코드 AS q, s.상권_코드 AS cd,
           s.점포_수::INT          AS ns_excl_fr,   -- 프랜차이즈 제외 (잘못된 분모)
           s.유사_업종_점포_수::INT AS ns,           -- 프랜차이즈 포함 (사용한 분모)
           m.당월_매출_건수::DOUBLE AS t
    FROM store s
    JOIN sales m USING (기준_년분기_코드, 상권_코드, 서비스_업종_코드)
    WHERE s.서비스_업종_코드 = 'CS100010'
),
y AS (
    SELECT cd, left(q, 4) AS yr, avg(ns_excl_fr) AS nw, avg(ns) AS n, sum(t) AS t
    FROM c GROUP BY 1, 2
)
SELECT a.cd,
       (b.t / b.n)  / (a.t / a.n)  - 1 AS g_txn_ps_right,
       (b.t / b.nw) / (a.t / a.nw) - 1 AS g_txn_ps_excl_fr
FROM y a
JOIN y b ON a.cd = b.cd AND a.yr = '2024' AND b.yr = '2025'
WHERE a.cd IN (SELECT cd FROM cand_base)
  AND a.nw > 0 AND b.nw > 0;

SELECT count(*) AS n_trdar,                                                    -- 555
       count(*) FILTER (WHERE (g_txn_ps_right > 0) <> (g_txn_ps_excl_fr > 0)) AS sign_flip  -- 48
FROM denom_check;

WITH a AS (SELECT cd FROM denom_check ORDER BY g_txn_ps_right   DESC, cd LIMIT 20),
     b AS (SELECT cd FROM denom_check ORDER BY g_txn_ps_excl_fr DESC, cd LIMIT 20)
SELECT count(*) AS top20_overlap FROM a JOIN b USING (cd);                     -- 17

-- [02-2] 매출 누락 상권 프로파일 (2025Q4): 점포 비중은 작지만 소규모·특정 유형에 집중
WITH s AS (
    SELECT 상권_코드 AS cd, 상권_구분_코드_명 AS tp, 유사_업종_점포_수::INT AS n
    FROM store
    WHERE 서비스_업종_코드 = 'CS100010' AND 기준_년분기_코드 = '20254'
      AND 유사_업종_점포_수::INT > 0
),
m AS (
    SELECT 상권_코드 AS cd FROM sales
    WHERE 서비스_업종_코드 = 'CS100010' AND 기준_년분기_코드 = '20254'
)
SELECT s.tp,
       count(*) FILTER (WHERE m.cd IS NULL)                          AS missing_trdar,
       count(*)                                                      AS trdar,
       round(100.0 * count(*) FILTER (WHERE m.cd IS NULL) / count(*), 1) AS missing_pct,
       median(s.n) FILTER (WHERE m.cd IS NULL)                       AS missing_median_stores,
       sum(s.n) FILTER (WHERE m.cd IS NULL)                          AS missing_stores,
       sum(s.n)                                                      AS stores
FROM s LEFT JOIN m USING (cd)
GROUP BY ROLLUP (s.tp)
ORDER BY trdar DESC;

-- [04-1] 기존 연간 TOP 20의 제외 사유: 조건을 순서대로 적용했을 때 처음 충족하지 못한 기준
SELECT CASE WHEN c.cd IN (SELECT cd FROM new20) THEN '5_공통 선정'
            WHEN c.open25 < 3              THEN '1_개업 3곳 미만'
            WHEN c.open25 <= c.close25     THEN '2_개업 <= 폐업'
            WHEN c.g_txn_ps_y <= 0         THEN '3_점포당 거래건수 비증가'
            WHEN c.up_q < 3                THEN '4_분기 지속성 미달'
            ELSE '4b_조건 통과·개업 순위 밖' END AS reason,
       count(*) AS n
FROM cand_base c JOIN old20_y USING (cd)
GROUP BY 1 ORDER BY 1;

-- ============================================================
-- 10. 10페이지: 후보 20곳 후속 검증 (상권변화지표 · 카페 밀도)
--   입력 1) chg.csv               : 서울시 상권변화지표-상권 (UTF-8 변환)
--   입력 2) trdar_area.csv        : 상권 경계 SHP 속성 (상권 코드·유형·면적 m², spatial.py 출력)
--   입력 3) cafe_trdar_pairs.csv  : 소진공 상가업소 2026.09 카페(I21201) × 상권 공간 결합 결과
--                                   (spatial.py: GeoPandas within 결합, EPSG:5181, 상권별 중복 제거)
-- ============================================================
CREATE OR REPLACE TABLE chg AS
SELECT * FROM read_csv('chg.csv', all_varchar = true);

CREATE OR REPLACE TABLE trdar_area AS
SELECT cd::VARCHAR AS cd, nm, tp,
       relm_ar_m2::DOUBLE / 1e6 AS area_km2
FROM read_csv('trdar_area.csv', all_varchar = true);

CREATE OR REPLACE TABLE cafe_pairs AS
SELECT DISTINCT store_id, cd::VARCHAR AS cd
FROM read_csv('cafe_trdar_pairs.csv', all_varchar = true);

-- [10-1] 결합 커버리지: 555개 상권 모두 변화지표·경계와 연결되는가
SELECT count(*)                                                    AS n_trdar,
       count(h.상권_코드)                                          AS with_chg_2025q4,
       count(a.cd)                                                 AS with_boundary
FROM cand_base c
LEFT JOIN chg h        ON h.상권_코드 = c.cd AND h.기준_년분기_코드 = '20254'
LEFT JOIN trdar_area a ON a.cd = c.cd;

-- [10-2] 상권별 카페 수·밀도 (555개 상권)
CREATE OR REPLACE TABLE p10 AS
WITH cnt AS (
    SELECT cd, count(*) AS cafes FROM cafe_pairs GROUP BY 1
),
s25 AS (                                   -- 서울시 2025Q4 커피-음료 점포 수(프랜차이즈 포함)
    SELECT 상권_코드 AS cd, 유사_업종_점포_수::INT AS seoul_stores
    FROM store
    WHERE 서비스_업종_코드 = 'CS100010' AND 기준_년분기_코드 = '20254'
)
SELECT c.cd, c.nm, c.tp, c.g_txn_ps_y, c.open25, c.close25,
       a.area_km2,
       coalesce(n.cafes, 0)                         AS cafes,
       coalesce(n.cafes, 0) / a.area_km2            AS cafe_density,
       s.seoul_stores,
       h4.상권_변화_지표_명                          AS chg_2025q4,
       h6.상권_변화_지표_명                          AS chg_2026q2,
       (c.cd IN (SELECT cd FROM new20))             AS is_new20
FROM cand_base c
JOIN trdar_area a USING (cd)
LEFT JOIN cnt n   USING (cd)
LEFT JOIN s25 s   USING (cd)
LEFT JOIN chg h4  ON h4.상권_코드 = c.cd AND h4.기준_년분기_코드 = '20254'
LEFT JOIN chg h6  ON h6.상권_코드 = c.cd AND h6.기준_년분기_코드 = '20262';

-- [10-3] 상권 유형별 고밀도 기준: 555개 상권 안에서 유형별 상위 25%
CREATE OR REPLACE TABLE dens_cut AS
SELECT tp, quantile_cont(cafe_density, 0.75) AS cut_p75, count(*) AS n
FROM p10 GROUP BY 1;

-- [10-4] 후보 20곳 체크 표
CREATE OR REPLACE TABLE p10_check AS
SELECT p.*,
       d.cut_p75,
       p.cafe_density >= d.cut_p75     AS high_density,
       p.chg_2025q4 = '상권축소'        AS shrinking_2025q4,
       p.chg_2026q2 = '상권축소'        AS shrinking_2026q2
FROM p10 p JOIN dens_cut d USING (tp)
WHERE p.is_new20;

SELECT chg_2025q4, count(*) FROM p10_check GROUP BY 1 ORDER BY 2 DESC;
SELECT tp, count(*) AS n, count(*) FILTER (WHERE high_density) AS high FROM p10_check GROUP BY 1;
SELECT count(*) FILTER (WHERE shrinking_2025q4)                       AS shrinking,
       count(*) FILTER (WHERE high_density)                           AS high_density,
       count(*) FILTER (WHERE shrinking_2025q4 OR high_density)       AS any_flag,
       count(*) FILTER (WHERE shrinking_2025q4 AND high_density)      AS both_flags,
       count(*) FILTER (WHERE shrinking_2026q2)                       AS shrinking_latest
FROM p10_check;

-- [10-5] 점포 수 집계 비교: 소진공 카페 수 vs 서울시 커피-음료 점포 수
SELECT round(corr(cafes, seoul_stores), 3)                        AS corr_counts,
       round(median(cafes::DOUBLE / seoul_stores), 2)             AS median_ratio,
       count(*) FILTER (WHERE cafes::DOUBLE / seoul_stores < 0.5
                         OR cafes::DOUBLE / seoul_stores > 2)     AS ratio_outliers,
       count(*)                                                   AS n
FROM p10 WHERE seoul_stores > 0;
