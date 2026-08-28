/**
 * 프롬프트 템플릿 "Meeting_Prep_Briefing"(Flex) 의 grounding 용 Apex.
 *
 * Prompt Builder 에서 리소스로 추가하면 템플릿 본문의 {!$Apex:MeetingPrepBriefingProvider.Prompt} 자리에
 * 해당 발굴 리드(주인공 기업)의 CRM 프로필 + Data Cloud 로 통합된 재무제표 추이 + 최근 외부 시그널이
 * 하나의 텍스트로 주입된다. 이 텍스트가 "미팅 준비 브리핑"의 근거가 된다.
 *
 * [Data Cloud 통합 관점]
 * CorporateFinancialStatement__c / ExternalSignal__c 는 Data Cloud 로 스트리밍되는 원천 CRM 오브젝트다
 * (scripts/datacloud 의 DMO/스트림 참고). 브리핑은 단건이 아니라 최근 연간 재무제표를 연도순으로 묶어
 * "자산·자본·현금·매출의 전년 대비 추이"를 근거로 제시한다. 여기에 CRM(Lead) 프로필과 외부 시그널을 합쳐
 * 재무·시그널·CRM 세 축을 grounding 한다.
 *
 * LeadPriorityRationaleProvider / RPProposalCatalogProvider 패턴을 그대로 따른다:
 *   - @InvocableMethod 에 CapabilityType 을 지정하지 않는다 (이 org 에서 flex 템플릿 타입은 컴파일 거부됨, 2026-08 확인).
 *   - Request 멤버 이름은 템플릿 입력 apiName(RelatedLead) 과 일치해야 Prompt Builder 가 이 클래스를 노출한다.
 *   - 조회는 WITH USER_MODE. 권한이 없거나 데이터가 없으면 예외 대신 안내 문구를 돌려줘 프롬프트는 항상 생성되게 한다.
 */
public with sharing class MeetingPrepBriefingProvider {

    @TestVisible private static final String ANNUAL_PERIOD = '4분기';
    @TestVisible private static final Integer MAX_ANNUAL_YEARS = 3;
    @TestVisible private static final Integer MAX_SIGNALS = 5;
    @TestVisible private static final String NO_LEAD_MESSAGE =
        '(리드 정보가 전달되지 않았습니다. 제공된 정보 외의 근거를 만들어내지 마세요.)';
    @TestVisible private static final String NO_DATA_MESSAGE =
        '(이 리드에 연결된 재무제표·외부 시그널 데이터가 없습니다. 제공되지 않은 수치를 지어내지 마세요.)';
    @TestVisible private static final String NO_ACCESS_MESSAGE =
        '(근거 데이터 조회 권한이 없어 재무·시그널 상세를 제공할 수 없습니다. 수치를 임의로 만들지 마세요.)';

    @InvocableMethod(
        label='미팅 준비 브리핑: 재무추이·시그널·CRM grounding'
        description='주인공 리드의 CRM 프로필과 Data Cloud 통합 재무제표 추이, 최근 외부 시그널을 텍스트로 묶어 Meeting_Prep_Briefing 프롬프트 템플릿에 주입합니다.'
    )
    public static List<Response> getBriefingContext(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            Response response = new Response();
            response.Prompt = buildContextText(request == null ? null : request.RelatedLead);
            responses.add(response);
        }
        return responses;
    }

    /** 리드의 근거 데이터를 조회해 브리핑용 텍스트로 만든다. 권한 문제는 안내 문구로 대체. */
    @TestVisible
    private static String buildContextText(Lead relatedLead) {
        if (relatedLead == null || relatedLead.Id == null) {
            return NO_LEAD_MESSAGE;
        }
        try {
            List<String> blocks = new List<String>();
            String crmBlock = buildCrmBlock(relatedLead.Id);
            if (crmBlock != null) {
                blocks.add(crmBlock);
            }
            String financialBlock = buildFinancialTrendBlock(relatedLead.Id);
            String signalBlock = buildSignalBlock(relatedLead.Id);
            if (financialBlock == null && signalBlock == null) {
                // CRM 프로필만으로는 브리핑 근거가 부족하다고 명시한다.
                if (crmBlock == null) {
                    return NO_DATA_MESSAGE;
                }
                blocks.add(NO_DATA_MESSAGE);
                return String.join(blocks, '\n\n');
            }
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

    /** CRM(Lead) 프로필. 회사·업종·직함·담당 RM 등. Data Cloud 통합의 CRM 축. */
    private static String buildCrmBlock(Id leadId) {
        List<Lead> leads = [
            SELECT Company, Industry, Title, Status, Assigned_Company_Code__c, Owner.Name,
                   Priority_Score__c, Priority_Rationale_Summary__c, Priority_Rationale_Detail__c,
                   Recommended_Product_Family__c, Recommended_Product_Rationale__c
            FROM Lead
            WHERE Id = :leadId
            WITH USER_MODE
            LIMIT 1
        ];
        if (leads.isEmpty()) {
            return null;
        }
        Lead lead = leads[0];
        List<String> lines = new List<String>();
        lines.add('[CRM 프로필]');
        lines.add('- 회사명: ' + textOrUnknown(lead.Company));
        lines.add('- 업종: ' + textOrUnknown(lead.Industry));
        lines.add('- 담당자 직함: ' + textOrUnknown(lead.Title));
        lines.add('- 리드 상태: ' + textOrUnknown(lead.Status));
        lines.add('- DART 기업 코드: ' + textOrUnknown(lead.Assigned_Company_Code__c));
        lines.add('- 담당 RM: ' + (lead.Owner == null ? '정보 없음' : textOrUnknown(lead.Owner.Name)));
        lines.add('- 우선순위 점수: '
            + (lead.Priority_Score__c == null ? '정보 없음' : String.valueOf(lead.Priority_Score__c)));
        lines.add('- 우선순위 사유 요약(있으면 이 값을 그대로 반영): '
            + textOrUnknown(lead.Priority_Rationale_Summary__c));
        lines.add('- 우선순위 사유 상세: ' + textOrUnknown(lead.Priority_Rationale_Detail__c));
        lines.add('- 추천 상품군(확정 값, 있으면 이 값을 따를 것): '
            + (String.isBlank(lead.Recommended_Product_Family__c) ? '미정' : lead.Recommended_Product_Family__c));
        lines.add('- 추천 상품군 근거: ' + textOrUnknown(lead.Recommended_Product_Rationale__c));
        return String.join(lines, '\n');
    }

    /** 최근 연간 재무제표를 연도순으로 묶어 추이를 텍스트로. 없으면 null. (Data Cloud 통합 재무 축) */
    private static String buildFinancialTrendBlock(Id leadId) {
        List<CorporateFinancialStatement__c> statements = [
            SELECT Fiscal_Year__c, Total_Assets__c, Total_Equity__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                   Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c,
                   Revenue__c, Operating_Income__c
            FROM CorporateFinancialStatement__c
            WHERE Lead__c = :leadId AND Period_Type__c = :ANNUAL_PERIOD
            WITH USER_MODE
            ORDER BY Fiscal_Year__c DESC NULLS LAST
            LIMIT :MAX_ANNUAL_YEARS
        ];
        if (statements.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        lines.add('[재무제표 추이 - 최근 연간, 최신 연도부터. Data Cloud 통합 데이터]');
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

    /** 최근 외부 시그널 몇 건을 텍스트로. 없으면 null. (Data Cloud 통합 시그널 축) */
    private static String buildSignalBlock(Id leadId) {
        List<ExternalSignal__c> signals = [
            SELECT Signal_Type__c, Signal_Date__c, Title__c, Summary__c
            FROM ExternalSignal__c
            WHERE Lead__c = :leadId
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

    private static String textOrUnknown(String value) {
        return String.isBlank(value) ? '정보 없음' : value;
    }

    /** 원화 금액을 억 단위로 읽기 쉽게. 값이 없으면 "정보 없음". */
    private static String formatWon(Decimal amount) {
        if (amount == null) {
            return '정보 없음';
        }
        Decimal inEok = (amount / 100000000L).setScale(1);
        return inEok.toPlainString().replaceAll('\\.0$', '') + '억 원';
    }

    /** 템플릿 입력과 동일한 이름/타입이어야 Prompt Builder 에서 이 클래스를 선택할 수 있다. */
    public class Request {
        @InvocableVariable(required=true label='RelatedLead' description='프롬프트 템플릿의 Lead 입력 (apiName: RelatedLead)')
        public Lead RelatedLead;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 브리핑 근거 텍스트')
        public String Prompt;
    }
}