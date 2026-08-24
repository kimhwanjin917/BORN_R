-- Data Cloud 통합 시연 쿼리 (org: main pjt)
-- 재무(CorpFinancialStmt_Home__dlm) + 시그널(ExternalSignal_Home__dlm) + CRM(ssot__Account__dlm) 통합
-- 실행: sf data360 query sql -o "main pjt" -q "<SQL>"

-- =========================================================
-- 데모 1: Top3 기업 랭킹 (시그널 활발도 + DART 최신 매출)
-- =========================================================
SELECT
  a.ssot__Name__c            AS company,
  COUNT(DISTINCT s.Id_c__c)  AS signal_count,
  COUNT(DISTINCT f.Id_c__c)  AS fin_stmt_count,
  MAX(f.Revenue_c_c__c)      AS dart_revenue
FROM ssot__Account__dlm a
JOIN ExternalSignal_Home__dlm s
  ON a.ssot__Id__c = s.Account_c_c__c
LEFT JOIN CorpFinancialStmt_Home__dlm f
  ON a.ssot__Id__c = f.Account_c_c__c
GROUP BY a.ssot__Name__c
ORDER BY signal_count DESC, dart_revenue DESC
LIMIT 3;

-- =========================================================
-- 데모 2: 주인공 계정 최신 시그널 상세 (뉴스 헤드라인)
--   :hero 를 대상 계정명으로 치환 (예: 코스메카코리아)
-- =========================================================
SELECT
  a.ssot__Name__c        AS company,
  s.Signal_Type_c_c__c   AS type,
  s.Title_c_c__c         AS headline
FROM ssot__Account__dlm a
JOIN ExternalSignal_Home__dlm s
  ON a.ssot__Id__c = s.Account_c_c__c
WHERE a.ssot__Name__c = ':hero'
LIMIT 10;

-- =========================================================
-- 데모 3: 주인공 계정 재무 추이 (연도별 매출/자산)
-- =========================================================
SELECT
  f.Fiscal_Year_c_c__c    AS fy,
  f.Revenue_c_c__c        AS revenue,
  f.Total_Assets_c_c__c   AS assets
FROM ssot__Account__dlm a
JOIN CorpFinancialStmt_Home__dlm f
  ON a.ssot__Id__c = f.Account_c_c__c
WHERE a.ssot__Name__c = ':hero'
ORDER BY f.Fiscal_Year_c_c__c DESC;

-- =========================================================
-- 데모 4: 계정 360 요약 (CRM + 재무 + 시그널 한 줄 통합)
-- =========================================================
SELECT
  a.ssot__Name__c            AS company,
  a.ssot__AnnualRevenueAmount__c AS crm_revenue,
  MAX(f.Revenue_c_c__c)      AS dart_latest_revenue,
  COUNT(DISTINCT s.Id_c__c)  AS signals
FROM ssot__Account__dlm a
LEFT JOIN CorpFinancialStmt_Home__dlm f
  ON a.ssot__Id__c = f.Account_c_c__c
LEFT JOIN ExternalSignal_Home__dlm s
  ON a.ssot__Id__c = s.Account_c_c__c
GROUP BY a.ssot__Name__c, a.ssot__AnnualRevenueAmount__c
ORDER BY signals DESC;
