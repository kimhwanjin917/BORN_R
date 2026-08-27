/**
 * docs/51 — 후속 추천(D구간) 재료 조회. 미팅 없이 Closed Won Opportunity 에서 시작하므로
 * 과거 미팅 메모 정제본(최근 3건)·기준 상품·보유상품 만기·DART 재무(최근 2기)·외부시그널(최근 5건)을
 * 실행 사용자 권한으로 모아 에이전트가 업셀(RP 확대)·크로스셀(회사채)을 판단할 재료로 돌려준다.
 * 적합 판단은 하지 않는다. 원문 메모(Raw_Content__c)는 읽지 않는다.
 */
public with sharing class OpportunityFollowupContextAction {

    @TestVisible private static final Integer MAX_NOTES = 3;
    @TestVisible private static final Integer MAX_FINANCIALS = 2;
    @TestVisible private static final Integer MAX_SIGNALS = 5;
    @TestVisible private static final Integer MATURITY_WINDOW_DAYS = 90;

    public class Request {
        @InvocableVariable(label='Opportunity Id' description='후속 추천을 만들 (종결된) 기회 Id' required=true)
        public Id opportunityId;
    }

    public class Response {
        @InvocableVariable(label='접근 가능') public Boolean isAccessible;
        @InvocableVariable(label='기회명') public String opportunityName;
        @InvocableVariable(label='고객사명') public String accountName;
        @InvocableVariable(label='산업군') public String accountIndustry;
        @InvocableVariable(label='기준 상품' description='Opportunity.Primary_Product__r.Name') public String primaryProductName;
        @InvocableVariable(label='기준 상품군' description='Opportunity.Product_Family__c') public String primaryProductFamily;
        @InvocableVariable(label='최근 에이전트 추천' description='마지막 미팅 중 추천 결과') public String lastRecommendation;
        @InvocableVariable(label='과거 미팅 메모 요약 텍스트' description='정제본 최근 3건, 최신 순') public String pastNotesText;
        @InvocableVariable(label='보유상품 요약 텍스트' description='Asset: 상품·원금·금리·만기, 만기 임박 표시') public String heldAssetText;
        @InvocableVariable(label='만기 임박 여부' description='90일 내 만기 또는 만기 경과 보유상품 존재') public Boolean hasMaturingAsset;
        @InvocableVariable(label='DART 재무 요약 텍스트' description='최근 2기') public String financialText;
        @InvocableVariable(label='외부시그널 요약 텍스트' description='최근 5건') public String signalText;
        @InvocableVariable(label='메시지') public String message;
    }

    @InvocableMethod(
        label='후속 추천 재료 조회 (기회)'
        description='종결된 기회의 과거 미팅 메모 정제본·기준 상품·보유상품 만기·DART 재무·외부시그널을 실행 사용자 권한으로 모아 돌려줍니다. 적합 판단은 하지 않습니다.'
        category='근본증권 RM')
    public static List<Response> gather(List<Request> requests) {
        List<Response> out = new List<Response>();
        if (requests == null) {
            return out;
        }
        for (Request req : requests) {
            out.add(gatherOne(req == null ? null : req.opportunityId));
        }
        return out;
    }

    private static Response gatherOne(Id oppId) {
        Response res = new Response();
        res.isAccessible = false;
        res.hasMaturingAsset = false;
        if (oppId == null) {
            res.message = '기회 Id 가 비어 있습니다.';
            return res;
        }
        List<Opportunity> opps;
        try {
            opps = [
                SELECT Id, Name, AccountId, Account.Name, Account.Industry,
                       Primary_Product__r.Name, Product_Family__c, Last_Recommendation__c
                FROM Opportunity WHERE Id = :oppId WITH USER_MODE LIMIT 1
            ];
        } catch (QueryException e) {
            res.message = '기회를 조회할 권한이 없습니다. (' + e.getMessage() + ')';
            return res;
        }
        if (opps.isEmpty()) {
            res.message = '기회를 찾지 못했거나 접근 권한이 없습니다.';
            return res;
        }
        Opportunity opp = opps[0];
        res.isAccessible = true;
        res.opportunityName = opp.Name;
        res.accountName = opp.Account == null ? null : opp.Account.Name;
        res.accountIndustry = opp.Account == null ? null : opp.Account.Industry;
        res.primaryProductName = opp.Primary_Product__r == null ? null : opp.Primary_Product__r.Name;
        res.primaryProductFamily = opp.Product_Family__c;
        res.lastRecommendation = opp.Last_Recommendation__c;
        res.pastNotesText = describeNotes(opp.Id);
        res.heldAssetText = describeAssets(opp.AccountId, res);
        res.financialText = describeFinancials(opp.AccountId);
        res.signalText = describeSignals(opp.AccountId);
        res.message = opp.Name + ' — 기준 상품 ' + (res.primaryProductName == null ? '미설정' : res.primaryProductName)
            + ', 만기 임박 ' + (res.hasMaturingAsset ? '있음' : '없음');
        return res;
    }

    private static String describeNotes(Id oppId) {
        List<String> lines = new List<String>();
        try {
            for (Meeting_Note__c n : [
                SELECT CreatedDate, Sanitized_Content__c FROM Meeting_Note__c
                WHERE Opportunity__c = :oppId
                WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 20
            ]) {
                if (String.isBlank(n.Sanitized_Content__c) || lines.size() >= MAX_NOTES) {
                    continue; // Long Text 는 WHERE 로 거를 수 없어 코드에서 거른다
                }
                lines.add('- ' + n.CreatedDate.date().format() + ': ' + n.Sanitized_Content__c.abbreviate(600));
            }
        } catch (QueryException e) {
            return '미팅 메모 조회 권한 없음';
        }
        return lines.isEmpty() ? '과거 미팅 메모 없음' : String.join(lines, '\n');
    }

    private static String describeAssets(Id accountId, Response res) {
        if (accountId == null) {
            return '고객사 없음';
        }
        List<String> lines = new List<String>();
        Date today = Date.today();
        try {
            for (Asset a : [
                SELECT Name, Product2.Name, Product2.Family, Status, Price, Principal_Amount__c, Interest_Rate__c, UsageEndDate
                FROM Asset WHERE AccountId = :accountId WITH USER_MODE ORDER BY UsageEndDate ASC NULLS LAST LIMIT 50
            ]) {
                List<String> parts = new List<String>();
                parts.add(a.Product2 == null ? a.Name : a.Product2.Name + (a.Product2.Family == null ? '' : '(' + a.Product2.Family + ')'));
                Decimal principal = a.Principal_Amount__c != null ? a.Principal_Amount__c : a.Price;
                if (principal != null) { parts.add('원금 ' + principal.setScale(0).format()); }
                if (a.Interest_Rate__c != null) { parts.add('금리 ' + a.Interest_Rate__c + '%'); }
                if (a.UsageEndDate != null) {
                    Integer days = today.daysBetween(a.UsageEndDate);
                    parts.add('만기 ' + a.UsageEndDate.format() + ' (D' + (days >= 0 ? '-' + days : '+' + (-days)) + ')');
                    if (days <= MATURITY_WINDOW_DAYS) {
                        res.hasMaturingAsset = true;
                        parts.add('※ 만기 임박');
                    }
                }
                lines.add('- ' + String.join(parts, ', '));
            }
        } catch (QueryException e) {
            return '보유상품 조회 권한 없음';
        }
        return lines.isEmpty() ? '보유상품 없음' : String.join(lines, '\n');
    }

    private static String describeFinancials(Id accountId) {
        if (accountId == null) {
            return 'DART 재무 없음';
        }
        List<String> lines = new List<String>();
        try {
            for (CorporateFinancialStatement__c f : [
                SELECT Fiscal_Year__c, Period_Type__c, Revenue__c, Operating_Income__c, Total_Debt__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c, Bonds_Payable__c, Cash_Asset_Ratio__c
                FROM CorporateFinancialStatement__c WHERE Account__c = :accountId
                WITH USER_MODE ORDER BY Fiscal_Year__c DESC NULLS LAST, CreatedDate DESC LIMIT :MAX_FINANCIALS
            ]) {
                List<String> parts = new List<String>();
                parts.add(String.valueOf(f.Fiscal_Year__c == null ? '' : String.valueOf(f.Fiscal_Year__c.intValue())) + (String.isBlank(f.Period_Type__c) ? '' : ' ' + f.Period_Type__c));
                if (f.Revenue__c != null) { parts.add('매출 ' + f.Revenue__c.setScale(0).format()); }
                if (f.Operating_Income__c != null) { parts.add('영업이익 ' + f.Operating_Income__c.setScale(0).format()); }
                if (f.Cash_And_Equivalents__c != null) { parts.add('현금성자산 ' + f.Cash_And_Equivalents__c.setScale(0).format()); }
                if (f.Short_Term_Financial_Instruments__c != null) { parts.add('단기금융상품 ' + f.Short_Term_Financial_Instruments__c.setScale(0).format()); }
                if (f.Total_Debt__c != null) { parts.add('총부채 ' + f.Total_Debt__c.setScale(0).format()); }
                if (f.Bonds_Payable__c != null) { parts.add('사채 ' + f.Bonds_Payable__c.setScale(0).format()); }
                if (f.Cash_Asset_Ratio__c != null) { parts.add('현금자산비율 ' + f.Cash_Asset_Ratio__c + '%'); }
                lines.add('- ' + String.join(parts, ', '));
            }
        } catch (QueryException e) {
            return 'DART 재무 조회 권한 없음';
        }
        return lines.isEmpty() ? 'DART 재무 없음' : String.join(lines, '\n');
    }

    private static String describeSignals(Id accountId) {
        if (accountId == null) {
            return '외부시그널 없음';
        }
        List<String> lines = new List<String>();
        try {
            for (ExternalSignal__c s : [
                SELECT Signal_Type__c, Title__c, Summary__c, Signal_Date__c, Amount__c, Maturity_Date__c
                FROM ExternalSignal__c WHERE Account__c = :accountId
                WITH USER_MODE ORDER BY Signal_Date__c DESC NULLS LAST LIMIT :MAX_SIGNALS
            ]) {
                List<String> parts = new List<String>();
                if (s.Signal_Date__c != null) { parts.add(s.Signal_Date__c.format()); }
                if (!String.isBlank(s.Signal_Type__c)) { parts.add('[' + s.Signal_Type__c + ']'); }
                if (!String.isBlank(s.Title__c)) { parts.add(s.Title__c); }
                if (!String.isBlank(s.Summary__c)) { parts.add(s.Summary__c); }
                if (s.Amount__c != null) { parts.add('금액 ' + s.Amount__c.setScale(0).format()); }
                if (s.Maturity_Date__c != null) { parts.add('만기 ' + s.Maturity_Date__c.format()); }
                lines.add('- ' + String.join(parts, ' '));
            }
        } catch (QueryException e) {
            return '외부시그널 조회 권한 없음';
        }
        return lines.isEmpty() ? '외부시그널 없음' : String.join(lines, '\n');
    }
}