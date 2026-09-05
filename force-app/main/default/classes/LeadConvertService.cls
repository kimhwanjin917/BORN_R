/**
 * Invocable Apex action that converts a Lead and wires up the resulting records.
 * Callable from Flows, Process Builder, and Agentforce.
 *
 * For each request it:
 *  - Converts the Lead via Database.convertLead (creates Account, Contact, Opportunity)
 *  - Fills the Opportunity's RecordType, 기준 상품, and Name ("{회사명} - {상품군}")
 *  - Creates a "고객 미팅" Event on the new Opportunity (WhatId) and Contact (WhoId)
 *  - Re-points related CorporateFinancialStatement__c / ExternalSignal__c records to the new Account
 *  - Transfers Lead fields to the new Account (Priority_Score always; the two
 *    external-id fields only when the Account value is blank)
 *
 * Accepts a bulkified List&lt;Request&gt; and returns a parallel List&lt;Response&gt;.
 */
public with sharing class LeadConvertService {

    private static final String EVENT_SUBJECT = '고객 미팅';

    // ADR-0001: Lead.Recommended_Product_Family__c → Opportunity RecordType DeveloperName.
    // 비어 있거나 매핑에 없으면 DEFAULT_OPP_RECORD_TYPE(RP Deal).
    @TestVisible
    private static final Map<String, String> OPP_RECORD_TYPE_BY_FAMILY = new Map<String, String>{
        'RP' => 'RP_Deal',
        '회사채' => 'Deal'
    };
    @TestVisible
    private static final String DEFAULT_OPP_RECORD_TYPE = 'RP_Deal';

    // 위 매핑의 역방향. 표준 Convert 화면은 RM 이 Opportunity RecordType 을 직접 고르는데,
    // 그 선택에서 상품군을 되짚어 이름·기준 상품을 맞춘다 (추천값이 아니라 고른 RT 기준).
    @TestVisible
    private static final Map<String, String> RECOMMENDATION_BY_OPP_RECORD_TYPE = new Map<String, String>{
        'RP_Deal' => 'RP',
        'Deal' => '회사채'
    };

    // docs/51: 추천 상품군 → Product2.Family. 전환된 Opportunity 의 기준 상품(Primary_Product__c)을
    // 같은 상품군의 대표 상품으로 채운다. Product_Family__c 는 Formula 라 자동으로 따라온다.
    @TestVisible
    private static final Map<String, String> PRODUCT_FAMILY_BY_RECOMMENDATION = new Map<String, String>{
        'RP' => 'RP',
        '회사채' => '채권'
    };

    // 상품군의 대표 상품명. 예전에는 '활성 상품 중 이름순 첫 번째'였는데, 한글이 라틴 문자보다
    // 먼저 정렬되는 탓에 RP 대표가 '외화 RP (USD) 30일물' 로 잡혔다. 기준 상품은 유사 Won 집계·
    // 기회 레이더·지갑 점유율의 기준이라 정렬 우연에 맡기지 않고 명시한다.
    @TestVisible
    private static final Map<String, String> REPRESENTATIVE_PRODUCT_BY_FAMILY = new Map<String, String>{
        'RP' => 'RP (환매조건부채권)',
        '채권' => '회사채'
    };
    @TestVisible
    private static final String DEFAULT_RECOMMENDATION = 'RP';

    // Opportunity.Name 의 표준 길이 제한.
    private static final Integer OPP_NAME_MAX_LENGTH = 120;

    // ─── Invocable Method ────────────────────────────────────────────────

    /**
     * Converts each supplied Lead and returns the created Opportunity Id.
     * @param requests List of Request inputs from the calling Flow
     * @return List of Response outputs, one per request, in the same order
     */
    @InvocableMethod(
        label='Convert Lead and Schedule Meeting'
        description='Converts a Lead, creates a meeting Event on the new Opportunity, reconnects external data, and transfers fields to the new Account.'
        category='Lead Management'
    )
    public static List<Response> convertLeads(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        // A Response placeholder is created per request so ordering is preserved.
        Map<Integer, Response> responsesByIndex = new Map<Integer, Response>();
        Set<Id> leadIds = new Set<Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            Response res = new Response();
            responsesByIndex.put(i, res);
            responses.add(res);

            Request req = requests[i];
            if (req == null || req.leadId == null) {
                res.isSuccess = false;
                res.errorMessage = 'leadId is required.';
                res.errorType = 'VALIDATION';
            } else if (req.meetingDateTime == null) {
                res.isSuccess = false;
                res.errorMessage = 'meetingDateTime is required.';
                res.errorType = 'VALIDATION';
            } else {
                leadIds.add(req.leadId);
            }
        }

        if (leadIds.isEmpty()) {
            return responses;
        }

        Map<Id, Lead> leadsById = new Map<Id, Lead>([
            SELECT Id, Priority_Score__c, Business_Registration_Number__c, Assigned_Company_Code__c,
                Recommended_Product_Family__c, Proposed_Yield_Rate__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH USER_MODE
        ]);

        String convertedStatus = getConvertedStatus();

        // Build one LeadConvert per valid, still-open request; track which
        // response each maps to so results can be reported back in order.
        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>();
        List<Integer> conversionIndexes = new List<Integer>();
        for (Integer i = 0; i < requests.size(); i++) {
            Response res = responsesByIndex.get(i);
            if (res.isSuccess == false) {
                continue; // already failed validation
            }
            Id leadId = requests[i].leadId;
            if (!leadsById.containsKey(leadId)) {
                res.isSuccess = false;
                res.errorMessage = 'Lead not found or not accessible: ' + leadId;
                res.errorType = 'NOT_FOUND';
                continue;
            }
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(leadId);
            lc.setConvertedStatus(convertedStatus);
            conversions.add(lc);
            conversionIndexes.add(i);
        }

        if (conversions.isEmpty()) {
            return responses;
        }

        // 이 경로(「미팅 확정」·활동 이벤트 자동 전환)에는 RecordType 을 고를 화면이 없다.
        // 그래서 아래 LeadConvertedTrigger 가 추천 상품군으로 RecordType 을 정해 준다.
        // 표준 Convert 화면에서 온 전환은 RM 이 이미 골랐으므로 그 선택을 덮지 않는다.
        List<Database.LeadConvertResult> convertResults;
        codePathConversion = true;
        try {
            convertResults = Database.convertLead(conversions, false);
        } finally {
            codePathConversion = false;
        }

        // Gather the created record Ids for the successful conversions.
        Map<Id, Id> accountIdByLeadId = new Map<Id, Id>();
        Map<Id, Id> contactIdByLeadId = new Map<Id, Id>();
        Map<Id, Id> opportunityIdByLeadId = new Map<Id, Id>();
        for (Integer c = 0; c < convertResults.size(); c++) {
            Database.LeadConvertResult result = convertResults[c];
            Integer requestIndex = conversionIndexes[c];
            Response res = responsesByIndex.get(requestIndex);
            Id leadId = requests[requestIndex].leadId;

            if (result.isSuccess()) {
                res.isSuccess = true;
                res.opportunityId = result.getOpportunityId();
                accountIdByLeadId.put(leadId, result.getAccountId());
                contactIdByLeadId.put(leadId, result.getContactId());
                opportunityIdByLeadId.put(leadId, result.getOpportunityId());
            } else {
                res.isSuccess = false;
                res.errorMessage = formatErrors(result.getErrors());
                res.errorType = 'CONVERSION_FAILED';
            }
        }

        if (accountIdByLeadId.isEmpty()) {
            return responses;
        }

        // Opportunity 기본값과 재무·시그널 재연결은 LeadConvertedTrigger 가 이미 처리했다
        // (Database.convertLead 가 Lead 를 업데이트하면서 발화). 여기서 다시 부르면
        // 같은 레코드를 두 번 쓴다.
        createMeetingEvents(requests, conversionIndexes, responsesByIndex,
            contactIdByLeadId, opportunityIdByLeadId);
        transferLeadFieldsToAccounts(leadsById, accountIdByLeadId);

        return responses;
    }

    // ─── Trigger Entry Point ─────────────────────────────────────────────

    /**
     * Applies the Opportunity defaults for Leads that were just converted, whatever
     * converted them: the standard Convert button, the API, 「미팅 확정」, or the
     * Event trigger. Called from LeadConvertedTrigger (Lead after update), which is
     * the one point every conversion path passes through.
     *
     * Failures never block the conversion — the Opportunity already exists by this
     * point, so a naming problem is logged rather than thrown.
     *
     * @param updatedLeads Trigger.new
     * @param oldLeadsById Trigger.oldMap
     */
    public static void applyDefaultsForConvertedLeads(
        List<Lead> updatedLeads,
        Map<Id, Lead> oldLeadsById
    ) {
        if (defaultsInProgress) {
            return; // our own Opportunity update must not re-enter
        }
        Map<Id, Lead> leadsById = new Map<Id, Lead>();
        Map<Id, Id> opportunityIdByLeadId = new Map<Id, Id>();
        Map<Id, Id> accountIdByLeadId = new Map<Id, Id>();
        for (Lead updated : updatedLeads) {
            Lead previous = oldLeadsById == null ? null : oldLeadsById.get(updated.Id);
            Boolean justConverted = updated.IsConverted == true
                && (previous == null || previous.IsConverted != true);
            if (!justConverted
                || updated.ConvertedOpportunityId == null
                || updated.ConvertedAccountId == null) {
                continue;
            }
            leadsById.put(updated.Id, updated);
            opportunityIdByLeadId.put(updated.Id, updated.ConvertedOpportunityId);
            accountIdByLeadId.put(updated.Id, updated.ConvertedAccountId);
        }
        if (opportunityIdByLeadId.isEmpty()) {
            return;
        }
        defaultsInProgress = true;
        try {
            applyOpportunityDefaults(leadsById, opportunityIdByLeadId, accountIdByLeadId);
            // 재무·시그널 재연결은 모든 전환 경로(표준 Convert 버튼·API 포함)가 지나는
            // 이 트리거 지점에서 한다. 예전에는 convertLeads Invocable 안에서만 돌아
            // 표준 Convert 로 전환한 리드의 시그널이 Account 로 옮겨오지 못했다.
            reconnectExternalRecords(accountIdByLeadId.keySet(), accountIdByLeadId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Opportunity defaults skipped after conversion: ' + e.getMessage());
        } finally {
            defaultsInProgress = false;
        }
    }

    private static Boolean defaultsInProgress = false;

    // convertLeads Invocable 이 돌린 전환인지 표시한다. true 면 RecordType 을 고를 화면이
    // 없었다는 뜻이라 추천 상품군으로 정해 주고, false(표준 Convert 버튼·API)면 이미 붙어
    // 있는 RecordType 이 RM 의 선택이므로 그대로 둔다.
    @TestVisible
    private static Boolean codePathConversion = false;

    // ─── Private Helpers ─────────────────────────────────────────────────

    /**
     * Fills in what Database.convertLead cannot set on the created Opportunity:
     * RecordType and 기준 상품 from the source Lead's 추천 상품군 (ADR-0001), and a
     * deal-shaped Name ("{Account 명} - {기준 상품명}") in place of the bare Account
     * name convertLead leaves behind. Each part is skipped independently when it
     * cannot be resolved, so a missing RecordType or Product2 never blocks the rest.
     * @param leadsById Source Leads keyed by Id
     * @param opportunityIdByLeadId Created Opportunity Id keyed by Lead Id
     * @param accountIdByLeadId Converted Account Id keyed by Lead Id
     */
    @TestVisible
    private static void applyOpportunityDefaults(
        Map<Id, Lead> leadsById,
        Map<Id, Id> opportunityIdByLeadId,
        Map<Id, Id> accountIdByLeadId
    ) {
        Map<String, Schema.RecordTypeInfo> rtByDevName =
            Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName();
        Map<String, Product2> productByFamily = queryDefaultProductByFamily();
        Map<Id, String> accountNameById = queryAccountNames(accountIdByLeadId.values());
        // 표준 Convert 화면 경로에서만 필요하다 — RM 이 고른 RecordType 을 읽기 위해서.
        Map<Id, Opportunity> createdOpps = codePathConversion
            ? new Map<Id, Opportunity>()
            : queryOpportunityRecordTypes(opportunityIdByLeadId.values());
        List<Opportunity> updates = new List<Opportunity>();
        for (Id leadId : opportunityIdByLeadId.keySet()) {
            Lead sourceLead = leadsById.get(leadId);
            Id opportunityId = opportunityIdByLeadId.get(leadId);
            String recommendation = sourceLead == null ? null : sourceLead.Recommended_Product_Family__c;
            if (!OPP_RECORD_TYPE_BY_FAMILY.containsKey(recommendation)) {
                recommendation = DEFAULT_RECOMMENDATION;
            }
            Opportunity opp = new Opportunity(Id = opportunityId);
            Boolean changed = false;

            // 표준 Convert 화면에서 RP Deal 을 골랐는데 추천이 회사채라는 이유로 회사채 딜이
            // 되던 문제(2026-09-01). RM 이 고른 RecordType 이 추천값보다 우선이다. 이름·기준
            // 상품도 고른 RT 에서 되짚은 상품군으로 맞춰 셋이 서로 어긋나지 않게 한다.
            Opportunity created = createdOpps.get(opportunityId);
            if (created != null && created.RecordTypeId != null) {
                String chosen = created.RecordType == null
                    ? null
                    : RECOMMENDATION_BY_OPP_RECORD_TYPE.get(created.RecordType.DeveloperName);
                if (String.isNotBlank(chosen)) {
                    recommendation = chosen;
                }
                // RecordTypeId 는 건드리지 않는다 — 매핑에 없는 RT 라도 RM 의 선택이다.
            } else {
                Schema.RecordTypeInfo rt = rtByDevName.get(OPP_RECORD_TYPE_BY_FAMILY.get(recommendation));
                if (rt != null && rt.isAvailable()) {
                    opp.RecordTypeId = rt.getRecordTypeId();
                    changed = true;
                }
            }
            Product2 product = productByFamily.get(PRODUCT_FAMILY_BY_RECOMMENDATION.get(recommendation));
            if (product != null) {
                opp.Primary_Product__c = product.Id; // 기준 상품 — 미팅 중 추천·유사 Won 의 기준
                changed = true;
            }
            // 제안서에 실어 보낸 조건을 딜로 넘긴다. 넘기지 않으면 RM 이 미팅 후 딜에서
            // 같은 값을 처음부터 다시 입력해야 하고, "얼마로 제안했는지"가 PDF 안에만 남는다.
            // 미팅 결과로 조건이 바뀌면 RM 이 딜에서 고치면 된다 — 여기서는 출발값만 준다.
            if (sourceLead != null && sourceLead.Proposed_Yield_Rate__c != null) {
                opp.RP_Yield__c = sourceLead.Proposed_Yield_Rate__c;
                changed = true;
            }

            // 이름에는 구체 상품이 아니라 상품군을 쓴다 (RP / 회사채). 구체 상품은
            // Primary_Product__c 가 들고 있고, 이름까지 특정 상품으로 못 박으면 실제
            // 딜과 어긋나기 쉽다. 회사명을 못 읽으면 convertLead 가 넣어 둔 이름을 둔다.
            String accountName = accountNameById.get(accountIdByLeadId.get(leadId));
            if (String.isNotBlank(accountName)) {
                opp.Name = buildOpportunityName(accountName, recommendation);
                changed = true;
            }
            if (changed) {
                updates.add(opp);
            }
        }
        if (updates.isEmpty()) {
            return;
        }
        // 이 시점엔 Opportunity 가 이미 만들어져 있다. 이름·기준 상품을 못 채우는 것이
        // 전환 자체를 되돌리는 것보다 낫기 때문에 건별 실패를 허용하고 로그만 남긴다.
        for (Database.SaveResult sr : Database.update(updates, false, AccessLevel.USER_MODE)) {
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'Opportunity defaults not applied to ' + sr.getId() + ': '
                    + formatErrors(sr.getErrors()));
            }
        }
    }

    /**
     * "{회사명} - {상품군}", truncated to the 120-character Opportunity.Name limit.
     * @param accountName Converted Account name
     * @param productFamily 추천 상품군 (RP / 회사채)
     * @return Assembled Opportunity name
     */
    @TestVisible
    private static String buildOpportunityName(String accountName, String productFamily) {
        String assembled = accountName + ' - ' + productFamily;
        return assembled.length() > OPP_NAME_MAX_LENGTH
            ? assembled.left(OPP_NAME_MAX_LENGTH)
            : assembled;
    }

    /**
     * RecordType just assigned to each created Opportunity. Only the standard Convert
     * screen lets the RM pick one, so this is queried only on that path — 「미팅 확정」
     * 같은 코드 경로에서는 고른 값이 없어 조회할 이유가 없다.
     *
     * 조회가 막히면(FLS·공유) 빈 Map 을 돌려준다. 그러면 호출부는 추천 상품군 기준의
     * 예전 동작으로 떨어질 뿐, 전환 자체는 막지 않는다.
     * @param opportunityIds Created Opportunity Ids
     * @return Opportunity(Id, RecordTypeId, RecordType.DeveloperName) keyed by Id
     */
    private static Map<Id, Opportunity> queryOpportunityRecordTypes(List<Id> opportunityIds) {
        Map<Id, Opportunity> oppById = new Map<Id, Opportunity>();
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return oppById;
        }
        try {
            for (Opportunity opp : [
                SELECT Id, RecordTypeId, RecordType.DeveloperName
                FROM Opportunity
                WHERE Id IN :opportunityIds
                WITH USER_MODE
            ]) {
                oppById.put(opp.Id, opp);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Opportunity RecordTypes not readable: ' + e.getMessage());
        }
        return oppById;
    }

    /**
     * Account names for the converted Accounts. convertLead can attach to an
     * existing Account, so the stored name is read back rather than assuming Lead.Company.
     * @param accountIds Converted Account Ids
     * @return Account Name keyed by Id; empty when the query is not permitted
     */
    private static Map<Id, String> queryAccountNames(List<Id> accountIds) {
        Map<Id, String> nameById = new Map<Id, String>();
        if (accountIds == null || accountIds.isEmpty()) {
            return nameById;
        }
        try {
            for (Account a : [
                SELECT Id, Name FROM Account WHERE Id IN :accountIds WITH USER_MODE
            ]) {
                nameById.put(a.Id, a.Name);
            }
        } catch (QueryException e) {
            System.debug(LoggingLevel.WARN, 'Account name lookup skipped: ' + e.getMessage());
        }
        return nameById;
    }

    /**
     * Active Product2 per Family (first by Name) for the families the conversion can map to.
     * Missing FLS/objects simply yield an empty map (기준 상품 미설정, RT 만 반영).
     */
    private static Map<String, Product2> queryDefaultProductByFamily() {
        Map<String, Product2> productByFamily = new Map<String, Product2>();
        Set<String> families = new Set<String>(PRODUCT_FAMILY_BY_RECOMMENDATION.values());
        Set<String> representatives = new Set<String>(REPRESENTATIVE_PRODUCT_BY_FAMILY.values());
        try {
            for (Product2 p : [
                SELECT Id, Name, Family FROM Product2
                WHERE IsActive = true AND Family IN :families
                WITH USER_MODE
                ORDER BY Family, Name
            ]) {
                // 대표 상품이 있으면 그것을 쓰고, 그 상품이 비활성/삭제됐을 때만
                // 같은 상품군의 아무 활성 상품으로 물러선다.
                Boolean isRepresentative = representatives.contains(p.Name)
                    && REPRESENTATIVE_PRODUCT_BY_FAMILY.get(p.Family) == p.Name;
                if (isRepresentative || !productByFamily.containsKey(p.Family)) {
                    productByFamily.put(p.Family, p);
                }
            }
        } catch (QueryException e) {
            System.debug(LoggingLevel.WARN, 'Product2 lookup skipped: ' + e.getMessage());
        }
        return productByFamily;
    }

    /**
     * Resolves a converted Lead status, preferring the default converted status.
     * @return MasterLabel of a converted LeadStatus
     * @throws LeadConvertServiceException when no converted status is configured
     */
    private static String getConvertedStatus() {
        List<LeadStatus> statuses = [
            SELECT ApiName, MasterLabel
            FROM LeadStatus
            WHERE IsConverted = true
            WITH USER_MODE
            ORDER BY IsDefault DESC
            LIMIT 1
        ];
        if (statuses.isEmpty()) {
            throw new LeadConvertServiceException('No converted LeadStatus is configured in this org.');
        }
        // setConvertedStatus 는 ApiName 을 요구한다. MasterLabel 은 관리자가 표시명을
        // 바꾸는 순간 (예: Converted → '전환 완료') 어긋나 전환이 전부 실패한다.
        return String.isNotBlank(statuses[0].ApiName)
            ? statuses[0].ApiName
            : statuses[0].MasterLabel;
    }

    /**
     * Creates a "고객 미팅" Event for each successful conversion.
     * @param requests Original requests (source of meetingDateTime)
     * @param conversionIndexes Request indexes that were submitted for conversion
     * @param responsesByIndex Responses keyed by request index
     * @param contactIdByLeadId Created Contact Id keyed by Lead Id
     * @param opportunityIdByLeadId Created Opportunity Id keyed by Lead Id
     */
    private static void createMeetingEvents(
        List<Request> requests,
        List<Integer> conversionIndexes,
        Map<Integer, Response> responsesByIndex,
        Map<Id, Id> contactIdByLeadId,
        Map<Id, Id> opportunityIdByLeadId
    ) {
        List<Event> events = new List<Event>();
        for (Integer requestIndex : conversionIndexes) {
            Response res = responsesByIndex.get(requestIndex);
            if (res.isSuccess != true) {
                continue;
            }
            Request req = requests[requestIndex];
            if (req.createMeetingEvent == false) {
                continue; // caller keeps its own Event as the meeting record
            }
            Id opportunityId = opportunityIdByLeadId.get(req.leadId);
            events.add(new Event(
                Subject = EVENT_SUBJECT,
                WhatId = opportunityId,
                WhoId = contactIdByLeadId.get(req.leadId),
                StartDateTime = req.meetingDateTime,
                DurationInMinutes = 60
            ));
        }
        if (!events.isEmpty()) {
            insert as user events;
        }
    }

    /**
     * Copies Lead field values onto the created Accounts. Priority_Score__c is
     * always overwritten; the two external-id fields are set only when blank.
     * @param leadsById Source Leads keyed by Id
     * @param accountIdByLeadId Created Account Id keyed by Lead Id
     */
    private static void transferLeadFieldsToAccounts(
        Map<Id, Lead> leadsById,
        Map<Id, Id> accountIdByLeadId
    ) {
        Map<Id, Id> leadIdByAccountId = new Map<Id, Id>();
        for (Id leadId : accountIdByLeadId.keySet()) {
            leadIdByAccountId.put(accountIdByLeadId.get(leadId), leadId);
        }

        Map<Id, Account> accountsById = new Map<Id, Account>([
            SELECT Id, Priority_Score__c, Business_Registration_Number__c, Assigned_Company_Code__c
            FROM Account
            WHERE Id IN :leadIdByAccountId.keySet()
            WITH USER_MODE
        ]);

        List<Account> accountsToUpdate = new List<Account>();
        for (Account acc : accountsById.values()) {
            Lead sourceLead = leadsById.get(leadIdByAccountId.get(acc.Id));
            if (sourceLead == null) {
                continue;
            }
            acc.Priority_Score__c = sourceLead.Priority_Score__c;
            if (String.isBlank(acc.Business_Registration_Number__c)) {
                acc.Business_Registration_Number__c = sourceLead.Business_Registration_Number__c;
            }
            if (String.isBlank(acc.Assigned_Company_Code__c)) {
                acc.Assigned_Company_Code__c = sourceLead.Assigned_Company_Code__c;
            }
            accountsToUpdate.add(acc);
        }
        if (!accountsToUpdate.isEmpty()) {
            update as user accountsToUpdate;
        }
    }

    /**
     * Re-points CorporateFinancialStatement__c and ExternalSignal__c records
     * whose Lead__c matches a converted Lead to the newly created Account.
     * @param leadIds Converted Lead Ids
     * @param accountIdByLeadId Created Account Id keyed by Lead Id
     */
    private static void reconnectExternalRecords(Set<Id> leadIds, Map<Id, Id> accountIdByLeadId) {
        List<SObject> recordsToUpdate = new List<SObject>();

        for (CorporateFinancialStatement__c statement : [
            SELECT Id, Lead__c, Account__c
            FROM CorporateFinancialStatement__c
            WHERE Lead__c IN :leadIds
            WITH USER_MODE
        ]) {
            statement.Account__c = accountIdByLeadId.get(statement.Lead__c);
            recordsToUpdate.add(statement);
        }

        for (ExternalSignal__c signal : [
            SELECT Id, Lead__c, Account__c
            FROM ExternalSignal__c
            WHERE Lead__c IN :leadIds
            WITH USER_MODE
        ]) {
            signal.Account__c = accountIdByLeadId.get(signal.Lead__c);
            recordsToUpdate.add(signal);
        }

        if (!recordsToUpdate.isEmpty()) {
            update as user recordsToUpdate;
        }
    }

    /**
     * Joins database error messages into a single string.
     * @param errors Errors from a Database result
     * @return Concatenated error messages
     */
    private static String formatErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getMessage());
        }
        return String.join(messages, '; ');
    }

    // ─── Request / Response DTOs ─────────────────────────────────────────

    /**
     * Input parameters from the calling Flow.
     */
    public class Request {
        @InvocableVariable(label='Lead Id' description='The Id of the Lead to convert' required=true)
        public Id leadId;

        @InvocableVariable(label='Meeting Date/Time' description='Start date and time of the customer meeting' required=true)
        public Datetime meetingDateTime;

        @InvocableVariable(label='Create Meeting Event' description='When false, skips creating the meeting Event (caller supplies its own). Defaults to true when null.')
        public Boolean createMeetingEvent;
    }

    /**
     * Output results returned to the calling Flow.
     */
    public class Response {
        @InvocableVariable(label='Opportunity Id' description='Id of the Opportunity created by the conversion')
        public Id opportunityId;

        @InvocableVariable(label='Success' description='Whether the conversion succeeded')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message' description='Error details if the conversion failed')
        public String errorMessage;

        @InvocableVariable(label='Error Type' description='Category of the failure if the conversion failed')
        public String errorType;
    }

    /**
     * Domain exception for Lead conversion failures.
     */
    public class LeadConvertServiceException extends Exception {}
}