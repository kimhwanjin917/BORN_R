/**
 * DART 전자공시 OpenAPI에서 단일회사 주요 재무제표를 수집하여
 * CorporateFinancialStatement__c 로 적재하는 서비스.
 *
 * DART는 인증키를 쿼리 파라미터(crtfc_key)로 요구하므로, Named Credential 만으로는
 * 자동 주입이 불가능하다. 따라서 엔드포인트 접근은 Named Credential(callout:DART_OpenAPI)로,
 * 인증키는 DART_Setting__mdt.Default.Crtfc_Key__c 에서 읽어 URL 에 직접 조립한다.
 */
public with sharing class DartFinancialService {
    @TestVisible
    private static final String NAMED_CREDENTIAL = 'callout:DART_OpenAPI';
    // 전체 재무제표 API. 주요계정 API(fnlttSinglAcnt)와 달리 현금및현금성자산 등 세부 계정을 포함하고,
    // fs_div 파라미터로 연결/별도를 서버에서 필터링해 응답에 한 재무제표 세트만 반환한다.
    private static final String API_PATH = '/api/fnlttSinglAcntAll.json';
    private static final Integer TIMEOUT_MS = 120000;

    // DART 재무제표 계정명 → 대상 필드 매핑
    private static final String ACCT_CASH = '현금및현금성자산';
    private static final String ACCT_TOTAL_ASSETS = '자산총계';
    private static final String ACCT_TOTAL_DEBT = '부채총계';
    private static final String ACCT_REVENUE = '매출액';
    private static final String ACCT_OPERATING_INCOME = '영업이익';

    public class DartServiceException extends Exception {}

    /**
     * 단일 회사의 재무제표를 수집하여 upsert 한다.
     *
     * @param corpCode DART 기업 고유번호(corp_code, Account.Assigned_Company_Code__c)
     * @param businessYear 사업연도(예: '2023')
     * @param reportCode 보고서 코드(11011=사업보고서, 11012=반기, 11013=1분기, 11014=3분기)
     * @return upsert 된 CorporateFinancialStatement__c
     * @throws DartServiceException 인증키 미설정, 콜아웃 실패, DART 오류코드 응답 시
     */
    public static CorporateFinancialStatement__c collectFinancials(
        String corpCode,
        String businessYear,
        String reportCode
    ) {
        if (String.isBlank(corpCode) || String.isBlank(businessYear) || String.isBlank(reportCode)) {
            throw new DartServiceException('corpCode, businessYear, reportCode 는 필수입니다.');
        }

        HttpResponse response = sendRequest(corpCode, businessYear, reportCode);
        Integer status = response.getStatusCode();
        if (status >= 500 || status == 429) {
            // 일시적 오류 — 호출자가 재시도하도록 신호
            throw new DartServiceException('DART 일시적 오류(HTTP ' + status + '). 재시도 대상입니다.');
        }
        if (status != 200) {
            throw new DartServiceException('DART 호출 실패(HTTP ' + status + '): ' + response.getBody());
        }

        return parseAndUpsert(response.getBody(), corpCode, businessYear, reportCode);
    }

    private static HttpResponse sendRequest(String corpCode, String businessYear, String reportCode) {
        String crtfcKey = getCrtfcKey();
        String endpoint =
            NAMED_CREDENTIAL +
            API_PATH +
            '?crtfc_key=' + EncodingUtil.urlEncode(crtfcKey, 'UTF-8') +
            '&corp_code=' + EncodingUtil.urlEncode(corpCode, 'UTF-8') +
            '&bsns_year=' + EncodingUtil.urlEncode(businessYear, 'UTF-8') +
            '&reprt_code=' + EncodingUtil.urlEncode(reportCode, 'UTF-8') +
            '&fs_div=CFS';

        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');
        request.setTimeout(TIMEOUT_MS);

        try {
            return new Http().send(request);
        } catch (System.CalloutException e) {
            // 네트워크/타임아웃 — 재시도 대상
            throw new DartServiceException('DART 콜아웃 예외: ' + e.getMessage(), e);
        }
    }

    // 테스트에서 CMDT 레코드를 DML로 삽입할 수 없으므로 인증키를 주입할 수 있게 한다.
    @TestVisible
    private static String testCrtfcKey;

    @TestVisible
    private static String getCrtfcKey() {
        // 테스트에서는 org 의 CMDT 값(실제 키가 채워져 있을 수 있음)에 의존하지 않고
        // 주입된 testCrtfcKey 만 사용한다. 미주입 시 '키 없음' 을 결정론적으로 재현한다.
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

    private static CorporateFinancialStatement__c parseAndUpsert(
        String body,
        String corpCode,
        String businessYear,
        String reportCode
    ) {
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
        if (status != '000') {
            // 013 = 조회 데이터 없음. 그 외는 오류.
            throw new DartServiceException('DART 오류(' + status + '): ' + parsed.get('message'));
        }

        Map<String, Decimal> amountByAccount = new Map<String, Decimal>();
        List<Object> rows = (List<Object>) parsed.get('list');
        if (rows != null) {
            for (Object rowObj : rows) {
                Map<String, Object> row = (Map<String, Object>) rowObj;
                String accountName = (String) row.get('account_nm');
                if (String.isBlank(accountName)) {
                    continue;
                }
                amountByAccount.put(accountName.trim(), parseAmount((String) row.get('thstrm_amount')));
            }
        }

        CorporateFinancialStatement__c record = new CorporateFinancialStatement__c();
        record.External_Key__c = buildExternalKey(corpCode, businessYear, reportCode);
        record.Account__c = resolveAccountId(corpCode);
        record.Lead__c = resolveLeadId(corpCode);
        record.Fiscal_Year__c = Integer.valueOf(businessYear);
        record.Period_Type__c = mapPeriodType(reportCode);
        record.Cash_And_Equivalents__c = amountByAccount.get(ACCT_CASH);
        record.Total_Assets__c = amountByAccount.get(ACCT_TOTAL_ASSETS);
        record.Total_Debt__c = amountByAccount.get(ACCT_TOTAL_DEBT);
        record.Revenue__c = amountByAccount.get(ACCT_REVENUE);
        record.Operating_Income__c = amountByAccount.get(ACCT_OPERATING_INCOME);

        Decimal cash = record.Cash_And_Equivalents__c;
        Decimal totalAssets = record.Total_Assets__c;
        if (cash != null && totalAssets != null && totalAssets != 0) {
            record.Cash_Asset_Ratio__c = (cash / totalAssets * 100).setScale(2);
        }

        Database.upsert(record, CorporateFinancialStatement__c.External_Key__c, AccessLevel.USER_MODE);
        return record;
    }

    @TestVisible
    private static Decimal parseAmount(String raw) {
        if (String.isBlank(raw) || raw == '-') {
            return null;
        }
        String cleaned = raw.replace(',', '').trim();
        try {
            return Decimal.valueOf(cleaned);
        } catch (System.TypeException e) {
            return null;
        }
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

    @TestVisible
    private static String buildExternalKey(String corpCode, String businessYear, String reportCode) {
        return corpCode + '_' + businessYear + '_' + reportCode;
    }

    private static String mapPeriodType(String reportCode) {
        switch on reportCode {
            when '11011' { return '연간'; }
            when '11012' { return '반기'; }
            when '11013', '11014' { return '분기'; }
            when else { return null; }
        }
    }
}