@isTest
private class MeetingPrepEmailComposerControllerTest {

    @TestSetup
    static void setup() {
        insert new Lead(
            LastName = 'Kim',
            Company = 'Test Co',
            Email = 'test@example.com',
            Title = 'CFO',
            Industry = 'Finance',
            name_new__c = 'TestName'
        );
    }

    @isTest
    static void testParseDraft_ParsesSubjectAndBody() {
        String raw = '제목: 단기 여유자금 운용 제안 건\n본문: 안녕하세요, 반갑습니다.\n감사합니다.';

        Test.startTest();
        MeetingPrepEmailComposerController.EmailDraft draft =
            MeetingPrepEmailComposerController.parseDraft(raw);
        Test.stopTest();

        System.assertEquals('단기 여유자금 운용 제안 건', draft.subject);
        System.assert(draft.htmlBody.contains('<br/>'), '줄바꿈이 <br/> 로 치환되어야 합니다.');
        System.assert(!draft.bodyText.contains('<br/>'), 'bodyText 는 평문이어야 합니다.');
        System.assert(draft.bodyText.contains('안녕하세요'), 'bodyText 에 본문 내용이 포함되어야 합니다.');
    }

    @isTest
    static void testParseDraft_ThrowsOnMissingMarkers() {
        Boolean threw = false;
        Test.startTest();
        try {
            MeetingPrepEmailComposerController.parseDraft('형식이 잘못된 텍스트');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '제목/본문 마커가 없으면 AuraHandledException 이 발생해야 합니다.');
    }

    @isTest
    static void testParseDraft_ThrowsOnBlankText() {
        Boolean threw = false;
        Test.startTest();
        try {
            MeetingPrepEmailComposerController.parseDraft('');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '빈 텍스트는 AuraHandledException 이 발생해야 합니다.');
    }

    @isTest
    static void testGetEmailContext() {
        Lead ld = [SELECT Id, Name FROM Lead LIMIT 1];
        Test.startTest();
        MeetingPrepEmailComposerController.EmailContext ctx =
            MeetingPrepEmailComposerController.getEmailContext(ld.Id);
        Test.stopTest();
        System.assertEquals(ld.Id, ctx.relatedToId, 'relatedToId=Lead');
        System.assertEquals(ld.Name, ctx.leadName, 'leadName');
        System.assert(ctx.fromOptions != null, 'fromOptions 반환되어야 함');
    }

    @isTest
    static void testGetRecordName() {
        Lead ld = [SELECT Id, Name FROM Lead LIMIT 1];
        Test.startTest();
        String nm = MeetingPrepEmailComposerController.getRecordName(ld.Id);
        String empty = MeetingPrepEmailComposerController.getRecordName(null);
        Test.stopTest();
        System.assertEquals(ld.Name, nm, '레코드 이름을 반환해야 합니다.');
        System.assertEquals('', empty, 'null 이면 빈 문자열을 반환해야 합니다.');
    }

    @isTest
    static void testGetEmailDraft_HandlesEmptyGenerationsInTestContext() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];
        Boolean threw = false;

        Test.startTest();
        try {
            MeetingPrepEmailComposerController.getEmailDraft(ld.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Test 컨텍스트에서는 ConnectApi 생성형 AI 응답이 비어 있어 예외가 발생해야 합니다.');
    }
}