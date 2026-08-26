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
    // 연결재무제표(CFS)를 우선 조회하고, 종속회사가 없어 연결재무제표를 작성하지 않는
    // 단일법인(DART status 013 응답)은 별도재무제표(OFS)로 폴백한다.
    private static final String FS_DIV_CONSOLIDATED = 'CFS';
    private static final String FS_DIV_SEPARATE = 'OFS';
    private static final String STATUS_NO_DATA = '013';

    // DART 재무제표 계정명(account_nm) → 대상 필드 매핑
    private static final String ACCT_CASH = '현금및현금성자산';
    private static final String ACCT_TOTAL_ASSETS = '자산총계';
    private static final String ACCT_TOTAL_DEBT = '부채총계';
    private static final String ACCT_REVENUE = '매출액';
    private static final String ACCT_OPERATING_INCOME = '영업이익';

    // 손익계산서(IS/CIS) 표준계정코드(account_id) → 대상 필드 매핑.
    // 매출은 회사마다 계정명이 '매출액'/'수익(매출액)'/'영업수익' 등으로 갈려 계정명 매칭만으로는
    // 성우하이텍·하나마이크론 같은 회사에서 누락된다. IFRS 표준계정코드로 잡으면 결정적이다.
    private static final String ID_REVENUE = 'ifrs-full_Revenue';
    private static final String ID_OPERATING_INCOME = 'dart_OperatingIncomeLoss';

    // 자산총계 표준계정코드(BS). 계정명 '자산총계' 행이 응답에 없는 회사(예: 고영 2025)에서
    // Total_Assets 가 null 이 되어 점수 산정에서 제외되는 것을 막는 폴백이다.
    private static final String ID_TOTAL_ASSETS = 'ifrs-full_Assets';

    // DART 표준계정코드(account_id) → 대상 필드 매핑.
    // 차입금·사채는 회사마다 account_nm 표기가 제각각이라, IFRS/DART 표준계정코드로 매핑해야 결정적이다.
    // 총차입금 = 단기차입금 + 유동성장기차입금 + 비유동장기차입금 + 사채 + 유동성사채.
    private static final String ID_SHORT_TERM_FINANCIAL = 'ifrs-full_ShorttermDepositsNotClassifiedAsCashEquivalents';
    private static final String ID_TOTAL_EQUITY = 'ifrs-full_Equity';
    private static final String ID_SHORT_TERM_BORROWINGS = 'ifrs-full_ShorttermBorrowings';
    private static final String ID_CURRENT_LONG_TERM_BORROWINGS = 'ifrs-full_CurrentLoansReceivedAndCurrentPortionOfNoncurrentLoansReceived';
    private static final String ID_NONCURRENT_LONG_TERM_BORROWINGS = 'ifrs-full_NoncurrentPortionOfNoncurrentLoansReceived';
    private static final String ID_CURRENT_BONDS = 'ifrs-full_CurrentBondsIssuedAndCurrentPortionOfNoncurrentBondsIssued';
    private static final String ID_NONCURRENT_BONDS = 'ifrs-full_NoncurrentPortionOfNoncurrentBondsIssued';

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

        String body = fetchBody(corpCode, businessYear, reportCode, FS_DIV_CONSOLIDATED);
        // 연결재무제표가 없어 013(데이터 없음)이면 별도재무제표로 폴백한다.
        if (isNoData(body)) {
            body = fetchBody(corpCode, businessYear, reportCode, FS_DIV_SEPARATE);
        }

        return parseAndUpsert(body, corpCode, businessYear, reportCode);
    }

    // 지정한 재무제표 구분(fs_div)으로 콜아웃하고, HTTP 상태를 검증해 응답 본문을 반환한다.
    private static String fetchBody(String corpCode, String businessYear, String reportCode, String fsDiv) {
        HttpResponse response = sendRequest(corpCode, businessYear, reportCode, fsDiv);
        Integer status = response.getStatusCode();
        if (status >= 500 || status == 429) {
            // 일시적 오류 — 호출자가 재시도하도록 신호
            throw new DartServiceException('DART 일시적 오류(HTTP ' + status + '). 재시도 대상입니다.');
        }
        if (status != 200) {
            throw new DartServiceException('DART 호출 실패(HTTP ' + status + '): ' + response.getBody());
        }
        return response.getBody();
    }

    // DART 응답이 013(조회된 데이터 없음)인지 판별한다. 파싱 실패/기타 상태는 false 로 두어
    // parseAndUpsert 의 기존 오류 처리에 위임한다.
    private static Boolean isNoData(String body) {
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
            return STATUS_NO_DATA.equals((String) parsed.get('status'));
        } catch (System.JSONException e) {
            return false;
        }
    }

    private static HttpResponse sendRequest(String corpCode, String businessYear, String reportCode, String fsDiv) {
        String crtfcKey = getCrtfcKey();
        String endpoint =
            NAMED_CREDENTIAL +
            API_PATH +
            '?crtfc_key=' + EncodingUtil.urlEncode(crtfcKey, 'UTF-8') +
            '&corp_code=' + EncodingUtil.urlEncode(corpCode, 'UTF-8') +
            '&bsns_year=' + EncodingUtil.urlEncode(businessYear, 'UTF-8') +
            '&reprt_code=' + EncodingUtil.urlEncode(reportCode, 'UTF-8') +
            '&fs_div=' + fsDiv;

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
        // 표준계정코드(account_id)는 재무상태표(BS)에서만 수집한다. 자본총계 등 동일 코드가
        // 자본변동표(SCE)에 중복 등장해 값이 덮이는 것을 막는다.
        Map<String, Decimal> amountByStdCodeBS = new Map<String, Decimal>();
        // 손익계산서(IS/CIS) 표준계정코드 맵. 매출·영업이익을 계정명 편차와 무관하게 결정적으로 잡는다.
        Map<String, Decimal> amountByStdCodeIS = new Map<String, Decimal>();
        // BS 계정명 목록(폴백용). 표준계정코드를 쓰지 않는 회사의 차입금·사채를 계정명으로 잡는다.
        List<BsAccount> bsAccounts = new List<BsAccount>();
        List<Object> rows = (List<Object>) parsed.get('list');
        if (rows != null) {
            for (Object rowObj : rows) {
                Map<String, Object> row = (Map<String, Object>) rowObj;
                Decimal amount = parseAmount((String) row.get('thstrm_amount'));
                String accountName = (String) row.get('account_nm');
                if (String.isNotBlank(accountName)) {
                    amountByAccount.put(accountName.trim(), amount);
                }
                String sjDiv = (String) row.get('sj_div');
                Boolean isBS = 'BS'.equals(sjDiv);
                Boolean isIS = 'IS'.equals(sjDiv) || 'CIS'.equals(sjDiv);
                String stdCode = (String) row.get('account_id');
                if (String.isNotBlank(stdCode) && isBS) {
                    amountByStdCodeBS.put(stdCode.trim(), amount);
                }
                // 손익계산서 표준코드는 첫 등장값만 취한다(IS·CIS 양쪽에 중복 등장 시 덮임 방지).
                if (String.isNotBlank(stdCode) && isIS && !amountByStdCodeIS.containsKey(stdCode.trim())) {
                    amountByStdCodeIS.put(stdCode.trim(), amount);
                }
                if (isBS && String.isNotBlank(accountName) && amount != null) {
                    bsAccounts.add(new BsAccount(accountName.trim(), amount));
                }
            }
        }

        CorporateFinancialStatement__c record = new CorporateFinancialStatement__c();
        // DART 재무수치는 전부 원(KRW) 단위다. 조직 기준통화도 KRW지만, 멀티커런시에서
        // 신규 레코드는 실행 유저의 기본통화를 기본값으로 쓰므로 여기서 KRW를 명시 고정한다.
        // (명시하지 않으면 배치를 돌린 유저 설정에 따라 USD 등으로 잘못 적재된다.)
        record.CurrencyIsoCode = 'KRW';
        record.External_Key__c = buildExternalKey(corpCode, businessYear, reportCode);
        record.Account__c = resolveAccountId(corpCode);
        record.Lead__c = resolveLeadId(corpCode);
        record.Fiscal_Year__c = Integer.valueOf(businessYear);
        record.Period_Type__c = mapPeriodType(reportCode);
        record.Cash_And_Equivalents__c = amountByAccount.get(ACCT_CASH);
        // 자산총계는 계정명 우선, 없으면 BS 표준계정코드로 폴백한다(회사별 계정명 편차 흡수).
        record.Total_Assets__c = firstNonNull(
            amountByAccount.get(ACCT_TOTAL_ASSETS), amountByStdCodeBS.get(ID_TOTAL_ASSETS)
        );
        record.Total_Debt__c = amountByAccount.get(ACCT_TOTAL_DEBT);
        // 매출·영업이익은 표준계정코드 우선, 없으면 계정명으로 폴백한다.
        // (회사별 계정명 편차 '매출액'/'수익(매출액)', '영업이익'/'영업이익(손실)' 흡수)
        record.Revenue__c = firstNonNull(amountByStdCodeIS.get(ID_REVENUE), amountByAccount.get(ACCT_REVENUE));
        record.Operating_Income__c = firstNonNull(
            amountByStdCodeIS.get(ID_OPERATING_INCOME), amountByAccount.get(ACCT_OPERATING_INCOME)
        );

        // 4분기(사업보고서, 11011)의 매출·영업이익은 DART가 '연간 누적(1~12월)'으로 준다.
        // 당분기(10~12월 3개월) = 연간 - (1분기 + 2분기 + 3분기). 같은 회사·연도의 세 분기가
        // org 에 모두 수집돼 있으면 여기서 차감해 '당분기'로 적재한다(연간 총합을 그대로 쓰지 않는다).
        if ('11011'.equals(reportCode)) {
            applyQ4Standalone(record, corpCode, businessYear);
        }

        // 표준계정코드 기반 신규 필드. 단기차입금 = 순수 단기차입금 + 유동성장기차입금,
        // 사채 = 유동성사채 + 비유동사채. 세 차입금 필드의 합이 총차입금이 된다.
        record.Short_Term_Financial_Instruments__c = amountByStdCodeBS.get(ID_SHORT_TERM_FINANCIAL);
        record.Total_Equity__c = amountByStdCodeBS.get(ID_TOTAL_EQUITY);
        record.Short_Term_Borrowings__c = sumStdCodes(amountByStdCodeBS, new List<String>{
            ID_SHORT_TERM_BORROWINGS, ID_CURRENT_LONG_TERM_BORROWINGS
        });
        record.Long_Term_Borrowings__c = sumStdCodes(amountByStdCodeBS, new List<String>{
            ID_NONCURRENT_LONG_TERM_BORROWINGS
        });
        record.Bonds_Payable__c = sumStdCodes(amountByStdCodeBS, new List<String>{
            ID_CURRENT_BONDS, ID_NONCURRENT_BONDS
        });

        // 차입금 표준계정코드를 하나도 안 쓰는 회사(예: 성우하이텍은 리스부채 포함 합산 계정으로만 공시)는
        // 차입금이 전부 null 이 된다. 이 경우에만 계정명 기반으로 폴백 집계한다.
        // (표준코드가 하나라도 있으면 폴백하지 않아 정상 회사의 값이 오염되지 않는다.)
        if (record.Short_Term_Borrowings__c == null
            && record.Long_Term_Borrowings__c == null
            && record.Bonds_Payable__c == null) {
            applyBorrowingNameFallback(record, bsAccounts);
        }

        Decimal cash = record.Cash_And_Equivalents__c;
        Decimal totalAssets = record.Total_Assets__c;
        if (cash != null && totalAssets != null && totalAssets != 0) {
            record.Cash_Asset_Ratio__c = (cash / totalAssets * 100).setScale(2);
        }

        Database.upsert(record, CorporateFinancialStatement__c.External_Key__c, AccessLevel.USER_MODE);
        return record;
    }

    // 폴백용 BS 계정명·금액 쌍.
    @TestVisible
    private class BsAccount {
        String name;
        Decimal amount;
        BsAccount(String name, Decimal amount) {
            this.name = name;
            this.amount = amount;
        }
    }

    // 표준계정코드를 쓰지 않는 회사의 차입금·사채를 계정명으로 집계해 record 에 채운다.
    // 계정명에 '차입'/'사채'가 포함된 BS 항목만 보되, '차입금및사채'처럼 둘을 합친 상위 합계
    // 계정은 이중계상을 막기 위해 제외한다. 비유동으로 시작하면 장기, 그 외 차입은 단기로 본다.
    // 이 경로의 차입금은 리스부채가 포함될 수 있어 금액이 과대될 수 있다(분류 정확성 우선).
    @TestVisible
    private static void applyBorrowingNameFallback(
        CorporateFinancialStatement__c record,
        List<BsAccount> bsAccounts
    ) {
        Decimal shortTerm = null;
        Decimal longTerm = null;
        Decimal bonds = null;
        for (BsAccount acct : bsAccounts) {
            String name = acct.name;
            Boolean hasBorrowing = name.contains('차입');
            Boolean hasBond = name.contains('사채');
            if (!hasBorrowing && !hasBond) {
                continue;
            }
            // 차입금과 사채를 함께 묶은 합계성 계정은 개별 계정과 중복되므로 건너뛴다.
            if (hasBorrowing && hasBond) {
                continue;
            }
            if (hasBond) {
                bonds = (bonds == null ? acct.amount : bonds + acct.amount);
            } else if (name.startsWith('비유동')) {
                longTerm = (longTerm == null ? acct.amount : longTerm + acct.amount);
            } else {
                shortTerm = (shortTerm == null ? acct.amount : shortTerm + acct.amount);
            }
        }
        record.Short_Term_Borrowings__c = shortTerm;
        record.Long_Term_Borrowings__c = longTerm;
        record.Bonds_Payable__c = bonds;
    }

    // 주어진 표준계정코드들의 금액을 합산한다. 하나도 존재하지 않으면 null(미공시)을 반환해
    // 값이 0인 회사(예: 사채 0)와 항목 자체가 없는 회사(무차입)를 구분한다.
    @TestVisible
    private static Decimal sumStdCodes(Map<String, Decimal> amountByStdCode, List<String> codes) {
        Decimal total = null;
        for (String code : codes) {
            Decimal amount = amountByStdCode.get(code);
            if (amount != null) {
                total = (total == null ? amount : total + amount);
            }
        }
        return total;
    }

    // 표준계정코드 값(우선)과 계정명 값(폴백) 중 먼저 null 이 아닌 값을 반환한다.
    @TestVisible
    private static Decimal firstNonNull(Decimal preferred, Decimal fallback) {
        return preferred != null ? preferred : fallback;
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

    // 4분기(사업보고서) 매출·영업이익을 '연간 누적'에서 '당분기 3개월'로 보정한다.
    // 당분기 = 연간 - (1분기 + 2분기 + 3분기). 세 분기 레코드가 org 에 모두 있어야 계산하고,
    // 하나라도 없으면 연간값을 유지한다(세 분기 확보 후 재수집 시 보정됨).
    @TestVisible
    private static void applyQ4Standalone(
        CorporateFinancialStatement__c annual,
        String corpCode,
        String businessYear
    ) {
        String q1Key = corpCode + '_' + businessYear + '_11013';
        String q2Key = corpCode + '_' + businessYear + '_11012';
        String q3Key = corpCode + '_' + businessYear + '_11014';
        Map<String, CorporateFinancialStatement__c> byKey = new Map<String, CorporateFinancialStatement__c>();
        for (CorporateFinancialStatement__c c : [
            SELECT External_Key__c, Revenue__c, Operating_Income__c
            FROM CorporateFinancialStatement__c
            WHERE External_Key__c IN :new Set<String>{ q1Key, q2Key, q3Key }
            WITH USER_MODE
        ]) {
            byKey.put(c.External_Key__c, c);
        }
        CorporateFinancialStatement__c q1 = byKey.get(q1Key);
        CorporateFinancialStatement__c q2 = byKey.get(q2Key);
        CorporateFinancialStatement__c q3 = byKey.get(q3Key);
        if (q1 == null || q2 == null || q3 == null) {
            return;
        }
        annual.Revenue__c = subtractIfCumulative(
            annual.Revenue__c, q1.Revenue__c, q2.Revenue__c, q3.Revenue__c
        );
        annual.Operating_Income__c = subtractIfCumulative(
            annual.Operating_Income__c, q1.Operating_Income__c, q2.Operating_Income__c, q3.Operating_Income__c
        );
    }

    // annual 이 세 분기 합보다 클 때(=아직 연간 누적)만 (annual - 합)을 반환한다.
    // 이미 당분기(합 이하)거나 값이 하나라도 null 이면 원값을 유지해, 재수집·재실행에도 안전하다(멱등).
    @TestVisible
    private static Decimal subtractIfCumulative(Decimal annual, Decimal q1, Decimal q2, Decimal q3) {
        if (annual == null || q1 == null || q2 == null || q3 == null) {
            return annual;
        }
        Decimal sum3 = q1 + q2 + q3;
        return annual > sum3 ? annual - sum3 : annual;
    }

    // DART 보고서코드 → 분기 구분. 반기(11012)=2분기, 사업보고서(11011)=4분기.
    // 4분기 매출·영업이익은 applyQ4Standalone 에서 당분기(3개월)로 보정한다.
    private static String mapPeriodType(String reportCode) {
        switch on reportCode {
            when '11013' { return '1분기'; }
            when '11012' { return '2분기'; }
            when '11014' { return '3분기'; }
            when '11011' { return '4분기'; }
            when else { return null; }
        }
    }
}