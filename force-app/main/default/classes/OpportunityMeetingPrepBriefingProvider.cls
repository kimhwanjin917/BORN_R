/**
 * Opportunity_Meeting_Prep_Briefing 템플릿의 grounding provider.
 * Lead 전환 후 재무·시그널이 Account에 연결되므로 Opportunity와 Account를 기준으로
 * Lead 브리핑과 같은 재무 추이·외부 시그널·CRM 컨텍스트를 구성한다.
 */
public with sharing class OpportunityMeetingPrepBriefingProvider {

    @TestVisible private static final String ANNUAL_PERIOD = '4분기';
    @TestVisible private static final Integer MAX_ANNUAL_YEARS = 3;
    @TestVisible private static final Integer MAX_SIGNALS = 5;
    @TestVisible private static final String NO_OPPORTUNITY_MESSAGE =
        '(영업기회 정보가 전달되지 않았습니다. 제공된 정보 외의 근거를 만들지 마세요.)';
    @TestVisible private static final String NO_DATA_MESSAGE =
        '(이 영업기회에 연결된 재무제표·외부 시그널 데이터가 없습니다. 제공되지 않은 수치를 지어내지 마세요.)';
    @TestVisible private static final String NO_ACCESS_MESSAGE =
        '(근거 데이터 조회 권한이 없어 재무·시그널 상세를 제공할 수 없습니다. 수치를 임의로 만들지 마세요.)';

    @InvocableMethod(
        label='영업기회 미팅 준비 브리핑: 재무추이·시그널·CRM grounding'
        description='영업기회와 Account에 연결된 재무제표 추이·외부 시그널·CRM 프로필을 브리핑 템플릿에 주입합니다.'
    )
    public static List<Response> getBriefingContext(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            Response response = new Response();
            response.Prompt = buildContextText(request == null ? null : request.RelatedOpportunity);
            responses.add(response);
        }
        return responses;
    }

    @TestVisible
    private static String buildContextText(String relatedOpportunityId) {
        if (String.isBlank(relatedOpportunityId)) {
            return NO_OPPORTUNITY_MESSAGE;
        }
        try {
            Id opportunityId = (Id) relatedOpportunityId;
            if (opportunityId.getSObjectType() != Opportunity.SObjectType) {
                return NO_OPPORTUNITY_MESSAGE;
            }
            Opportunity opportunity = [
                SELECT Id, Name, AccountId, Account.Name, Account.Industry, Owner.Name,
                       StageName, CloseDate, Primary_Product__c, Primary_Product__r.Name,
                       Product_Family__c, Last_Meeting_Date__c, Meeting_Log__c
                FROM Opportunity
                WHERE Id = :opportunityId
                WITH USER_MODE
                LIMIT 1
            ];
            List<String> blocks = new List<String>();
            blocks.add(buildCrmBlock(opportunity));
            if (opportunity.AccountId == null) {
                blocks.add(NO_DATA_MESSAGE);
                return String.join(blocks, '\n\n');
            }
            String financial = buildFinancialTrendBlock(opportunity.AccountId);
            String latest = buildLatestQuarterBlock(opportunity.AccountId);
            String signals = buildSignalBlock(opportunity.AccountId);
            String won = buildSimilarWonBlock(opportunity);
            if (financial == null && signals == null) {
                blocks.add(NO_DATA_MESSAGE);
            } else {
                if (financial != null) blocks.add(financial);
                if (latest != null) blocks.add(latest);
                if (signals != null) blocks.add(signals);
                if (won != null) blocks.add(won);
            }
            return String.join(blocks, '\n\n');
        } catch (QueryException e) {
            return NO_ACCESS_MESSAGE;
        }
    }

    private static String buildCrmBlock(Opportunity opportunity) {
        List<String> lines = new List<String>{ '[CRM 프로필 - 영업기회]' };
        lines.add('- 기회명: ' + textOrUnknown(opportunity.Name));
        lines.add('- 고객사: ' + (opportunity.Account == null
            ? '정보 없음' : textOrUnknown(opportunity.Account.Name)));
        lines.add('- 업종: ' + (opportunity.Account == null
            ? '정보 없음' : textOrUnknown(opportunity.Account.Industry)));
        lines.add('- 영업단계: ' + textOrUnknown(opportunity.StageName));
        lines.add('- 예상 종료일: ' + (opportunity.CloseDate == null
            ? '정보 없음' : String.valueOf(opportunity.CloseDate)));
        lines.add('- 담당 RM: ' + (opportunity.Owner == null
            ? '정보 없음' : textOrUnknown(opportunity.Owner.Name)));
        lines.add('- 기준 상품: ' + (opportunity.Primary_Product__r == null
            ? '미정' : opportunity.Primary_Product__r.Name));
        lines.add('- 상품군: ' + textOrUnknown(opportunity.Product_Family__c));
        lines.add('- 최근 미팅일: ' + (opportunity.Last_Meeting_Date__c == null
            ? '정보 없음' : String.valueOf(opportunity.Last_Meeting_Date__c)));
        lines.add('- 미팅 로그: ' + textOrUnknown(opportunity.Meeting_Log__c));
        return String.join(lines, '\n');
    }

    private static String buildFinancialTrendBlock(Id accountId) {
        Set<Id> leadIds = convertedLeadIdsForAccount(accountId);
        List<CorporateFinancialStatement__c> statements = [
            SELECT Fiscal_Year__c, Total_Assets__c, Total_Equity__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                   Short_Term_Borrowings__c, Long_Term_Borrowings__c,
                   Bonds_Payable__c, Revenue__c, Operating_Income__c
            FROM CorporateFinancialStatement__c
            WHERE (Account__c = :accountId OR Lead__c IN :leadIds)
                  AND Period_Type__c = :ANNUAL_PERIOD
            WITH USER_MODE
            ORDER BY Fiscal_Year__c DESC NULLS LAST
            LIMIT :MAX_ANNUAL_YEARS
        ];
        if (statements.isEmpty()) return null;
        List<String> lines = new List<String>{ '[재무제표 추이 - 최근 연간, 최신 연도부터]' };
        for (CorporateFinancialStatement__c cfs : statements) {
            String year = cfs.Fiscal_Year__c == null ? '연도 미상' : cfs.Fiscal_Year__c.intValue() + '년';
            lines.add('- ' + year
                + ': 자산총계 ' + formatWon(cfs.Total_Assets__c)
                + ', 자본총계 ' + formatWon(cfs.Total_Equity__c)
                + ', 현금및현금성자산 ' + formatWon(cfs.Cash_And_Equivalents__c)
                + ', 단기금융상품 ' + formatWon(cfs.Short_Term_Financial_Instruments__c)
                + ', 매출액 ' + formatWon(cfs.Revenue__c)
                + ', 영업이익 ' + formatWon(cfs.Operating_Income__c)
                + ', 단기차입금 ' + formatWon(cfs.Short_Term_Borrowings__c)
                + ', 장기차입금 ' + formatWon(cfs.Long_Term_Borrowings__c)
                + ', 사채 ' + formatWon(cfs.Bonds_Payable__c));
        }
        return String.join(lines, '\n');
    }

    private static String buildLatestQuarterBlock(Id accountId) {
        Set<Id> leadIds = convertedLeadIdsForAccount(accountId);
        List<CorporateFinancialStatement__c> rows = [
            SELECT Fiscal_Year__c, Period_Type__c, Disclosure_Period_YM__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                   Short_Term_Borrowings__c, Bonds_Payable__c, Revenue__c
            FROM CorporateFinancialStatement__c
            WHERE (Account__c = :accountId OR Lead__c IN :leadIds)
                  AND Period_Type__c != :ANNUAL_PERIOD
            WITH USER_MODE
            ORDER BY Fiscal_Year__c DESC NULLS LAST, Disclosure_Period_YM__c DESC NULLS LAST
            LIMIT 1
        ];
        if (rows.isEmpty()) return null;
        CorporateFinancialStatement__c cfs = rows[0];
        return '[최신 분기 재무]\n- 공시기준 ' + textOrUnknown(cfs.Disclosure_Period_YM__c)
            + ' (' + textOrUnknown(cfs.Period_Type__c) + ')'
            + ': 현금및현금성자산 ' + formatWon(cfs.Cash_And_Equivalents__c)
            + ', 단기금융상품 ' + formatWon(cfs.Short_Term_Financial_Instruments__c)
            + ', 단기차입금 ' + formatWon(cfs.Short_Term_Borrowings__c)
            + ', 사채 ' + formatWon(cfs.Bonds_Payable__c)
            + ', 매출 ' + formatWon(cfs.Revenue__c);
    }

    private static String buildSignalBlock(Id accountId) {
        Set<Id> leadIds = convertedLeadIdsForAccount(accountId);
        List<ExternalSignal__c> signals = [
            SELECT Signal_Type__c, Signal_Date__c, Title__c, Summary__c
            FROM ExternalSignal__c
            WHERE Account__c = :accountId OR Lead__c IN :leadIds
            WITH USER_MODE
            ORDER BY Signal_Date__c DESC NULLS LAST
            LIMIT :MAX_SIGNALS
        ];
        if (signals.isEmpty()) return null;
        List<String> lines = new List<String>{ '[최근 외부 시그널]' };
        for (ExternalSignal__c signal : signals) {
            String dateText = signal.Signal_Date__c == null ? '일자 미상' : String.valueOf(signal.Signal_Date__c);
            String typeText = String.isBlank(signal.Signal_Type__c) ? '기타' : signal.Signal_Type__c;
            String titleText = String.isBlank(signal.Title__c) ? '(제목 없음)' : signal.Title__c;
            lines.add('- ' + dateText + ' [' + typeText + '] ' + titleText
                + (String.isBlank(signal.Summary__c) ? '' : ': ' + signal.Summary__c));
        }
        return String.join(lines, '\n');
    }

    private static String buildSimilarWonBlock(Opportunity opportunity) {
        if (opportunity.Account == null || String.isBlank(opportunity.Account.Industry)) return null;
        SimilarWonAnalysisAction.Request req = new SimilarWonAnalysisAction.Request();
        req.industry = opportunity.Account.Industry;
        if (String.isNotBlank(opportunity.Product_Family__c)) {
            req.productType = opportunity.Product_Family__c;
        }
        try {
            List<SimilarWonAnalysisAction.Result> results = SimilarWonAnalysisAction.analyze(
                new List<SimilarWonAnalysisAction.Request>{ req });
            if (results == null || results.isEmpty()) return null;
            SimilarWonAnalysisAction.Result r = results[0];
            if (r.insufficientData == true || r.totalCount == null || r.totalCount == 0) {
                return '[유사 Won 집계]\n- 조건에 맞는 종결 기회가 없어 확률을 추정하지 말 것.';
            }
            return '[유사 Won 집계]\n- 종결 ' + r.totalCount + '건 중 Won ' + r.wonCount
                + '건 · Won 비율 ' + r.wonRate + '%';
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * 이 Account 로 전환된 Lead 의 Id 집합. 재무·시그널이 전환 시 Account 로 재연결되지
     * 못하고 Lead 에만 남은 경우(과거 표준 Convert 경로 등)를 위한 폴백 조회용이다.
     */
    private static Set<Id> convertedLeadIdsForAccount(Id accountId) {
        Set<Id> leadIds = new Set<Id>();
        if (accountId == null) {
            return leadIds;
        }
        for (Lead lead : [
            SELECT Id FROM Lead WHERE ConvertedAccountId = :accountId WITH USER_MODE
        ]) {
            leadIds.add(lead.Id);
        }
        return leadIds;
    }

    private static String textOrUnknown(String value) {
        return String.isBlank(value) ? '정보 없음' : value;
    }

    private static String formatWon(Decimal amount) {
        if (amount == null) return '정보 없음';
        Decimal inEok = (amount / 100000000L).setScale(1);
        return inEok.toPlainString().replaceAll('\\.0$', '') + '억 원';
    }

    public class Request {
        @InvocableVariable(required=true label='RelatedOpportunity' description='프롬프트 템플릿의 Opportunity Id 입력')
        public String RelatedOpportunity;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 브리핑 근거 텍스트')
        public String Prompt;
    }
}