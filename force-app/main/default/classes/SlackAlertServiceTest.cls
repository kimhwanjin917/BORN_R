/**
 * SlackAlertService 테스트. Slack 은 HttpCalloutMock, 설정은 settingOverrides 로 흉내 낸다.
 * 핵심 검증: (1) 어떤 상황에서도 예외가 밖으로 나가지 않는다 (2) 메시지에 원인·조치가 들어간다.
 */
@IsTest
private class SlackAlertServiceTest {

    private class SlackMock implements HttpCalloutMock {
        public Integer callCount = 0;
        public List<String> sentTexts = new List<String>();
        private String body;
        SlackMock(String body) { this.body = body; }
        public HttpResponse respond(HttpRequest request) {
            callCount++;
            Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
            sentTexts.add((String) sent.get('text'));
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            response.setBody(body);
            return response;
        }
    }

    private static void useSetting(String channelId, Boolean isActive) {
        CRM_Alert_Setting__mdt setting = new CRM_Alert_Setting__mdt(
            DeveloperName = SlackAlertService.ALERT_LEAD_CONVERT_FAILURE,
            Slack_Channel_Id__c = channelId,
            Is_Active__c = isActive
        );
        SlackAlertService.settingOverrides = new Map<String, CRM_Alert_Setting__mdt>{
            SlackAlertService.ALERT_LEAD_CONVERT_FAILURE => setting
        };
    }

    @TestSetup
    static void setup() {
        insert new Lead(
            LastName = '담당자',
            Company = 'TEST-알림대상(주)',
            Status = 'Open - Not Contacted',
            Industry = 'Insurance',
            Email = 'alert.tester@slackalert.test.example.com',
            name_new__c = '담당자',
            Business_Registration_Number__c = '1112223330',
            Assigned_Company_Code__c = 'CODE-A01'
        );
    }

    private static Lead getLead() {
        return [SELECT Id, Company, Name, Email, Business_Registration_Number__c, Owner.Name
                FROM Lead WHERE Company = 'TEST-알림대상(주)' LIMIT 1];
    }

    private static Event insertEvent(Id leadId) {
        // 알림 서비스 단독 테스트이므로 Lead 트리거의 전환은 막지 않는다 — Event 는 Lead 없이 만든다
        Datetime start = Datetime.newInstance(2026, 8, 27, 10, 0, 0);
        Event ev = new Event(Subject = '테스트 미팅', StartDateTime = start, EndDateTime = start.addHours(1));
        insert ev;
        return ev;
    }

    @IsTest
    static void duplicate_listsExistingAccountAndContact() {
        Lead ld = getLead();
        // 중복 규칙을 우회해서 "이미 존재하는" 레코드를 만든다
        Database.DMLOptions allowDup = new Database.DMLOptions();
        allowDup.DuplicateRuleHeader.allowSave = true;
        allowDup.optAllOrNone = true;
        Account existing = new Account(Name = 'TEST-알림대상(주)', Business_Registration_Number__c = '9999999999');
        Database.insert(existing, allowDup);
        Contact existingContact = new Contact(LastName = '기존담당', name_new__c = '기존담당',
            AccountId = existing.Id, Email = 'alert.tester@slackalert.test.example.com');
        Database.SaveResult contactResult = Database.insert(existingContact, allowDup);
        Assert.isTrue(contactResult.isSuccess(), 'Contact 준비 실패: ' + contactResult.getErrors());
        Event ev = insertEvent(null);
        useSetting('C_TEST', true);
        SlackMock mock = new SlackMock('{"ok":true,"ts":"1.1"}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SlackAlertService.notifyLeadConvertFailures(new List<SlackAlertService.LeadConvertFailure>{
            new SlackAlertService.LeadConvertFailure(ld.Id, ev.Id, 'CONVERSION_FAILED', 'Use one of these records?')
        });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE Email = 'alert.tester@slackalert.test.example.com'],
            '기존 Contact 가 만들어져 있어야 한다');
        Assert.areEqual(1, mock.callCount, 'Slack 게시 1회 / 삼킨 예외: ' + SlackAlertService.lastSwallowedError);
        String text = mock.sentTexts[0];
        Assert.isTrue(text.contains('Lead 자동 전환 실패 — TEST-알림대상(주)'), text);
        Assert.isTrue(text.contains('테스트 미팅'), '미팅 제목 포함: ' + text);
        Assert.isTrue(text.contains('2026-08-27'), '미팅 일시 포함: ' + text);
        Assert.isTrue(text.contains('Account「TEST-알림대상(주)」'), '기존 Account 표시: ' + text);
        Assert.isTrue(text.contains('Contact「기존담당」'), '기존 Contact 표시: ' + text);
        Assert.isTrue(text.contains('기존 Account/Contact를 선택'), '조치 안내: ' + text);
        Assert.isTrue(text.contains('/' + ld.Id), 'Lead 링크: ' + text);
    }

    @IsTest
    static void diagnose_mapsKnownErrorsToKorean() {
        Lead ld = getLead();
        Assert.isTrue(SlackAlertService.diagnose(
            new SlackAlertService.LeadConvertFailure(ld.Id, null, 'CONVERSION_FAILED', 'Required fields are missing: [Industry]'), ld
        ).cause.contains('필수 값'));
        Assert.isTrue(SlackAlertService.diagnose(
            new SlackAlertService.LeadConvertFailure(ld.Id, null, 'CONVERSION_FAILED', 'insufficient access rights'), ld
        ).cause.contains('권한'));
        Assert.isTrue(SlackAlertService.diagnose(
            new SlackAlertService.LeadConvertFailure(ld.Id, null, 'NOT_FOUND', 'Lead not found'), ld
        ).cause.contains('권한'));
        Assert.isTrue(SlackAlertService.diagnose(
            new SlackAlertService.LeadConvertFailure(ld.Id, null, 'CONVERSION_FAILED', 'FIELD_CUSTOM_VALIDATION_EXCEPTION: 금액 필수'), ld
        ).cause.contains('유효성'));
        Assert.isTrue(SlackAlertService.diagnose(
            new SlackAlertService.LeadConvertFailure(ld.Id, null, 'X', 'something odd'), ld
        ).cause.contains('알 수 없는 오류'));
        Assert.isTrue(SlackAlertService.diagnose(
            new SlackAlertService.LeadConvertFailure(ld.Id, null, 'CONVERSION_FAILED', 'Use one of these records?'), ld
        ).cause.contains('중복 규칙'), '기존 레코드 못 찾으면 일반 중복 안내');
    }

    @IsTest
    static void inactiveOrMissingSetting_sendsNothing() {
        Lead ld = getLead();
        SlackMock mock = new SlackMock('{"ok":true}');
        Test.setMock(HttpCalloutMock.class, mock);
        List<SlackAlertService.LeadConvertFailure> failures = new List<SlackAlertService.LeadConvertFailure>{
            new SlackAlertService.LeadConvertFailure(ld.Id, null, 'CONVERSION_FAILED', 'x')
        };

        useSetting('C_TEST', false);
        SlackAlertService.notifyLeadConvertFailures(failures);
        useSetting('   ', true);
        SlackAlertService.notifyLeadConvertFailures(failures);
        SlackAlertService.settingOverrides = new Map<String, CRM_Alert_Setting__mdt>();
        SlackAlertService.notifyLeadConvertFailures(failures);

        Assert.areEqual(0, mock.callCount, '비활성/빈 채널/설정 없음 → 발송 없음');
    }

    @IsTest
    static void emptyInput_isNoop() {
        useSetting('C_TEST', true);
        SlackMock mock = new SlackMock('{"ok":true}');
        Test.setMock(HttpCalloutMock.class, mock);
        SlackAlertService.notifyLeadConvertFailures(null);
        SlackAlertService.notifyLeadConvertFailures(new List<SlackAlertService.LeadConvertFailure>());
        Assert.areEqual(0, mock.callCount);
    }

    @IsTest
    static void slackFailure_isSwallowed() {
        Lead ld = getLead();
        useSetting('C_TEST', true);
        Test.setMock(HttpCalloutMock.class, new SlackMock('{"ok":false,"error":"not_in_channel"}'));

        Boolean threw = false;
        try {
            SlackAlertService.notifyLeadConvertFailures(new List<SlackAlertService.LeadConvertFailure>{
                new SlackAlertService.LeadConvertFailure(ld.Id, null, 'CONVERSION_FAILED', 'x')
            });
        } catch (Exception e) {
            threw = true;
        }
        Assert.isFalse(threw, 'Slack 실패는 밖으로 나가지 않는다');
    }

    @IsTest
    static void noMockCallout_isSwallowed() {
        // 콜아웃 mock 이 없으면 CalloutException 이 나지만, 서비스 밖으로 새지 않아야 한다
        Lead ld = getLead();
        useSetting('C_TEST', true);
        Boolean threw = false;
        try {
            SlackAlertService.notifyLeadConvertFailures(new List<SlackAlertService.LeadConvertFailure>{
                new SlackAlertService.LeadConvertFailure(ld.Id, null, 'CONVERSION_FAILED', 'x')
            });
        } catch (Exception e) {
            threw = true;
        }
        Assert.isFalse(threw);
    }

    @IsTest
    static void unknownLeadAndEvent_stillBuildsMessage() {
        useSetting('C_TEST', true);
        SlackMock mock = new SlackMock('{"ok":true}');
        Test.setMock(HttpCalloutMock.class, mock);
        // 유효하지만 존재하지 않는 Id: 만들고 지운다
        Lead gone = new Lead(LastName = '삭제', Company = 'TEST-삭제(주)', Status = 'Open - Not Contacted',
            name_new__c = '삭제', Business_Registration_Number__c = '1231231230', Assigned_Company_Code__c = 'CODE-DEL');
        insert gone;
        delete gone;
        Id fakeLead = gone.Id;

        Test.startTest(); // DML 이후 콜아웃 허용 컨텍스트 분리
        SlackAlertService.notifyLeadConvertFailures(new List<SlackAlertService.LeadConvertFailure>{
            new SlackAlertService.LeadConvertFailure(fakeLead, null, 'NOT_FOUND', 'Lead not found')
        });
        Test.stopTest();

        Assert.areEqual(1, mock.callCount, '삼킨 예외: ' + SlackAlertService.lastSwallowedError
            + ' / 메시지: ' + SlackAlertService.lastBuiltMessages);
        Assert.isTrue(mock.sentTexts[0].contains(String.valueOf(fakeLead)), '회사명 없으면 Id 표시');
    }

    @IsTest
    static void postQueueable_runsWithoutThrowing() {
        Test.setMock(HttpCalloutMock.class, new SlackMock('{"ok":true}'));
        Test.startTest();
        System.enqueueJob(new SlackAlertService.PostQueueable('C_TEST', new List<String>{ 'hello' }));
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status = 'Completed']);
    }
}