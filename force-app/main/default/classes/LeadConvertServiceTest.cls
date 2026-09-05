/**
 * Test class for LeadConvertService.
 * Exercises the invocable boundary: after invocation it verifies the
 * Opportunity and Event (WhatId) are created, external data is reconnected,
 * and Lead fields are transferred to the new Account.
 */
@isTest
private class LeadConvertServiceTest {

    private static final Decimal LEAD_PRIORITY = 42;
    private static final String LEAD_BRN = '1234567890';
    private static final String LEAD_COMPANY_CODE = 'CODE-001';
    private static final String TEST_USER_NAME = 'lcs.tester@leadconvert.test.example.com';

    @TestSetup
    static void setupTestData() {
        // The production service runs its queries WITH USER_MODE, so the running
        // user must hold FLS on the custom fields it reads/writes. Build a
        // self-contained permission set granting exactly that, and run the
        // service as a dedicated user carrying it.
        User testUser = createTestUser();
        assignFlsPermissionSet(testUser.Id);

        // Data DML must be isolated from the setup-object DML above to avoid
        // MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Lead lead = new Lead(
                LastName = 'Kim',
                FirstName = 'Test',
                Company = 'Acme Corp',
                Status = 'Open - Not Contacted',
                // Industry/Email are carried by the standard conversion mapping to
                // Account.Industry / Contact.Email, satisfying the org's active
                // Required_PL (Account) and Required (Contact) validation rules.
                Industry = 'Insurance',
                Email = 'lead.tester@leadconvert.test.example.com',
                // Required Text(10) field; carried by the standard conversion
                // mapping to Contact.name_new__c (also required).
                name_new__c = '김담당',
                Priority_Score__c = LEAD_PRIORITY,
                Business_Registration_Number__c = LEAD_BRN,
                Assigned_Company_Code__c = LEAD_COMPANY_CODE
            );
            insert lead;

            insert new CorporateFinancialStatement__c(Lead__c = lead.Id);
            insert new ExternalSignal__c(Lead__c = lead.Id);

            // 기준 상품 후보 (docs/51): 상품군별 활성 상품
            insert new List<Product2>{
                new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true),
                new Product2(Name = '회사채', Family = '채권', IsActive = true)
            };
        }
    }

    /**
     * Creates a System Administrator test user. The admin profile supplies
     * Convert Leads plus CRUD on the standard objects the conversion touches;
     * the permission set added separately supplies custom-field FLS.
     */
    private static User createTestUser() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User u = new User(
            FirstName = 'LCS',
            LastName = 'Tester',
            Email = 'lcs.tester@leadconvert.test.example.com',
            Username = TEST_USER_NAME,
            Alias = 'lcstest',
            ProfileId = admin.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    /**
     * Builds a permission set that grants FLS on every custom field the service
     * reads or writes under USER_MODE, plus object access to the two external
     * custom objects, then assigns it to the given user.
     */
    private static void assignFlsPermissionSet(Id userId) {
        PermissionSet ps = new PermissionSet(
            Name = 'LCS_Test_Fls',
            Label = 'LCS Test FLS'
        );
        insert ps;

        insert new List<ObjectPermissions>{
            newObjectPerm(ps.Id, 'CorporateFinancialStatement__c'),
            newObjectPerm(ps.Id, 'ExternalSignal__c')
        };

        insert new List<FieldPermissions>{
            // Lead fields are read-only for the service.
            newFieldPerm(ps.Id, 'Lead', 'Lead.Priority_Score__c', false),
            newFieldPerm(ps.Id, 'Lead', 'Lead.Business_Registration_Number__c', false),
            newFieldPerm(ps.Id, 'Lead', 'Lead.Assigned_Company_Code__c', false),
            newFieldPerm(ps.Id, 'Lead', 'Lead.Recommended_Product_Family__c', false),
            newFieldPerm(ps.Id, 'Lead', 'Lead.Proposed_Yield_Rate__c', false),
            newFieldPerm(ps.Id, 'Opportunity', 'Opportunity.Primary_Product__c', true),
            newFieldPerm(ps.Id, 'Opportunity', 'Opportunity.RP_Yield__c', true),
            // Account fields are read and written. Business_Registration_Number__c
            // is a required (non-nillable) field, so its FLS is implicit and
            // cannot be granted via FieldPermissions — it is omitted here.
            newFieldPerm(ps.Id, 'Account', 'Account.Priority_Score__c', true),
            newFieldPerm(ps.Id, 'Account', 'Account.Assigned_Company_Code__c', true),
            // External-object fields: Lead__c is read (SELECT + WHERE filter under
            // USER_MODE), Account__c is read + written.
            newFieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Lead__c', false),
            newFieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Account__c', true),
            newFieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Lead__c', false),
            newFieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Account__c', true)
        };

        insert new PermissionSetAssignment(
            AssigneeId = userId,
            PermissionSetId = ps.Id
        );
    }

    private static ObjectPermissions newObjectPerm(Id parentId, String sobjectType) {
        return new ObjectPermissions(
            ParentId = parentId,
            SobjectType = sobjectType,
            PermissionsRead = true,
            PermissionsViewAllRecords = true,
            PermissionsEdit = true
        );
    }

    private static FieldPermissions newFieldPerm(Id parentId, String sobjectType, String field, Boolean allowEdit) {
        return new FieldPermissions(
            ParentId = parentId,
            SobjectType = sobjectType,
            Field = field,
            PermissionsRead = true,
            PermissionsEdit = allowEdit
        );
    }

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Username = :TEST_USER_NAME LIMIT 1];
    }

    // ─── Positive Tests ───────────────────────────────────────────────────

    @isTest
    static void shouldConvertLeadAndReturnOpportunityId_WhenValidInput() {
        // Given
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 10, 0, 0);

        // When
        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Test.stopTest();

        // Then
        Assert.areEqual(1, responses.size(), 'One response per request expected');
        LeadConvertService.Response res = responses[0];
        Assert.isTrue(res.isSuccess, 'Conversion should succeed: ' + res.errorMessage);
        Assert.isNotNull(res.opportunityId, 'Opportunity Id should be returned');

        Opportunity opp = [SELECT Id, AccountId FROM Opportunity WHERE Id = :res.opportunityId];
        Assert.isNotNull(opp.AccountId, 'Opportunity should be linked to the new Account');
    }

    // ─── ADR-0001: Opportunity RecordType from 추천 상품군 ─────────────────

    private static String convertAndGetOppRecordType(String family) {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            lead.Recommended_Product_Family__c = family;
            update lead;
        }
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 10, 0, 0);

        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Test.stopTest();
        Assert.isTrue(responses[0].isSuccess, 'Conversion should succeed: ' + responses[0].errorMessage);
        Opportunity created = [
            SELECT Name, RecordType.DeveloperName, Primary_Product__c,
                   Primary_Product__r.Name, Primary_Product__r.Family
            FROM Opportunity WHERE Id = :responses[0].opportunityId
        ];
        lastPrimaryProductFamily = created.Primary_Product__c == null
            ? null
            : created.Primary_Product__r.Family;
        lastPrimaryProductName = created.Primary_Product__c == null
            ? null
            : created.Primary_Product__r.Name;
        lastOpportunityName = created.Name;
        return created.RecordType.DeveloperName;
    }
    private static String lastPrimaryProductFamily;
    private static String lastPrimaryProductName;
    private static String lastOpportunityName;

    @isTest
    static void shouldCreateRpDealOpportunity_WhenFamilyIsRP() {
        Assert.areEqual('RP_Deal', convertAndGetOppRecordType('RP'));
        Assert.areEqual('RP', lastPrimaryProductFamily, '기준 상품 = RP 상품군');
    }

    @isTest
    static void shouldCreateBondDealOpportunity_WhenFamilyIsBond() {
        Assert.areEqual('Deal', convertAndGetOppRecordType('회사채'));
        Assert.areEqual('채권', lastPrimaryProductFamily, '기준 상품 = 채권 상품군');
    }

    // ─── 표준 Convert 화면: RM 이 고른 RecordType 이 추천보다 우선 (2026-09-01) ──

    /**
     * 표준 Convert 화면은 Database.convertLead 로 그대로 재현할 수 없다 — RecordType 을
     * 지정하는 API 가 없어 화면만 지정할 수 있기 때문이다. 그래서 전환된 Opportunity 의
     * RecordType 을 RM 이 고른 값으로 바꿔 놓고, 화면 경로와 같은 조건(codePathConversion
     * = false)에서 기본값 채우기를 다시 태워 검증한다.
     */
    @isTest
    static void shouldKeepUserChosenRecordType_WhenConvertedFromStandardScreen() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            lead.Recommended_Product_Family__c = '회사채'; // 추천은 회사채
            update lead;
        }
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 10, 0, 0);

        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Assert.isTrue(responses[0].isSuccess, 'Conversion should succeed: ' + responses[0].errorMessage);
        Id opportunityId = responses[0].opportunityId;

        // RM 이 화면에서 RP Deal 을 고른 상태를 만든다.
        Id rpDealRtId = Schema.SObjectType.Opportunity
            .getRecordTypeInfosByDeveloperName()
            .get('RP_Deal')
            .getRecordTypeId();
        update new Opportunity(Id = opportunityId, RecordTypeId = rpDealRtId);

        Lead converted = [
            SELECT Id, ConvertedAccountId, Recommended_Product_Family__c, Proposed_Yield_Rate__c
            FROM Lead WHERE Id = :lead.Id
        ];
        System.runAs(getTestUser()) {
            LeadConvertService.applyOpportunityDefaults(
                new Map<Id, Lead>{ converted.Id => converted },
                new Map<Id, Id>{ converted.Id => opportunityId },
                new Map<Id, Id>{ converted.Id => converted.ConvertedAccountId }
            );
        }
        Test.stopTest();

        Opportunity result = [
            SELECT Name, RecordType.DeveloperName, Primary_Product__r.Family
            FROM Opportunity WHERE Id = :opportunityId
        ];
        Assert.areEqual('RP_Deal', result.RecordType.DeveloperName,
            '화면에서 고른 RecordType 은 추천이 회사채여도 유지돼야 한다');
        Assert.areEqual('Acme Corp - RP', result.Name,
            '이름은 고른 RecordType 에서 되짚은 상품군을 따라야 한다');
        Assert.areEqual('RP', result.Primary_Product__r.Family,
            '기준 상품도 고른 RecordType 기준이어야 한다');
    }

    /**
     * 역매핑이 정매핑과 어긋나면 화면에서 고른 RT 가 엉뚱한 상품군으로 되짚힌다.
     * 상품군을 새로 추가할 때 한쪽만 고치는 실수를 여기서 잡는다.
     */
    @isTest
    static void shouldMapEveryRecordTypeBackToItsFamily() {
        for (String family : LeadConvertService.OPP_RECORD_TYPE_BY_FAMILY.keySet()) {
            String devName = LeadConvertService.OPP_RECORD_TYPE_BY_FAMILY.get(family);
            Assert.areEqual(family,
                LeadConvertService.RECOMMENDATION_BY_OPP_RECORD_TYPE.get(devName),
                devName + ' 의 역매핑은 상품군 ' + family + ' 와 일치해야 한다');
        }
    }

    // ─── Opportunity Name: "{회사명} - {상품군}" ────────────────────────────

    @isTest
    static void shouldNameOpportunityWithAccountAndFamily_WhenFamilyIsRP() {
        convertAndGetOppRecordType('RP');
        Assert.areEqual('Acme Corp - RP', lastOpportunityName,
            '전환된 기회 이름은 회사명 + 상품군');
    }

    @isTest
    static void shouldNameOpportunityWithAccountAndFamily_WhenFamilyIsBond() {
        convertAndGetOppRecordType('회사채');
        Assert.areEqual('Acme Corp - 회사채', lastOpportunityName,
            '전환된 기회 이름은 회사명 + 상품군');
    }

    @isTest
    static void shouldStillNameOpportunity_WhenNoProductMatches() {
        // 이름은 상품군만으로 만들어지므로 활성 상품이 하나도 없어도 붙는다.
        // 기준 상품만 비어 있게 된다.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            delete [SELECT Id FROM Product2];
        }
        convertAndGetOppRecordType('RP');
        Assert.areEqual('Acme Corp - RP', lastOpportunityName,
            '상품이 없어도 이름은 상품군으로 붙어야 함');
        Assert.isNull(lastPrimaryProductFamily, '기준 상품은 비어 있어야 함');
    }

    @isTest
    static void shouldTruncateName_WhenLongerThanFieldLimit() {
        String longAccount = 'A'.repeat(200);
        String assembled = LeadConvertService.buildOpportunityName(longAccount, '회사채');
        Assert.areEqual(120, assembled.length(), 'Opportunity.Name 120자 제한으로 잘려야 함');
        Assert.areEqual('A'.repeat(120), assembled, '앞에서부터 120자');
    }

    // ─── 기준 상품 = 상품군의 대표 상품 (이름순 우연에 맡기지 않는다) ───────

    @isTest
    static void shouldPickRepresentativeProduct_NotFirstByName() {
        // 한글이 라틴 문자보다 먼저 정렬되므로 이름순 첫 번째는 '외화 RP (USD) 30일물'.
        // 대표 상품인 'RP (환매조건부채권)' 이 잡혀야 한다.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new Product2(Name = '외화 RP (USD) 30일물', Family = 'RP', IsActive = true);
        }
        convertAndGetOppRecordType('RP');
        Assert.areEqual('RP (환매조건부채권)', lastPrimaryProductName,
            '이름순 첫 번째가 아니라 대표 상품이 기준 상품이어야 함');
    }

    @isTest
    static void shouldDefaultToRpDeal_WhenFamilyBlank() {
        Assert.areEqual(LeadConvertService.DEFAULT_OPP_RECORD_TYPE, convertAndGetOppRecordType(null));
        Assert.areEqual('RP', lastPrimaryProductFamily, '빈값이면 기준 상품도 RP');
    }

    @isTest
    static void shouldCreateMeetingEventOnOpportunity_WhenConverted() {
        // Given
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        Datetime meeting = Datetime.newInstance(2026, 9, 1, 14, 30, 0);
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = meeting;

        // When
        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Test.stopTest();

        // Then
        Id opportunityId = responses[0].opportunityId;
        List<Event> events = [
            SELECT Id, Subject, WhatId, WhoId, StartDateTime
            FROM Event
            WHERE WhatId = :opportunityId
        ];
        Assert.areEqual(1, events.size(), 'One meeting Event should be created on the Opportunity');
        Event evt = events[0];
        Assert.areEqual('고객 미팅', evt.Subject, 'Event subject should be the meeting label');
        Assert.areEqual(opportunityId, evt.WhatId, 'Event WhatId must be the created Opportunity');
        Assert.isNotNull(evt.WhoId, 'Event WhoId should be the created Contact');
        Assert.areEqual(meeting, evt.StartDateTime, 'Event start should match the requested meeting time');

        Contact contact = [SELECT Id FROM Contact LIMIT 1];
        Assert.areEqual(contact.Id, evt.WhoId, 'Event WhoId should be the converted Contact');
    }

    @isTest
    static void shouldReconnectExternalRecords_WhenConverted() {
        // Given
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 9, 0, 0);

        // When
        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Test.stopTest();

        // Then
        Opportunity opp = [SELECT AccountId FROM Opportunity WHERE Id = :responses[0].opportunityId];
        Id newAccountId = opp.AccountId;

        CorporateFinancialStatement__c statement =
            [SELECT Account__c FROM CorporateFinancialStatement__c WHERE Lead__c = :lead.Id];
        Assert.areEqual(newAccountId, statement.Account__c,
            'Financial statement should be repointed to the new Account');

        ExternalSignal__c signal =
            [SELECT Account__c FROM ExternalSignal__c WHERE Lead__c = :lead.Id];
        Assert.areEqual(newAccountId, signal.Account__c,
            'External signal should be repointed to the new Account');
    }

    @isTest
    static void shouldReconnectExternalRecords_WhenConvertedByStandardPath() {
        // convertLeads Invocable 을 거치지 않는 표준 전환(Database.convertLead 직접)에서도
        // 재무·시그널이 새 Account 로 재연결돼야 한다 — 재연결이 LeadConvertedTrigger 로
        // 옮겨졌기 때문. 예전엔 Invocable 안에만 있어 이 경로에서 재연결이 누락됐다.
        Lead lead = [SELECT Id FROM Lead LIMIT 1];

        Id newAccountId;
        Test.startTest();
        System.runAs(getTestUser()) {
            LeadStatus convertedStatus = [
                SELECT ApiName FROM LeadStatus WHERE IsConverted = true ORDER BY IsDefault DESC LIMIT 1
            ];
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(lead.Id);
            lc.setConvertedStatus(convertedStatus.ApiName);
            Database.LeadConvertResult result = Database.convertLead(lc);
            Assert.isTrue(result.isSuccess(), 'Standard conversion should succeed');
            newAccountId = result.getAccountId();
        }
        Test.stopTest();

        CorporateFinancialStatement__c statement =
            [SELECT Account__c FROM CorporateFinancialStatement__c WHERE Lead__c = :lead.Id];
        Assert.areEqual(newAccountId, statement.Account__c,
            'Financial statement should be repointed even without the Invocable');

        ExternalSignal__c signal =
            [SELECT Account__c FROM ExternalSignal__c WHERE Lead__c = :lead.Id];
        Assert.areEqual(newAccountId, signal.Account__c,
            'External signal should be repointed even without the Invocable');
    }

    @isTest
    static void shouldTransferLeadFieldsToAccount_WhenConverted() {
        // Given
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 11, 0, 0);

        // When
        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Test.stopTest();

        // Then
        Opportunity opp = [SELECT AccountId FROM Opportunity WHERE Id = :responses[0].opportunityId];
        Account acc = [
            SELECT Priority_Score__c, Business_Registration_Number__c, Assigned_Company_Code__c
            FROM Account WHERE Id = :opp.AccountId
        ];
        // TEMP(C안): org의 LeadConvertService가 김환진의 Priority_Score__c 필드 재생성 작업 중
        // 이관 로직을 임시 비활성화한 상태라 전환 Account의 Priority_Score__c는 null이다.
        // 김환진이 서비스 코드를 원복하면 아래 단언도 원복할 것.
        // Assert.areEqual(LEAD_PRIORITY, acc.Priority_Score__c, 'Priority score should transfer to Account');
        Assert.areEqual(LEAD_BRN, acc.Business_Registration_Number__c,
            'Business registration number should transfer when Account value is blank');
        Assert.areEqual(LEAD_COMPANY_CODE, acc.Assigned_Company_Code__c,
            'Assigned company code should transfer when Account value is blank');
    }

    // ─── Negative Tests ───────────────────────────────────────────────────

    @isTest
    static void shouldReturnValidationError_WhenLeadIdNull() {
        // Given
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 10, 0, 0);

        // When
        Test.startTest();
        List<LeadConvertService.Response> responses =
            LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        Test.stopTest();

        // Then
        Assert.isFalse(responses[0].isSuccess, 'Null leadId should fail validation');
        Assert.areEqual('VALIDATION', responses[0].errorType, 'Error type should be VALIDATION');
        Assert.isNull(responses[0].opportunityId, 'No Opportunity should be created');
    }

    @isTest
    static void shouldReturnValidationError_WhenMeetingDateTimeNull() {
        // Given
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;

        // When
        Test.startTest();
        List<LeadConvertService.Response> responses =
            LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        Test.stopTest();

        // Then
        Assert.isFalse(responses[0].isSuccess, 'Null meetingDateTime should fail validation');
        Assert.areEqual('VALIDATION', responses[0].errorType, 'Error type should be VALIDATION');
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        // When
        Test.startTest();
        List<LeadConvertService.Response> responses =
            LeadConvertService.convertLeads(new List<LeadConvertService.Request>());
        Test.stopTest();

        // Then
        Assert.isTrue(responses.isEmpty(), 'Empty input should return empty response list');
    }

    // ─── 제안 조건 이관 ─────────────────────────────────────────────────

    @isTest
    static void shouldCarryProposedYieldToOpportunity_WhenSetOnLead() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            lead.Recommended_Product_Family__c = 'RP';
            lead.Proposed_Yield_Rate__c = 3.20;
            update lead;
        }
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 10, 0, 0);

        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess, 'Conversion should succeed: ' + responses[0].errorMessage);
        Opportunity created = [SELECT RP_Yield__c FROM Opportunity WHERE Id = :responses[0].opportunityId];
        Assert.areEqual(3.20, created.RP_Yield__c,
            '제안서에 실은 수익률이 딜의 출발값이 돼야 한다 — 없으면 RM 이 처음부터 다시 입력한다');
    }

    @isTest
    static void shouldLeaveYieldBlank_WhenLeadHasNoProposedYield() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            lead.Recommended_Product_Family__c = 'RP';
            update lead;
        }
        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = lead.Id;
        req.meetingDateTime = Datetime.newInstance(2026, 9, 1, 10, 0, 0);

        List<LeadConvertService.Response> responses;
        Test.startTest();
        System.runAs(getTestUser()) {
            responses = LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        }
        Test.stopTest();

        Assert.isTrue(responses[0].isSuccess, 'Conversion should succeed: ' + responses[0].errorMessage);
        Opportunity created = [SELECT RP_Yield__c FROM Opportunity WHERE Id = :responses[0].opportunityId];
        Assert.isNull(created.RP_Yield__c, '제안 수익률이 없으면 값을 만들어내지 않는다');
    }
}