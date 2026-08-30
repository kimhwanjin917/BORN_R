/**
 * Controller for the meeting-preparation briefing card on Lead and Opportunity pages.
 * Opportunity briefing data is stored in a standard ContentNote linked to the record
 * because the target org's custom briefing fields are unavailable to Apex at runtime.
 * Lead behavior remains unchanged.
 */
public with sharing class MeetingPrepBriefingController {

    @TestVisible private static final String TEMPLATE_API_NAME = 'Meeting_Prep_Briefing';
    @TestVisible private static final String OPPORTUNITY_NOTE_TITLE = '미팅 준비 브리핑';
    @TestVisible private static String testResponseOverride;

    public class BriefingResult {
        @AuraEnabled public String briefing;
        @AuraEnabled public Datetime updatedAt;
    }

    public class SimilarWonCardResult {
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer wonCount;
        @AuraEnabled public Decimal wonRate;
        @AuraEnabled public Boolean insufficientData;
        @AuraEnabled public String industry;
        @AuraEnabled public String productType;
        @AuraEnabled public String message;
    }

    /** @param recordId Lead or Opportunity Id. @return Stored briefing data. */
    @AuraEnabled(cacheable=true)
    public static BriefingResult getBriefing(Id recordId) {
        BriefingResult result = new BriefingResult();
        if (isOpportunity(recordId)) {
            return loadOpportunityBriefing(recordId);
        }
        Lead lead = loadLead(recordId);
        result.briefing = lead.Meeting_Prep_Briefing__c;
        result.updatedAt = lead.Meeting_Prep_Briefing_Updated_At__c;
        return result;
    }

    /** @param recordId Opportunity Id. @return Similar Won aggregation for the card. */
    @AuraEnabled(cacheable=true)
    public static SimilarWonCardResult getSimilarWon(Id recordId) {
        if (recordId == null || !isOpportunity(recordId)) {
            return null;
        }
        try {
            Opportunity opportunity = [
                SELECT Account.Industry, Product_Family__c
                FROM Opportunity
                WHERE Id = :recordId
                WITH USER_MODE
                LIMIT 1
            ];
            SimilarWonAnalysisAction.Request request = new SimilarWonAnalysisAction.Request();
            request.industry = opportunity.Account == null ? null : opportunity.Account.Industry;
            request.productType = opportunity.Product_Family__c;
            List<SimilarWonAnalysisAction.Result> results = SimilarWonAnalysisAction.analyze(
                new List<SimilarWonAnalysisAction.Request>{ request });
            if (results == null || results.isEmpty()) {
                return null;
            }
            SimilarWonAnalysisAction.Result source = results[0];
            SimilarWonCardResult card = new SimilarWonCardResult();
            card.totalCount = source.totalCount;
            card.wonCount = source.wonCount;
            card.wonRate = source.wonRate;
            card.insufficientData = source.insufficientData;
            card.industry = source.industry;
            card.productType = source.productType;
            card.message = source.message;
            return card;
        } catch (QueryException e) {
            throw new AuraHandledException('유사 WON 집계를 조회할 수 없습니다.');
        } catch (Exception e) {
            throw new AuraHandledException('유사 WON 집계를 계산하는 중 오류가 발생했습니다.');
        }
    }

    /** @param recordId Lead Id. Ensures a missing Lead recommendation is populated. */
    @AuraEnabled
    public static void ensureRecommendation(Id recordId) {
        if (recordId == null || isOpportunity(recordId)) {
            return;
        }
        LeadProductRecommendationService.ensureRecommendation(recordId);
    }

    /** @param recordId Lead or Opportunity Id. @return Newly generated and stored briefing. */
    @AuraEnabled
    public static BriefingResult generateBriefing(Id recordId) {
        if (recordId == null) {
            throw new AuraHandledException('레코드 정보가 없어 브리핑을 생성할 수 없습니다.');
        }
        try {
            String briefingText = invokePromptTemplate(recordId);
            // Opportunity는 프롬프트 응답이 정상처럼 보여도 재무 카드만 수치 없는
            // 문구로 생성되는 경우가 있다. 원천 데이터가 있으면 매번 서버에서
            // 재무 섹션을 보강해 첫 진입 결과가 프롬프트 변형에 좌우되지 않게 한다.
            String financialSection = isOpportunity(recordId)
                ? buildFinancialSection(recordId)
                : null;
            String externalSignalSection = isOpportunity(recordId)
                ? buildExternalSignalSection(recordId)
                : null;
            if (!String.isBlank(financialSection)) {
                // 원천 재무 데이터가 있는데 모델이 fallback을 선택하는 경우가 있어
                // 한 번 재호출한다. 최종 결과에는 항상 원천 수치 섹션을 넣는다.
                if (isFinancialFallback(briefingText)) {
                    briefingText = invokePromptTemplate(recordId);
                }
                briefingText = replaceFinancialSection(briefingText, financialSection);
            }
            if (!String.isBlank(externalSignalSection)) {
                // 모델이 외부 시그널을 누락하거나 fallback으로 답해도
                // 최종 결과에는 보안 조회된 실제 시그널을 반드시 넣는다.
                briefingText = replaceExternalSignalSection(briefingText, externalSignalSection);
            }
            if (String.isBlank(briefingText)) {
                throw new AuraHandledException('AI 응답이 비어 있어 브리핑을 생성하지 못했습니다.');
            }
            Datetime now = System.now();
            BriefingResult result = new BriefingResult();
            result.briefing = briefingText;
            result.updatedAt = now;
            if (isOpportunity(recordId)) {
                saveOpportunityBriefing(recordId, briefingText);
                return result;
            }
            SObject toUpdate = new Lead(
                Id = recordId,
                Meeting_Prep_Briefing__c = briefingText,
                Meeting_Prep_Briefing_Updated_At__c = now
            );
            update as user toUpdate;
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('브리핑 생성 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    private static Lead loadLead(Id recordId) {
        return [
            SELECT Meeting_Prep_Briefing__c, Meeting_Prep_Briefing_Updated_At__c
            FROM Lead
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static BriefingResult loadOpportunityBriefing(Id recordId) {
        BriefingResult result = new BriefingResult();
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            WITH USER_MODE
            LIMIT 50
        ];
        if (links.isEmpty()) {
            return result;
        }

        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            documentIds.add(link.ContentDocumentId);
        }
        List<ContentNote> notes = [
            SELECT Id, Title, Content, LastModifiedDate
            FROM ContentNote
            WHERE Id IN :documentIds AND Title = :OPPORTUNITY_NOTE_TITLE
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!notes.isEmpty()) {
            String briefingText = notes[0].Content == null
                ? null
                : normalizeStoredBriefing(notes[0].Content.toString());
            // 데이터가 있는데도 과거에 저장된 "수치 없음" 결과는 브리핑으로 취급하지
            // 않는다. LWC가 자동 재생성하도록 빈 결과를 반환한다.
            if (!isStoredBriefingFallback(briefingText) || !hasBriefingGroundingData(recordId)) {
                result.briefing = briefingText;
                result.updatedAt = notes[0].LastModifiedDate;
            }
        }
        return result;
    }

    /** ContentNote converts line breaks to rich-text HTML; restore section breaks for the LWC parser. */
    private static String normalizeStoredBriefing(String briefingText) {
        if (String.isBlank(briefingText)) {
            return briefingText;
        }
        String normalized = briefingText
            .replaceAll('(?i)<br\\s*/?>', '\n')
            .replaceAll('(?i)</p>', '\n')
            .replaceAll('(?i)</div>', '\n')
            .replaceAll('<[^>]+>', '')
            .replace('&amp;', '&')
            .replace('&lt;', '<')
            .replace('&gt;', '>');
        // Some ContentNote payloads omit all separators between paragraphs.
        normalized = normalized.replaceAll('(?<!^)■', '\n■');
        return normalized.trim();
    }

    @TestVisible
    private static Boolean isFinancialFallback(String briefingText) {
        if (String.isBlank(briefingText)) {
            return false;
        }
        return briefingText.contains('재무 수치가 제공되지')
            || briefingText.contains('재무 수치가 포함되어 있지')
            || briefingText.contains('재무·추이 수치가 제공되지')
            || briefingText.contains('근거 데이터 조회 권한')
            || briefingText.contains('재무 추이의 상세가 없')
            || briefingText.contains('재무 추이 수치가 없어')
            || briefingText.contains('재무 추이의 구체적 항목이 제공될 때까지')
            || briefingText.contains('구체적 수치 확인은 불가능')
            || briefingText.contains('구체 재무 추이를 확인할 수 없')
            || briefingText.contains('재무 세부 자료')
            || briefingText.contains('재무 추이 상세 데이터 접근이 불가')
            || briefingText.contains('구체적 매출·자산·현금흐름 수치를 제시할 수 없')
            || briefingText.contains('제공된 근거 데이터 내에서 확인 가능한 항목이 없어')
            || briefingText.contains('구체적 흐름은 미확인')
            || briefingText.contains('재무·시그널 상세를 제공할 수 없')
            || (briefingText.contains('재무 추이') && (
                briefingText.contains('조회 불가')
                || briefingText.contains('접근할 수 없')
                || briefingText.contains('접근이 불가')
                || briefingText.contains('수치를 제시할 수 없')
                || briefingText.contains('수치 확인이 불가')
                || briefingText.contains('자료가 없')
                || briefingText.contains('자료의 부재')
                || briefingText.contains('미확인')
            ));
    }

    @TestVisible
    private static Boolean isExternalSignalFallback(String briefingText) {
        if (String.isBlank(briefingText)) {
            return false;
        }
        return briefingText.contains('외부 시그널 상세가 제공되지')
            || briefingText.contains('외부 시그널 세부 정보에 접근하지 못')
            || briefingText.contains('외부 시그널 상세 정보에 접근하지 못')
            || briefingText.contains('외부 시그널에 접근할 수 없')
            || briefingText.contains('외부 시그널 상세를 확인할 수 없')
            || briefingText.contains('외부 시그널이 제공되지')
            || briefingText.contains('외부 시그널과 관련된 상세 정보가 제공되지')
            || briefingText.contains('외부 시그널과 관련된 상세 정보는 제공되지')
            || briefingText.contains('재무·시그널 상세가 제공되지')
            || briefingText.contains('외부 신호의 상세 내용은 제공되지')
            || briefingText.contains('외부 신호 상세가 제공되지')
            || briefingText.contains('시그널 상세 내용은 제공되지');
    }

    private static Boolean isStoredBriefingFallback(String briefingText) {
        return isFinancialFallback(briefingText) || isExternalSignalFallback(briefingText);
    }

    private static Boolean hasBriefingGroundingData(Id opportunityId) {
        try {
            Opportunity opportunity = [
                SELECT AccountId
                FROM Opportunity
                WHERE Id = :opportunityId
                WITH USER_MODE
                LIMIT 1
            ];
            if (opportunity.AccountId == null) {
                return false;
            }
            return hasFinancialDataForAccount(opportunity.AccountId)
                || hasExternalSignalsForAccount(opportunity.AccountId);
        } catch (QueryException e) {
            return false;
        }
    }

    /**
     * 이 Account 로 전환된 Lead 의 Id 집합. 재무·시그널은 전환 시 Account 로 재연결되지만,
     * 재연결이 누락된 경우(과거 표준 Convert 경로 등) 데이터가 Lead 에만 남아 있어
     * Account 기준 조회로는 안 잡힌다. 이 Lead Id 들을 조회에 함께 넣어 폴백한다.
     */
    private static Set<Id> convertedLeadIdsForAccount(Id accountId) {
        Set<Id> leadIds = new Set<Id>();
        if (accountId == null) {
            return leadIds;
        }
        try {
            for (Lead lead : [
                SELECT Id
                FROM Lead
                WHERE ConvertedAccountId = :accountId
                WITH USER_MODE
            ]) {
                leadIds.add(lead.Id);
            }
        } catch (QueryException e) {
            // 권한 없으면 폴백만 포기하고 Account 기준 조회는 그대로 진행한다.
        }
        return leadIds;
    }

    private static Boolean hasFinancialDataForAccount(Id accountId) {
        try {
            Set<Id> leadIds = convertedLeadIdsForAccount(accountId);
            return [
                SELECT COUNT()
                FROM CorporateFinancialStatement__c
                WHERE Account__c = :accountId OR Lead__c IN :leadIds
                WITH USER_MODE
            ] > 0;
        } catch (QueryException e) {
            return false;
        }
    }

    private static Boolean hasExternalSignalsForAccount(Id accountId) {
        try {
            Set<Id> leadIds = convertedLeadIdsForAccount(accountId);
            return [
                SELECT COUNT()
                FROM ExternalSignal__c
                WHERE Account__c = :accountId OR Lead__c IN :leadIds
                WITH USER_MODE
            ] > 0;
        } catch (QueryException e) {
            return false;
        }
    }

    private static String buildFinancialSection(Id opportunityId) {
        try {
            Opportunity opportunity = [
                SELECT AccountId
                FROM Opportunity
                WHERE Id = :opportunityId
                WITH USER_MODE
                LIMIT 1
            ];
            if (opportunity.AccountId == null) {
                return null;
            }
            Set<Id> leadIds = convertedLeadIdsForAccount(opportunity.AccountId);
            List<CorporateFinancialStatement__c> annual = [
                SELECT Fiscal_Year__c, Total_Assets__c, Total_Equity__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Long_Term_Borrowings__c,
                       Bonds_Payable__c, Revenue__c, Operating_Income__c
                FROM CorporateFinancialStatement__c
                WHERE (Account__c = :opportunity.AccountId OR Lead__c IN :leadIds)
                      AND Period_Type__c = '4분기'
                WITH USER_MODE
                ORDER BY Fiscal_Year__c DESC NULLS LAST
                LIMIT 3
            ];
            List<CorporateFinancialStatement__c> quarter = [
                SELECT Fiscal_Year__c, External_Key__c, Period_Type__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Bonds_Payable__c, Revenue__c
                FROM CorporateFinancialStatement__c
                WHERE (Account__c = :opportunity.AccountId OR Lead__c IN :leadIds)
                      AND Period_Type__c != '4분기'
                WITH USER_MODE
                ORDER BY Fiscal_Year__c DESC NULLS LAST, External_Key__c DESC NULLS LAST
                LIMIT 1
            ];
            if (annual.isEmpty() && quarter.isEmpty()) {
                return null;
            }
            List<String> lines = new List<String>{ '■ 재무 하이라이트:' };
            for (CorporateFinancialStatement__c statement : annual) {
                lines.add('- ' + yearText(statement.Fiscal_Year__c)
                    + ': 매출액 ' + formatWon(statement.Revenue__c)
                    + ', 영업이익 ' + formatWon(statement.Operating_Income__c)
                    + ', 자산총계 ' + formatWon(statement.Total_Assets__c)
                    + ', 현금및현금성자산 ' + formatWon(statement.Cash_And_Equivalents__c)
                    + ', 단기금융상품 ' + formatWon(statement.Short_Term_Financial_Instruments__c)
                    + ', 단기차입금 ' + formatWon(statement.Short_Term_Borrowings__c)
                    + ', 장기차입금 ' + formatWon(statement.Long_Term_Borrowings__c)
                    + ', 사채 ' + formatWon(statement.Bonds_Payable__c));
            }
            if (!quarter.isEmpty()) {
                CorporateFinancialStatement__c statement = quarter[0];
                lines.add('- 최신 분기 ' + disclosurePeriodText(
                        statement.Fiscal_Year__c, statement.External_Key__c, statement.Period_Type__c)
                    + ' (' + textOrUnknown(statement.Period_Type__c) + '): 현금및현금성자산 '
                    + formatWon(statement.Cash_And_Equivalents__c)
                    + ', 단기금융상품 ' + formatWon(statement.Short_Term_Financial_Instruments__c)
                    + ', 단기차입금 ' + formatWon(statement.Short_Term_Borrowings__c)
                    + ', 사채 ' + formatWon(statement.Bonds_Payable__c)
                    + ', 매출액 ' + formatWon(statement.Revenue__c));
            }
            return String.join(lines, '\n');
        } catch (QueryException e) {
            return null;
        }
    }

    private static String replaceFinancialSection(String briefingText, String financialSection) {
        if (String.isBlank(briefingText) || String.isBlank(financialSection)) {
            return briefingText;
        }
        String pattern = '(?s)(?:^|\\n)\\s*(?:■\\s*)?재무\\s*하이라이트\\s*:?.*?(?=\\n\\s*(?:■|◆)|$)';
        if (briefingText.replaceFirst(pattern, financialSection) != briefingText) {
            return briefingText.replaceFirst(pattern, financialSection);
        }
        // AI가 재무 섹션 제목을 생략한 경우에도 다른 카드와 원문을 보존하면서
        // 숫자 섹션을 추가한다.
        return briefingText + '\n' + financialSection;
    }

    private static String buildExternalSignalSection(Id opportunityId) {
        try {
            Opportunity opportunity = [
                SELECT AccountId
                FROM Opportunity
                WHERE Id = :opportunityId
                WITH USER_MODE
                LIMIT 1
            ];
            if (opportunity.AccountId == null) {
                return null;
            }
            Set<Id> leadIds = convertedLeadIdsForAccount(opportunity.AccountId);
            List<ExternalSignal__c> signals = [
                SELECT Signal_Type__c, Signal_Date__c, Title__c, Summary__c
                FROM ExternalSignal__c
                WHERE Account__c = :opportunity.AccountId OR Lead__c IN :leadIds
                WITH USER_MODE
                ORDER BY Signal_Date__c DESC NULLS LAST
                LIMIT 5
            ];
            if (signals.isEmpty()) {
                return null;
            }
            List<String> lines = new List<String>{ '■ 최근 동향:' };
            for (ExternalSignal__c signal : signals) {
                String dateText = signal.Signal_Date__c == null
                    ? '일자 미상'
                    : String.valueOf(signal.Signal_Date__c);
                String typeText = String.isBlank(signal.Signal_Type__c)
                    ? '기타'
                    : signal.Signal_Type__c;
                String titleText = String.isBlank(signal.Title__c)
                    ? '(제목 없음)'
                    : signal.Title__c;
                String line = '- ' + dateText + ' [' + typeText + '] ' + titleText;
                if (String.isNotBlank(signal.Summary__c)) {
                    line += ': ' + signal.Summary__c;
                }
                lines.add(line);
            }
            return String.join(lines, '\n');
        } catch (QueryException e) {
            return null;
        }
    }

    private static String replaceExternalSignalSection(String briefingText, String signalSection) {
        if (String.isBlank(briefingText) || String.isBlank(signalSection)) {
            return briefingText;
        }
        String pattern = '(?s)(?:^|\\n)\\s*(?:■\\s*)?최근\\s*동향\\s*:?.*?(?=\\n\\s*(?:■|◆)|$)';
        if (briefingText.replaceFirst(pattern, signalSection) != briefingText) {
            return briefingText.replaceFirst(pattern, signalSection);
        }
        return briefingText + '\n' + signalSection;
    }

    private static String yearText(Decimal year) {
        return year == null ? '연도 미상' : year.intValue() + '년';
    }

    private static String textOrUnknown(String value) {
        return String.isBlank(value) ? '정보 없음' : value;
    }

    private static String disclosurePeriodText(Decimal fiscalYear, String externalKey, String periodType) {
        if (fiscalYear == null) {
            return '정보 없음';
        }
        String reportCode = String.isBlank(externalKey) || externalKey.length() < 5
            ? null : externalKey.right(5);
        String month;
        if ('11013'.equals(reportCode) || '1분기'.equals(periodType)) {
            month = '03';
        } else if ('11012'.equals(reportCode) || '2분기'.equals(periodType)) {
            month = '06';
        } else if ('11014'.equals(reportCode) || '3분기'.equals(periodType)) {
            month = '09';
        } else if ('11011'.equals(reportCode) || '4분기'.equals(periodType) || '사업보고서'.equals(periodType)) {
            month = '12';
        } else {
            return String.valueOf(fiscalYear.intValue());
        }
        return String.valueOf(fiscalYear.intValue()) + '/' + month;
    }

    private static String formatWon(Decimal amount) {
        if (amount == null) {
            return '정보 없음';
        }
        Decimal inEok = (amount / 100000000L).setScale(1);
        return inEok.toPlainString().replaceAll('\\.0$', '') + '억 원';
    }

    private static void saveOpportunityBriefing(Id recordId, String briefingText) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            WITH USER_MODE
            LIMIT 50
        ];
        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            documentIds.add(link.ContentDocumentId);
        }

        List<ContentNote> notes = documentIds.isEmpty()
            ? new List<ContentNote>()
            : [
                SELECT Id, Title
                FROM ContentNote
                WHERE Id IN :documentIds AND Title = :OPPORTUNITY_NOTE_TITLE
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT 1
            ];
        if (!notes.isEmpty()) {
            notes[0].Content = Blob.valueOf(briefingText);
            update as user notes[0];
            return;
        }

        ContentNote note = new ContentNote(
            Title = OPPORTUNITY_NOTE_TITLE,
            Content = Blob.valueOf(briefingText)
        );
        insert as user note;
        ContentDocumentLink link = new ContentDocumentLink(
            ContentDocumentId = note.Id,
            LinkedEntityId = recordId,
            // Opportunity edit access determines whether the linked briefing can be updated.
            ShareType = 'I'
        );
        insert as user link;
    }

    private static Boolean isOpportunity(Id recordId) {
        return recordId != null && recordId.getSObjectType() == Opportunity.SObjectType;
    }

    @TestVisible
    private static String invokePromptTemplate(Id recordId) {
        if (Test.isRunningTest()) {
            return testResponseOverride;
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        ConnectApi.EinsteinLlmAdditionalConfigInput config =
            new ConnectApi.EinsteinLlmAdditionalConfigInput();
        config.applicationName = 'PromptTemplateGenerationsInvocable';
        input.additionalConfig = config;
        input.isPreview = false;

        ConnectApi.WrappedValue recordValue = new ConnectApi.WrappedValue();
        String inputName;
        if (isOpportunity(recordId)) {
            recordValue.value = String.valueOf(recordId);
            inputName = 'Input:RelatedOpportunity';
        } else {
            recordValue.value = new Map<String, Object>{ 'id' => recordId };
            inputName = 'Input:RelatedLead';
        }
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ inputName => recordValue };
        String templateName = isOpportunity(recordId)
            ? 'Opportunity_Meeting_Prep_Briefing_Primitive'
            : TEMPLATE_API_NAME;
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateName, input);
        if (response != null && response.generations != null && !response.generations.isEmpty()) {
            return response.generations[0].text;
        }
        return null;
    }
}