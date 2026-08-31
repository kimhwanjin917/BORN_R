/**
 * 프롬프트 템플릿 "Account_Priority_Rationale"(Flex) 의 grounding 용 Apex.
 *
 * Prompt Builder 에서 리소스로 추가하면 템플릿 본문의 {!$Apex:AccountPriorityRationaleProvider.Prompt} 자리에
 * 해당 기업(Account) 의 최신 공시(분기 포함) 재무제표 수치와 전년 동기 대비 증감, 최근 외부 시그널(공시 등)이 텍스트로 주입된다.
 * 이 텍스트가 "왜 이 우선순위 점수인지"를 LLM 이 구체적 수치로 서술하는 근거가 된다.
 *
 * AI 이원화 원칙: 이 클래스는 Account.Priority_Score__c 를 재계산하지 않는다. 점수는 PriorityScoreBatch 가
 * 산정한 확정 값이고, 여기서는 그 점수의 배경이 되는 재무·시그널 사실만 모아 제공한다.
 *
 * LeadPriorityRationaleProvider 패턴을 그대로 따른다:
 *   - @InvocableMethod 에 CapabilityType 을 지정하지 않는다 (이 org 에서 flex 템플릿 타입은 컴파일 거부됨, 2026-08 확인).
 *   - Request 멤버 이름은 템플릿 입력 apiName(RelatedAccount) 과 일치해야 Prompt Builder 가 이 클래스를 노출한다.
 *   - 조회는 WITH USER_MODE. 권한이 없거나 데이터가 없으면 예외 대신 안내 문구를 돌려줘 프롬프트는 항상 생성되게 한다.
 */
public with sharing class AccountPriorityRationaleProvider {

    @TestVisible private static final Integer MAX_SIGNALS = 5;
    @TestVisible private static final String NO_ACCOUNT_MESSAGE =
        '(기업 정보가 전달되지 않았습니다. 제공된 점수 외의 근거를 만들어내지 마세요.)';
    @TestVisible private static final String NO_DATA_MESSAGE =
        '(이 기업에 연결된 재무제표·외부 시그널 데이터가 없습니다. 제공되지 않은 수치를 지어내지 마세요.)';
    @TestVisible private static final String NO_ACCESS_MESSAGE =
        '(근거 데이터 조회 권한이 없어 재무·시그널 상세를 제공할 수 없습니다. 수치를 임의로 만들지 마세요.)';

    @InvocableMethod(
        label='Account 우선순위 사유: 재무·시그널 grounding'
        description='기업(Account)의 최신 공시(분기 포함) 재무제표와 전년 동기 대비 증감, 최근 외부 시그널을 텍스트로 묶어 Account_Priority_Rationale 프롬프트 템플릿에 주입합니다. 점수는 재계산하지 않습니다.'
    )
    public static List<Response> getRationaleContext(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            Response response = new Response();
            response.Prompt = buildContextText(request == null ? null : request.RelatedAccount);
            responses.add(response);
        }
        return responses;
    }

    /** 기업의 근거 데이터를 조회해 프롬프트용 텍스트로 만든다. 권한 문제는 안내 문구로 대체. */
    @TestVisible
    private static String buildContextText(Account relatedAccount) {
        if (relatedAccount == null || relatedAccount.Id == null) {
            return NO_ACCOUNT_MESSAGE;
        }
        try {
            String financialBlock = buildFinancialBlock(relatedAccount.Id);
            String signalBlock = buildSignalBlock(relatedAccount.Id);
            if (financialBlock == null && signalBlock == null) {
                return NO_DATA_MESSAGE;
            }
            List<String> blocks = new List<String>();
            if (financialBlock != null) {
                blocks.add(financialBlock);
            }
            if (signalBlock != null) {
                blocks.add(signalBlock);
            }
            return String.join(blocks, '\n\n');
        } catch (QueryException e) {
            return NO_ACCESS_MESSAGE;
        }
    }

    /**
     * 최신 공시(분기 포함) 재무제표 1건과 전년 동기 대비 증감을 텍스트로. 없으면 null.
     * 점수 산정과 동일하게 최신은 recencyKey(Fiscal_Year*10+보고서 서수) 최대,
     * 전년 동기는 동일 보고서 코드·Fiscal_Year-1 로 골라 YoY 근거를 제공한다.
     */
    private static String buildFinancialBlock(Id accountId) {
        List<CorporateFinancialStatement__c> statements = [
            SELECT Fiscal_Year__c, Period_Type__c, External_Key__c,
                   Total_Assets__c, Total_Equity__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                   Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
            FROM CorporateFinancialStatement__c
            WHERE Account__c = :accountId
            WITH USER_MODE
            ORDER BY Fiscal_Year__c DESC NULLS LAST, Id ASC
        ];
        if (statements.isEmpty()) {
            return null;
        }
        return CfsGroundingBlock.render(statements);
    }

    /** 최근 외부 시그널 몇 건을 텍스트로. 없으면 null. */
    private static String buildSignalBlock(Id accountId) {
        List<ExternalSignal__c> signals = [
            SELECT Signal_Type__c, Signal_Date__c, Title__c, Summary__c
            FROM ExternalSignal__c
            WHERE Account__c = :accountId
            WITH USER_MODE
            ORDER BY Signal_Date__c DESC NULLS LAST
            LIMIT :MAX_SIGNALS
        ];
        if (signals.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        lines.add('[최근 외부 시그널]');
        for (ExternalSignal__c signal : signals) {
            String dateText = signal.Signal_Date__c == null ? '일자 미상' : String.valueOf(signal.Signal_Date__c);
            String typeText = String.isBlank(signal.Signal_Type__c) ? '기타' : signal.Signal_Type__c;
            String titleText = String.isBlank(signal.Title__c) ? '(제목 없음)' : signal.Title__c;
            String line = '- ' + dateText + ' [' + typeText + '] ' + titleText;
            if (String.isNotBlank(signal.Summary__c)) {
                line += ': ' + signal.Summary__c;
            }
            lines.add(line);
        }
        return String.join(lines, '\n');
    }

    /** 템플릿 입력과 동일한 이름/타입이어야 Prompt Builder 에서 이 클래스를 선택할 수 있다. */
    public class Request {
        @InvocableVariable(required=true label='RelatedAccount' description='프롬프트 템플릿의 Account 입력 (apiName: RelatedAccount)')
        public Account RelatedAccount;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 재무·시그널 근거 텍스트')
        public String Prompt;
    }
}