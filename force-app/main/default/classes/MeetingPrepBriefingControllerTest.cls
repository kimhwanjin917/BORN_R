/**
 * MeetingPrepBriefingController 테스트.
 * ConnectApi(프롬프트 템플릿) 호출은 testResponseOverride 로 대체해,
 * 저장/조회/에러 처리 로직만 검증한다.
 */
@isTest
private class MeetingPrepBriefingControllerTest {

    private static Integer brnSeq = 5300000;

    private static Lead createLead() {
        Integer seq = brnSeq++;
        Lead lead = new Lead(
            LastName = 'Tester' + seq,
            Company = 'Briefing Co ' + seq,
            Status = '신규',
            Email = 'tester' + seq + '@example.com',
            name_new__c = 'Tester',
            Business_Registration_Number__c = String.valueOf(seq)
        );
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        lead.setOptions(dml);
        insert lead;
        return lead;
    }

    @isTest
    static void shouldReturnStoredBriefing_WhenPresent() {
        Lead lead = createLead();
        Datetime stamp = System.now();
        update new Lead(
            Id = lead.Id,
            Meeting_Prep_Briefing__c = '저장된 브리핑 본문',
            Meeting_Prep_Briefing_Updated_At__c = stamp
        );

        MeetingPrepBriefingController.BriefingResult result =
            MeetingPrepBriefingController.getBriefing(lead.Id);

        Assert.areEqual('저장된 브리핑 본문', result.briefing, '저장된 브리핑을 반환해야 한다');
        Assert.areNotEqual(null, result.updatedAt, '생성 시각이 반환돼야 한다');
    }

    @isTest
    static void shouldReturnNull_WhenNoBriefingStored() {
        Lead lead = createLead();
        MeetingPrepBriefingController.BriefingResult result =
            MeetingPrepBriefingController.getBriefing(lead.Id);
        Assert.areEqual(null, result.briefing, '저장된 브리핑이 없으면 null 이어야 한다');
    }

    @isTest
    static void shouldGenerateAndStoreBriefing_WhenTemplateReturnsText() {
        Lead lead = createLead();
        MeetingPrepBriefingController.testResponseOverride = '■ 한줄 요약: 테스트 브리핑';

        Test.startTest();
        MeetingPrepBriefingController.BriefingResult result =
            MeetingPrepBriefingController.generateBriefing(lead.Id);
        Test.stopTest();

        Assert.areEqual('■ 한줄 요약: 테스트 브리핑', result.briefing, '생성된 브리핑을 반환해야 한다');
        Lead stored = [
            SELECT Meeting_Prep_Briefing__c, Meeting_Prep_Briefing_Updated_At__c
            FROM Lead WHERE Id = :lead.Id
        ];
        Assert.areEqual('■ 한줄 요약: 테스트 브리핑', stored.Meeting_Prep_Briefing__c, 'Lead 에 저장돼야 한다');
        Assert.areNotEqual(null, stored.Meeting_Prep_Briefing_Updated_At__c, '생성 시각이 저장돼야 한다');
    }

    @isTest
    static void shouldThrow_WhenTemplateReturnsBlank() {
        Lead lead = createLead();
        MeetingPrepBriefingController.testResponseOverride = '';

        Boolean threw = false;
        try {
            MeetingPrepBriefingController.generateBriefing(lead.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, '빈 응답이면 예외를 던져야 한다');
    }

    @isTest
    static void shouldThrow_WhenRecordIdNull() {
        Boolean threw = false;
        try {
            MeetingPrepBriefingController.generateBriefing(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'recordId 가 없으면 예외를 던져야 한다');
    }
}