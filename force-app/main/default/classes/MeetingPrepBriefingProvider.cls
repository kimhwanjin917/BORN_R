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
 *
 * [블록 격리 원칙 — 2026-08 재발 방지]
 * 근거 블록(CRM·우선순위·연간재무·분기재무·유사Won·시그널)은 각자 독립적으로 조회하고, SOQL 은
 * 블록 단위로 try/catch(QueryException) 한다. WITH USER_MODE 쿼리는 SELECT 필드 중 하나라도 FLS 가
 * 없으면 쿼리 전체가 QueryException 을 던지는데, 예전엔 buildContextText 의 단일 try/catch 가 이를
 * 통째로 삼켜 "재무 데이터 없음"으로 뭉갰다. 실제로는 분기 블록의 필드 하나(Disclosure_Period_YM__c)가
 * 누락됐을 뿐 연간 재무는 멀쩡했는데도 전부 버려졌다. 이제 블록별로 격리해 한 블록이 실패해도 나머지는
 * 살리고, "권한 없음(QueryException)"과 "데이터 없음(빈 결과)"을 구분해 안내한다.
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

    /**
     * 블록 하나의 조회 결과. text 가 채워지면 표시할 내용이 있는 것이고,
     * text 가 null 이면 accessDenied 로 "권한 없음(쿼리 실패)"인지 "데이터 없음(빈 결과)"인지 구분한다.
     */
    private class BlockResult {
        String text;
        Boolean accessDenied;
        BlockResult(String text, Boolean accessDenied) {
            this.text = text;
            this.accessDenied = accessDenied;
        }
    }

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

    /**
     * 리드의 근거 데이터를 조회해 브리핑용 텍스트로 만든다.
     * 블록별로 격리 조회하므로 한 블록의 권한/조회 실패가 나머지 블록을 죽이지 않는다.
     */
    @TestVisible
    private static String buildContextText(Lead relatedLead) {
        if (relatedLead == null || relatedLead.Id == null) {
            return NO_LEAD_MESSAGE;
        }
        Id leadId = relatedLead.Id;
        List<String> blocks = new List<String>();

        BlockResult crm = buildCrmBlock(leadId);
        if (crm.text != null) {
            blocks.add(crm.text);
        }
        // 우선순위 점수를 "적합도/니즈/공시" 항목별로 분해한 근거(배치와 동일 규칙, PriorityScoreExplainer).
        // 있으면 CRM 블록 바로 뒤에 붙여 "왜 이 점수인지"를 LLM 이 수치로 설명하게 한다.
        // 외부 클래스라 여기서 QueryException 을 격리해, 우선순위 블록이 실패해도 나머지는 남긴다.
        String priorityScoreBlock;
        try {
            priorityScoreBlock = PriorityScoreExplainer.buildGroundingText(leadId);
        } catch (QueryException e) {
            priorityScoreBlock = null;
        }
        if (priorityScoreBlock != null) {
            blocks.add(priorityScoreBlock);
        }

        BlockResult financial = buildFinancialTrendBlock(leadId);
        BlockResult latestQuarter = buildLatestQuarterBlock(leadId);
        BlockResult won = buildSimilarWonBlock(leadId);
        BlockResult signal = buildSignalBlock(leadId);

        if (financial.text != null) {
            blocks.add(financial.text);
        }
        if (latestQuarter.text != null) {
            blocks.add(latestQuarter.text);
        }
        if (signal.text != null) {
            blocks.add(signal.text);
        }
        if (won.text != null) {
            blocks.add(won.text);
        }

        // 재무·시그널 본문이 하나도 안 붙었으면, 그 이유가 "권한 없음"인지 "데이터 없음"인지 구분해 알린다.
        // 예전엔 둘을 뭉뚱그려 항상 "데이터 없음"으로 보였고, 그래서 권한 문제를 매번 데이터 문제로 오인했다.
        Boolean noEvidenceShown = (financial.text == null && signal.text == null);
        if (noEvidenceShown) {
            Boolean accessDenied = financial.accessDenied
                || latestQuarter.accessDenied
                || signal.accessDenied;
            String note = accessDenied ? NO_ACCESS_MESSAGE : NO_DATA_MESSAGE;
            if (blocks.isEmpty()) {
                return note;
            }
            blocks.add(note);
        }
        return String.join(blocks, '\n\n');
    }

    /** CRM(Lead) 프로필. 회사·업종·직함·담당 RM 등. Data Cloud 통합의 CRM 축. */
    private static BlockResult buildCrmBlock(Id leadId) {
        List<Lead> leads;
        try {
            leads = [
                SELECT Name, Company, Industry, Title, Status, Assigned_Company_Code__c, Owner.Name,
                       Priority_Score__c, Priority_Rationale_Summary__c, Priority_Rationale_Detail__c,
                       Recommended_Product_Family__c, Recommended_Product_Rationale__c
                FROM Lead
                WHERE Id = :leadId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException e) {
            return new BlockResult(null, true);
        }
        if (leads.isEmpty()) {
            return new BlockResult(null, false);
        }
        Lead lead = leads[0];
        List<String> lines = new List<String>();
        lines.add('[CRM 프로필]');
        lines.add('- 회사명: ' + textOrUnknown(lead.Company));
        lines.add('- 담당자: ' + textOrUnknown(lead.Name));
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
        lines.add('- 추천 근거: ' + textOrUnknown(lead.Recommended_Product_Rationale__c));
        return new BlockResult(String.join(lines, '\n'), false);
    }

    /**
     * 같은 산업군(있으면 추천 상품군까지)의 종결 기회 Won 비율. 숫자는 SimilarWonAnalysisAction 이
     * Aggregate SOQL 로 실계산한다 — 여기서 다시 세지 않는다.
     *
     * 이 블록이 없으면 LLM 이 근거 없이 확률을 지어낸다(실제로 "추정 40~60%" 가 나온 적이 있다).
     * 모수가 0이면 수치 대신 "추정하지 말 것" 지시를 넘긴다.
     */
    private static BlockResult buildSimilarWonBlock(Id leadId) {
        List<Lead> leads;
        try {
            leads = [
                SELECT Industry, Recommended_Product_Family__c
                FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1
            ];
        } catch (QueryException e) {
            return new BlockResult(null, true);
        }
        if (leads.isEmpty() || String.isBlank(leads[0].Industry)) {
            return new BlockResult(null, false);
        }
        SimilarWonAnalysisAction.Request req = new SimilarWonAnalysisAction.Request();
        req.industry = leads[0].Industry;
        // 상품군이 정해져 있으면 그 상품군의 종결 기회로 모수를 좁힌다. Lead 는 '회사채', Product2 는 '채권'.
        String family = leads[0].Recommended_Product_Family__c;
        if (String.isNotBlank(family)) {
            req.productType = family == '회사채' ? '채권' : family;
        }
        List<SimilarWonAnalysisAction.Result> results;
        try {
            results = SimilarWonAnalysisAction.analyze(new List<SimilarWonAnalysisAction.Request>{ req });
        } catch (Exception e) {
            return new BlockResult(null, false);
        }
        if (results == null || results.isEmpty()) {
            return new BlockResult(null, false);
        }
        SimilarWonAnalysisAction.Result r = results[0];
        List<String> lines = new List<String>();
        lines.add('[유사 Won 집계 - Apex 가 실제 종결 기회를 센 값이다. 확률은 이 수치만 인용하고 절대 추정하지 말 것]');
        lines.add('- 기준 산업군: ' + textOrUnknown(leads[0].Industry)
            + (String.isBlank(req.productType) ? ' (상품군 미지정, 전체 상품 기준)' : ' · 상품군: ' + req.productType));
        if (r.insufficientData == true || r.totalCount == null || r.totalCount == 0) {
            lines.add('- 조건에 맞는 종결 기회가 없다. 확률을 말하지 말고 "유사 사례가 부족하다"고만 쓸 것.');
        } else {
            lines.add('- 종결 ' + r.totalCount + '건 중 Won ' + r.wonCount + '건 · Won 비율 ' + r.wonRate + '%');
        }
        return new BlockResult(String.join(lines, '\n'), false);
    }

    /**
     * 가장 최근 분기 재무 1건. 연간(사업보고서)은 12월 결산이라 반년 넘게 묵은 숫자가 되는데,
     * 자금운용 제안은 "지금 굴릴 수 있는 돈"이 핵심이라 최신 잔고를 따로 보여준다.
     * 추세는 위의 연간 블록으로, 잔고는 이 블록으로 판단하게 한다.
     */
    private static BlockResult buildLatestQuarterBlock(Id leadId) {
        List<CorporateFinancialStatement__c> rows;
        try {
            rows = [
                SELECT Fiscal_Year__c, Period_Type__c, Disclosure_Period_YM__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Bonds_Payable__c, Revenue__c
                FROM CorporateFinancialStatement__c
                WHERE Lead__c = :leadId AND Period_Type__c != :ANNUAL_PERIOD
                WITH USER_MODE
                ORDER BY Fiscal_Year__c DESC NULLS LAST, Disclosure_Period_YM__c DESC NULLS LAST
                LIMIT 1
            ];
        } catch (QueryException e) {
            return new BlockResult(null, true);
        }
        if (rows.isEmpty()) {
            return new BlockResult(null, false);
        }
        CorporateFinancialStatement__c cfs = rows[0];
        List<String> lines = new List<String>();
        lines.add('[최신 분기 재무 - 위 연간 추이보다 최신이다. 현재 운용 가능한 자금 규모는 이 값을 기준으로 말할 것]');
        lines.add('- 공시기준 ' + textOrUnknown(cfs.Disclosure_Period_YM__c)
            + ' (' + textOrUnknown(cfs.Period_Type__c) + ')'
            + ': 현금및현금성자산 ' + formatWon(cfs.Cash_And_Equivalents__c)
            + ', 단기금융상품 ' + formatWon(cfs.Short_Term_Financial_Instruments__c)
            + ', 단기차입금 ' + formatWon(cfs.Short_Term_Borrowings__c)
            + ', 사채 ' + formatWon(cfs.Bonds_Payable__c)
            + ', 매출 ' + formatWon(cfs.Revenue__c));
        return new BlockResult(String.join(lines, '\n'), false);
    }

    /** 최근 연간 재무제표를 연도순으로 묶어 추이를 텍스트로. 없으면 빈 결과. (Data Cloud 통합 재무 축) */
    private static BlockResult buildFinancialTrendBlock(Id leadId) {
        List<CorporateFinancialStatement__c> statements;
        try {
            statements = [
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
        } catch (QueryException e) {
            return new BlockResult(null, true);
        }
        if (statements.isEmpty()) {
            return new BlockResult(null, false);
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
        return new BlockResult(String.join(lines, '\n'), false);
    }

    /** 최근 외부 시그널 몇 건을 텍스트로. 없으면 빈 결과. (Data Cloud 통합 시그널 축) */
    private static BlockResult buildSignalBlock(Id leadId) {
        List<ExternalSignal__c> signals;
        try {
            signals = [
                SELECT Signal_Type__c, Signal_Date__c, Title__c, Summary__c
                FROM ExternalSignal__c
                WHERE Lead__c = :leadId
                WITH USER_MODE
                ORDER BY Signal_Date__c DESC NULLS LAST
                LIMIT :MAX_SIGNALS
            ];
        } catch (QueryException e) {
            return new BlockResult(null, true);
        }
        if (signals.isEmpty()) {
            return new BlockResult(null, false);
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
        return new BlockResult(String.join(lines, '\n'), false);
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