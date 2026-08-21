/**
 * DART 전자공시 OpenAPI의 공시검색(list.json)에서 담당사 공시를 수집하여
 * 설비투자·차입(만기) 성격의 공시를 ExternalSignal__c 로 적재하는 서비스.
 *
 * 재무제표(DartFinancialService)와 동일하게 엔드포인트는 Named Credential
 * (callout:DART_OpenAPI)로, 인증키는 DART_Setting__mdt.Default.Crtfc_Key__c 에서
 * 읽어 crtfc_key 쿼리 파라미터로 조립한다.
 *
 * 중복 적재는 External_Key__c(corp_code + '_' + rcept_no) External ID 기준 upsert 로
 * 방지한다. 동일 공시를 재수집해도 같은 키로 갱신되어 중복 레코드가 생기지 않는다.
 */
public with sharing class DartSignalService {
    @TestVisible
    private static final String NAMED_CREDENTIAL = 'callout:DART_OpenAPI';
    // 공시검색 API. 기간 내 공시 목록(report_nm·rcept_no·rcept_dt 등)을 반환한다.
    private static final String API_PATH = '/api/list.json';
    private static final Integer TIMEOUT_MS = 120000;
    private static final Integer PAGE_COUNT = 100;
    // 공시 뷰어 URL — rcept_no 로 원문을 특정한다(Source_URL__c 자연키).
    private static final String VIEWER_URL = 'https://dart.fss.or.kr/dsaf001/main.do?rcpNo=';

    private static final String SIGNAL_TYPE_DISCLOSURE = '공시';

    // 설비투자·차입(만기) 성격을 식별하는 공시 제목 키워드.
    private static final List<String> CAPEX_KEYWORDS = new List<String>{
        '유형자산', '설비', '신규시설', '시설투자', '투자판단'
    };
    private static final List<String> DEBT_KEYWORDS = new List<String>{
        '차입', '차입금', '사채', '회사채', '전환사채', '신주인수권부사채', '교환사채'
    };

    public class DartServiceException extends Exception {}

    /**
     * 단일 회사의 기간 내 공시를 수집해 설비투자·차입 성격 공시를 ExternalSignal__c 로 적재한다.
     * External_Key__c(corp_code + '_' + rcept_no) 기준 upsert 로 중복 없이 갱신한다.
     *
     * @param corpCode DART 기업 고유번호(Account.Assigned_Company_Code__c)
     * @param beginDate 조회 시작일(YYYYMMDD)
     * @param endDate 조회 종료일(YYYYMMDD)
     * @return upsert 된 ExternalSignal__c 목록
     * @throws DartServiceException 인증키 미설정·콜아웃 실패·DART 오류코드 응답 시
     */
    public static List<ExternalSignal__c> collectSignals(
        String corpCode,
        String beginDate,
        String endDate
    ) {
        if (String.isBlank(corpCode) || String.isBlank(beginDate) || String.isBlank(endDate)) {
            throw new DartServiceException('corpCode, beginDate, endDate 는 필수입니다.');
        }

        HttpResponse response = sendRequest(corpCode, beginDate, endDate);
        Integer status = response.getStatusCode();
        if (status >= 500 || status == 429) {
            throw new DartServiceException('DART 일시적 오류(HTTP ' + status + '). 재시도 대상입니다.');
        }
        if (status != 200) {
            throw new DartServiceException('DART 호출 실패(HTTP ' + status + '): ' + response.getBody());
        }

        return parseAndInsert(response.getBody(), corpCode);
    }

    private static HttpResponse sendRequest(String corpCode, String beginDate, String endDate) {
        String crtfcKey = getCrtfcKey();
        String endpoint =
            NAMED_CREDENTIAL +
            API_PATH +
            '?crtfc_key=' + EncodingUtil.urlEncode(crtfcKey, 'UTF-8') +
            '&corp_code=' + EncodingUtil.urlEncode(corpCode, 'UTF-8') +
            '&bgn_de=' + EncodingUtil.urlEncode(beginDate, 'UTF-8') +
            '&end_de=' + EncodingUtil.urlEncode(endDate, 'UTF-8') +
            '&page_count=' + PAGE_COUNT;

        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');
        request.setTimeout(TIMEOUT_MS);

        try {
            return new Http().send(request);
        } catch (System.CalloutException e) {
            throw new DartServiceException('DART 콜아웃 예외: ' + e.getMessage(), e);
        }
    }

    @TestVisible
    private static String testCrtfcKey;

    @TestVisible
    private static String getCrtfcKey() {
        if (Test.isRunningTest()) {
            if (String.isBlank(testCrtfcKey)) {
                throw new DartServiceException('DART 인증키가 설정되지 않았습니다. DART_Setting__mdt.Default.Crtfc_Key__c 를 확인하세요.');
            }
            return testCrtfcKey;
        }
        DART_Setting__mdt setting = DART_Setting__mdt.getInstance('Default');
        if (setting == null || String.isBlank(setting.Crtfc_Key__c)) {
            throw new DartServiceException('DART 인증키가 설정되지 않았습니다. DART_Setting__mdt.Default.Crtfc_Key__c 를 확인하세요.');
        }
        return setting.Crtfc_Key__c;
    }

    private static List<ExternalSignal__c> parseAndInsert(String body, String corpCode) {
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (System.JSONException e) {
            throw new DartServiceException('DART 응답 파싱 실패: ' + e.getMessage(), e);
        }

        String status = (String) parsed.get('status');
        if (String.isBlank(status)) {
            throw new DartServiceException('DART 응답 파싱 실패.');
        }
        if (status == '013') {
            // 조회 데이터 없음 — 정상(적재할 공시 없음)
            return new List<ExternalSignal__c>();
        }
        if (status != '000') {
            throw new DartServiceException('DART 오류(' + status + '): ' + parsed.get('message'));
        }

        Id accountId = resolveAccountId(corpCode);
        Id leadId = resolveLeadId(corpCode);

        // 관심 공시만 후보로 추림. External_Key__c(corp_code + '_' + rcept_no)로
        // 후보를 dedup 하여 같은 공시가 응답에 중복돼도 한 건만 남긴다.
        Map<String, ExternalSignal__c> signalByExternalKey = new Map<String, ExternalSignal__c>();
        List<Object> rows = (List<Object>) parsed.get('list');
        if (rows != null) {
            for (Object rowObj : rows) {
                Map<String, Object> row = (Map<String, Object>) rowObj;
                String reportName = (String) row.get('report_nm');
                String receiptNo = (String) row.get('rcept_no');
                if (String.isBlank(reportName) || String.isBlank(receiptNo)) {
                    continue;
                }
                if (!isCapexOrDebt(reportName)) {
                    continue;
                }
                String externalKey = corpCode + '_' + receiptNo;
                signalByExternalKey.put(
                    externalKey,
                    buildSignal(row, accountId, leadId, reportName, externalKey, VIEWER_URL + receiptNo)
                );
            }
        }

        if (signalByExternalKey.isEmpty()) {
            return new List<ExternalSignal__c>();
        }

        // External_Key__c 기준 upsert → 이미 적재된 공시는 갱신, 신규는 insert
        List<ExternalSignal__c> toUpsert = signalByExternalKey.values();
        Database.upsert(toUpsert, ExternalSignal__c.External_Key__c, AccessLevel.USER_MODE);
        return toUpsert;
    }

    private static ExternalSignal__c buildSignal(
        Map<String, Object> row,
        Id accountId,
        Id leadId,
        String reportName,
        String externalKey,
        String sourceUrl
    ) {
        ExternalSignal__c signal = new ExternalSignal__c();
        signal.Account__c = accountId;
        signal.Lead__c = leadId;
        signal.External_Key__c = externalKey;
        signal.Signal_Type__c = SIGNAL_TYPE_DISCLOSURE;
        signal.Title__c = truncate(reportName, 255);
        signal.Summary__c = truncate(buildSummary(row), 255);
        signal.Signal_Date__c = parseDartDate((String) row.get('rcept_dt'));
        signal.Source_URL__c = sourceUrl;
        // 차입 공시는 만기 개념이 있으나 목록 API 에는 만기일/금액이 없어
        // 상세 보고서 파싱(2차)에서 채운다. 여기서는 null 로 두어 원문과 불일치를 만들지 않는다.
        signal.Amount__c = null;
        signal.Maturity_Date__c = null;
        signal.Relevance_Score__c = isDebt(reportName) ? 80 : 60;
        signal.Confidence__c = 70;
        return signal;
    }

    private static String buildSummary(Map<String, Object> row) {
        String corpName = (String) row.get('corp_name');
        String filerName = (String) row.get('flr_nm');
        List<String> parts = new List<String>();
        if (String.isNotBlank(corpName)) {
            parts.add(corpName);
        }
        if (String.isNotBlank(filerName)) {
            parts.add('제출인:' + filerName);
        }
        return String.join(parts, ' / ');
    }

    @TestVisible
    private static Boolean isCapexOrDebt(String reportName) {
        return containsAny(reportName, CAPEX_KEYWORDS) || isDebt(reportName);
    }

    @TestVisible
    private static Boolean isDebt(String reportName) {
        return containsAny(reportName, DEBT_KEYWORDS);
    }

    private static Boolean containsAny(String source, List<String> keywords) {
        if (String.isBlank(source)) {
            return false;
        }
        for (String keyword : keywords) {
            if (source.contains(keyword)) {
                return true;
            }
        }
        return false;
    }

    @TestVisible
    private static Date parseDartDate(String raw) {
        // DART 날짜는 YYYYMMDD 형식.
        if (String.isBlank(raw) || raw.length() != 8 || !raw.isNumeric()) {
            return null;
        }
        return Date.newInstance(
            Integer.valueOf(raw.substring(0, 4)),
            Integer.valueOf(raw.substring(4, 6)),
            Integer.valueOf(raw.substring(6, 8))
        );
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }

    @TestVisible
    private static Id resolveAccountId(String corpCode) {
        List<Account> accounts = [
            SELECT Id
            FROM Account
            WHERE Assigned_Company_Code__c = :corpCode
            WITH USER_MODE
            LIMIT 1
        ];
        return accounts.isEmpty() ? null : accounts[0].Id;
    }

    // corp_code(Account 와 동일 체계)가 일치하는 발굴 리드를 찾아 Lead__c 룩업을 채운다.
    // Account 매칭과 독립적이며, 매칭 리드가 없으면 null 을 반환한다(Lead__c 비움).
    @TestVisible
    private static Id resolveLeadId(String corpCode) {
        List<Lead> leads = [
            SELECT Id
            FROM Lead
            WHERE Assigned_Company_Code__c = :corpCode
            WITH USER_MODE
            LIMIT 1
        ];
        return leads.isEmpty() ? null : leads[0].Id;
    }
}