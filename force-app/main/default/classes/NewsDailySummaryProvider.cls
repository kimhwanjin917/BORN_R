/**
 * 프롬프트 템플릿 "News_Daily_Summary"(Flex) 의 grounding 용 Apex.
 *
 * Prompt Builder 에서 리소스로 추가하면 템플릿 본문의 {!$Apex:NewsDailySummaryProvider.Prompt} 자리에
 * 주인공·Top3 담당 기업의 최근 뉴스 시그널과 담당 산업군 뉴스가 텍스트로 주입된다.
 * 이 텍스트가 홈 대시보드 "뉴스 요약" 칸의 일일 요약을 LLM 이 생성하는 근거가 된다.
 *
 * AI 이원화 원칙(LeadPriorityRationaleProvider 와 동일): 이 클래스는 뉴스를 새로 만들지 않는다.
 * 뉴스 시그널은 사전 적재된 ExternalSignal__c(Signal_Type__c='뉴스') 를 그대로 읽어 근거로 제공하고,
 * 요약문 생성은 프롬프트 템플릿(LLM)이 맡는다.
 *
 * 조회 대상:
 *   - 기업 뉴스: Priority_Score__c 상위 3개 담당 Account 에 연결된 최근 뉴스 시그널.
 *   - 산업군 뉴스: 특정 회사 룩업 없이 Industry__c 로 분류된 뉴스 시그널.
 *
 * RPProposalCatalogProvider / LeadPriorityRationaleProvider 패턴을 따른다:
 *   - @InvocableMethod 에 CapabilityType 을 지정하지 않는다 (이 org 에서 flex 템플릿 타입은 컴파일 거부됨).
 *   - 조회는 WITH USER_MODE. 권한이 없거나 데이터가 없으면 예외 대신 안내 문구를 돌려줘 프롬프트는 항상 생성되게 한다.
 */
public with sharing class NewsDailySummaryProvider {

    @TestVisible private static final String NEWS_SIGNAL = '뉴스';
    @TestVisible private static final Integer TOP_ACCOUNT_COUNT = 3;
    @TestVisible private static final Integer MAX_NEWS_PER_ACCOUNT = 3;
    @TestVisible private static final Integer MAX_INDUSTRY_NEWS = 5;
    @TestVisible private static final String NO_DATA_MESSAGE =
        '(오늘 적재된 담당 기업·산업군 뉴스 시그널이 없습니다. 뉴스를 지어내지 말고 "요약할 뉴스가 없습니다"라고만 안내하세요.)';
    @TestVisible private static final String NO_ACCESS_MESSAGE =
        '(뉴스 시그널 조회 권한이 없어 요약 근거를 제공할 수 없습니다. 뉴스를 임의로 만들지 마세요.)';

    @InvocableMethod(
        label='뉴스 일일 요약: 담당 기업·산업군 뉴스 grounding'
        description='주인공·Top3 담당 기업의 최근 뉴스와 담당 산업군 뉴스를 텍스트로 묶어 News_Daily_Summary 프롬프트 템플릿에 주입합니다. 뉴스를 새로 만들지 않습니다.'
    )
    public static List<Response> getSummaryContext(List<Request> requests) {
        // 이 프롬프트는 특정 레코드 입력이 필요 없다(홈 대시보드 전체 요약).
        // 템플릿이 호출할 때마다 한 번 근거 텍스트를 만들어 돌려준다.
        Integer count = (requests == null || requests.isEmpty()) ? 1 : requests.size();
        String context = buildContextText();
        List<Response> responses = new List<Response>();
        for (Integer i = 0; i < count; i++) {
            Response response = new Response();
            response.Prompt = context;
            responses.add(response);
        }
        return responses;
    }

    /** 담당 기업·산업군 뉴스를 조회해 프롬프트용 텍스트로 만든다. 권한 문제는 안내 문구로 대체. */
    @TestVisible
    private static String buildContextText() {
        try {
            String companyBlock = buildCompanyBlock();
            String industryBlock = buildIndustryBlock();
            if (companyBlock == null && industryBlock == null) {
                return NO_DATA_MESSAGE;
            }
            List<String> blocks = new List<String>();
            if (companyBlock != null) {
                blocks.add(companyBlock);
            }
            if (industryBlock != null) {
                blocks.add(industryBlock);
            }
            return String.join(blocks, '\n\n');
        } catch (QueryException e) {
            return NO_ACCESS_MESSAGE;
        }
    }

    /** Priority_Score__c 상위 3개 담당 Account 의 최근 뉴스 시그널을 텍스트로. 없으면 null. */
    private static String buildCompanyBlock() {
        List<Account> topAccounts = [
            SELECT Id, Name
            FROM Account
            WHERE Assigned_Company_Code__c != null
            WITH USER_MODE
            ORDER BY Priority_Score__c DESC NULLS LAST, Name ASC
            LIMIT :TOP_ACCOUNT_COUNT
        ];
        if (topAccounts.isEmpty()) {
            return null;
        }

        Map<Id, String> nameByAccountId = new Map<Id, String>();
        for (Account acct : topAccounts) {
            nameByAccountId.put(acct.Id, acct.Name);
        }

        // 회사별 최근 뉴스를 담되, 회사당 MAX_NEWS_PER_ACCOUNT 건으로 제한한다.
        List<ExternalSignal__c> signals = [
            SELECT Account__c, Signal_Date__c, Title__c, Summary__c, Source_URL__c
            FROM ExternalSignal__c
            WHERE Signal_Type__c = :NEWS_SIGNAL AND Account__c IN :nameByAccountId.keySet()
            WITH USER_MODE
            ORDER BY Account__c, Signal_Date__c DESC NULLS LAST
        ];
        if (signals.isEmpty()) {
            return null;
        }

        Map<Id, List<ExternalSignal__c>> byAccount = new Map<Id, List<ExternalSignal__c>>();
        for (ExternalSignal__c s : signals) {
            List<ExternalSignal__c> bucket = byAccount.get(s.Account__c);
            if (bucket == null) {
                bucket = new List<ExternalSignal__c>();
                byAccount.put(s.Account__c, bucket);
            }
            if (bucket.size() < MAX_NEWS_PER_ACCOUNT) {
                bucket.add(s);
            }
        }

        List<String> lines = new List<String>();
        lines.add('[담당 기업 뉴스 (우선순위 Top' + TOP_ACCOUNT_COUNT + ')]');
        // topAccounts 순서(우선순위 순)를 유지해 출력한다.
        for (Account acct : topAccounts) {
            List<ExternalSignal__c> bucket = byAccount.get(acct.Id);
            if (bucket == null || bucket.isEmpty()) {
                continue;
            }
            lines.add('# ' + acct.Name);
            for (ExternalSignal__c s : bucket) {
                lines.add(formatSignalLine(s.Signal_Date__c, s.Title__c, s.Summary__c, s.Source_URL__c));
            }
        }
        return lines.size() > 1 ? String.join(lines, '\n') : null;
    }

    /** Industry__c 로 분류된 산업군 뉴스를 텍스트로. 없으면 null. */
    private static String buildIndustryBlock() {
        List<ExternalSignal__c> signals = [
            SELECT Industry__c, Signal_Date__c, Title__c, Summary__c, Source_URL__c
            FROM ExternalSignal__c
            WHERE Signal_Type__c = :NEWS_SIGNAL AND Industry__c != null
            WITH USER_MODE
            ORDER BY Signal_Date__c DESC NULLS LAST
            LIMIT :MAX_INDUSTRY_NEWS
        ];
        if (signals.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        lines.add('[담당 산업군 뉴스]');
        for (ExternalSignal__c s : signals) {
            String industryTag = String.isBlank(s.Industry__c) ? '' : '(' + s.Industry__c + ') ';
            lines.add(formatSignalLine(s.Signal_Date__c, industryTag + s.Title__c, s.Summary__c, s.Source_URL__c));
        }
        return String.join(lines, '\n');
    }

    private static String formatSignalLine(Date signalDate, String title, String summary, String sourceUrl) {
        String dateText = signalDate == null ? '일자 미상' : String.valueOf(signalDate);
        String titleText = String.isBlank(title) ? '(제목 없음)' : title;
        String line = '- ' + dateText + ' ' + titleText;
        if (String.isNotBlank(summary)) {
            line += ': ' + summary;
        }
        if (String.isNotBlank(sourceUrl)) {
            line += ' (출처: ' + sourceUrl + ')';
        }
        return line;
    }

    /** 이 프롬프트는 레코드 입력이 필요 없으나, InvocableMethod 규약상 Request 타입을 둔다. */
    public class Request {
        @InvocableVariable(label='(사용 안 함)' description='뉴스 일일 요약은 특정 레코드 입력이 필요 없습니다.')
        public String placeholder;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 담당 기업·산업군 뉴스 근거 텍스트')
        public String Prompt;
    }
}
