/**
 * LeadEventConvertHandler / LeadEventConvertTrigger 테스트.
 * TestDataFactory(동결)는 사용하지 않고 자체 @TestSetup으로 데이터를 만든다.
 */
@IsTest
private class LeadEventConvertHandlerTest {

    @TestSetup
    static void setup() {
        // 전환 가능한 최소 필드 구성은 LeadConvertServiceTest(이주연)와 동일 기준:
        // Industry/Email은 표준 매핑으로 Account/Contact 필수 검증을 충족하고,
        // name_new__c(Text 10)·사업자번호는 필수 매핑 대상이다.
        insert new Lead(
            LastName = '담당자',
            Company = 'TEST-전환대상(주)',
            Status = 'Open - Not Contacted',
            Industry = 'Insurance',
            Email = 'lead.tester@leadeventconvert.test.example.com',
            name_new__c = '담당자',
            Business_Registration_Number__c = '9876543210',
            Assigned_Company_Code__c = 'CODE-T41'
        );
    }

    private static Lead getLead() {
        return [SELECT Id, IsConverted FROM Lead WHERE Company = 'TEST-전환대상(주)' LIMIT 1];
    }

    @IsTest
    static void convertsLeadWhenMeetingEventInserted() {
        Lead target = getLead();
        Datetime meetingTime = Datetime.now().addDays(2);

        Event source = new Event(
            Subject = '미팅',
            WhoId = target.Id,
            StartDateTime = meetingTime,
            EndDateTime = meetingTime.addHours(1)
        );

        Test.startTest();
        insert source;
        Test.stopTest();

        Lead converted = [
            SELECT Id, IsConverted, ConvertedOpportunityId, ConvertedContactId
            FROM Lead WHERE Id = :target.Id
        ];
        System.assertEquals(true, converted.IsConverted, 'Lead가 전환되어야 한다');
        System.assertNotEquals(null, converted.ConvertedOpportunityId, 'Opportunity가 생성되어야 한다');

        // Event는 봇이 만든 원본 1건뿐이어야 하고(서비스의 "고객 미팅" 중복 생성 없음),
        // 전환 후 새 Opportunity·Contact에 연결되어야 한다
        System.assertEquals(1, [SELECT COUNT() FROM Event], 'Event는 원본 1건만 존재해야 한다');
        Event relinked = [SELECT Subject, WhatId, WhoId, StartDateTime FROM Event WHERE Id = :source.Id];
        System.assertEquals('미팅', relinked.Subject, '원본 Event가 그대로 유지되어야 한다');
        System.assertEquals(converted.ConvertedOpportunityId, relinked.WhatId,
            '원본 Event가 새 Opportunity에 연결되어야 한다');
        System.assertEquals(converted.ConvertedContactId, relinked.WhoId,
            '원본 Event의 WhoId가 새 Contact로 이전되어야 한다');
        System.assertEquals(meetingTime, relinked.StartDateTime, '미팅 일시가 보존되어야 한다');
    }

    @IsTest
    static void ignoresEventNotLinkedToLead() {
        Lead target = getLead();
        Datetime meetingTime = Datetime.now().addDays(2);

        Test.startTest();
        insert new Event(
            Subject = '일반 일정',
            StartDateTime = meetingTime,
            EndDateTime = meetingTime.addHours(1)
        );
        Test.stopTest();

        System.assertEquals(false, getLead().IsConverted, 'WhoId 없는 Event는 전환을 일으키지 않는다');
    }

    @IsTest
    static void skipsAlreadyConvertedLead() {
        Lead target = getLead();
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(target.Id);
        // setConvertedStatus 는 ApiName 을 요구한다. MasterLabel 은 관리자가 표시명을
        // 바꾸는 순간 어긋난다 (예: Converted → '전환 완료').
        lc.setConvertedStatus([
            SELECT ApiName FROM LeadStatus WHERE IsConverted = true ORDER BY IsDefault DESC LIMIT 1
        ].ApiName);
        Database.LeadConvertResult lcr = Database.convertLead(lc);
        System.assertEquals(true, lcr.isSuccess(), '사전 전환이 성공해야 한다');
        Id opportunityId = lcr.getOpportunityId();
        Datetime meetingTime = Datetime.now().addDays(2);

        Test.startTest();
        insert new Event(
            Subject = '미팅',
            WhoId = lcr.getContactId(),
            StartDateTime = meetingTime,
            EndDateTime = meetingTime.addHours(1)
        );
        Test.stopTest();

        // Contact에 걸린 Event는 무시되고(재귀 방지 경로) 추가 Opportunity가 생기지 않는다
        System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE Id = :opportunityId]);
        System.assertEquals(1, [SELECT COUNT() FROM Opportunity],
            '이미 전환된 고객에게 추가 전환이 발생하면 안 된다');
        System.assertEquals(1, [SELECT COUNT() FROM Event WHERE Subject = '미팅'],
            'Lead가 아닌 대상의 Event는 삭제되지 않는다');
    }

    @IsTest
    static void convertsOncePerLeadForMultipleEvents() {
        Lead target = getLead();
        Datetime meetingTime = Datetime.now().addDays(2);

        Test.startTest();
        insert new List<Event>{
            new Event(Subject = '미팅', WhoId = target.Id,
                StartDateTime = meetingTime, EndDateTime = meetingTime.addHours(1)),
            new Event(Subject = '미팅(중복)', WhoId = target.Id,
                StartDateTime = meetingTime.addDays(1), EndDateTime = meetingTime.addDays(1).addHours(1))
        };
        Test.stopTest();

        Lead converted = [SELECT IsConverted, ConvertedOpportunityId FROM Lead WHERE Id = :target.Id];
        System.assertEquals(true, converted.IsConverted);
        System.assertEquals(1, [SELECT COUNT() FROM Opportunity], '전환은 Lead당 1회여야 한다');
        System.assertEquals(2, [SELECT COUNT() FROM Event], '서비스가 Event를 추가 생성하면 안 된다');
        // 표준 전환 동작이 Lead의 열린 활동을 모두 새 Opportunity로 재연결한다(실측)
        System.assertEquals(2, [SELECT COUNT() FROM Event WHERE WhatId = :converted.ConvertedOpportunityId],
            '원본 Event들이 모두 Opportunity에 연결된다');
    }

    /** Slack 게시 요청을 기록하는 mock (알림 경로 검증용) */
    private class SlackMock implements HttpCalloutMock {
        public List<String> sentTexts = new List<String>();
        public HttpResponse respond(HttpRequest request) {
            Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
            sentTexts.add((String) sent.get('text'));
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            response.setBody('{"ok":true,"ts":"1.1"}');
            return response;
        }
    }

    @IsTest
    static void conversionFailure_sendsSlackAlertAndKeepsLeadOpen() {
        // 같은 회사명의 Account 를 미리 만들어 표준 중복 규칙으로 전환을 실패시킨다
        Lead target = getLead();
        Account existing = new Account(Name = 'TEST-전환대상(주)', Business_Registration_Number__c = '5555555550');
        insert existing;
        // 표준 Contact 매칭 규칙(이름+이메일)에 걸리도록 Lead 와 같은 담당자를 미리 둔다
        // (이 insert 자체가 Lead 와의 중복으로 막히므로 규칙을 우회해서 넣는다)
        Database.DMLOptions allowDup = new Database.DMLOptions();
        allowDup.DuplicateRuleHeader.allowSave = true;
        allowDup.optAllOrNone = true;
        Database.insert(new Contact(LastName = '담당자', name_new__c = '담당자', AccountId = existing.Id,
            Email = 'lead.tester@leadeventconvert.test.example.com'), allowDup);
        Datetime meetingTime = Datetime.now().addDays(2);
        SlackAlertService.settingOverrides = new Map<String, CRM_Alert_Setting__mdt>{
            SlackAlertService.ALERT_LEAD_CONVERT_FAILURE => new CRM_Alert_Setting__mdt(
                DeveloperName = SlackAlertService.ALERT_LEAD_CONVERT_FAILURE,
                Slack_Channel_Id__c = 'C_TEST', Is_Active__c = true)
        };
        SlackMock mock = new SlackMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Event source = new Event(Subject = '미팅', WhoId = target.Id,
            StartDateTime = meetingTime, EndDateTime = meetingTime.addHours(1));
        insert source;
        Test.stopTest();

        System.assertEquals(false, getLead().IsConverted, '중복 규칙에 막혀 Lead 는 전환되지 않는다');
        System.assertEquals(1, [SELECT COUNT() FROM Event WHERE Id = :source.Id], '원본 Event 는 유지된다');
        // 전환 Queueable 안에서는 이미 DML 이 있었으므로 테스트의 mock 콜아웃은 거부된다
        // (운영에서는 별도 PostQueueable 로 체인되어 발송됨 — SlackAlertServiceTest 가 검증).
        // 여기서는 핸들러→알림 서비스 연결과 메시지 내용만 검증한다.
        System.assertEquals(1, SlackAlertService.lastBuiltMessages.size(),
            '알림 메시지 1건 / 삼킨 예외: ' + SlackAlertService.lastSwallowedError);
        String text = SlackAlertService.lastBuiltMessages[0];
        System.assert(text.contains('Lead 자동 전환 실패 — TEST-전환대상(주)'), text);
        System.assert(text.contains('Account「TEST-전환대상(주)」'), '기존 Account 안내: ' + text);
        System.assert(text.contains('Contact「담당자」'), '기존 Contact 안내: ' + text);
        System.assert(text.contains('수동으로 전환'), '조치 안내: ' + text);
    }

    @IsTest
    static void conversionFailure_withoutAlertSetting_doesNotBreak() {
        // 알림 설정이 없어도(또는 Slack 이 죽어도) 전환 경로는 예외 없이 끝난다
        Lead target = getLead();
        Account existing = new Account(Name = 'TEST-전환대상(주)', Business_Registration_Number__c = '5555555550');
        insert existing;
        // 표준 Contact 매칭 규칙(이름+이메일)에 걸리도록 Lead 와 같은 담당자를 미리 둔다
        // (이 insert 자체가 Lead 와의 중복으로 막히므로 규칙을 우회해서 넣는다)
        Database.DMLOptions allowDup = new Database.DMLOptions();
        allowDup.DuplicateRuleHeader.allowSave = true;
        allowDup.optAllOrNone = true;
        Database.insert(new Contact(LastName = '담당자', name_new__c = '담당자', AccountId = existing.Id,
            Email = 'lead.tester@leadeventconvert.test.example.com'), allowDup);
        SlackAlertService.settingOverrides = new Map<String, CRM_Alert_Setting__mdt>();
        Datetime meetingTime = Datetime.now().addDays(2);

        Test.startTest();
        insert new Event(Subject = '미팅', WhoId = target.Id,
            StartDateTime = meetingTime, EndDateTime = meetingTime.addHours(1));
        Test.stopTest();

        System.assertEquals(false, getLead().IsConverted);
    }

    @IsTest
    static void serviceStillCreatesEventWhenFlagOmitted() {
        // 회귀 확인: 13번 화면 Flow처럼 createMeetingEvent를 넘기지 않으면
        // LeadConvertService의 기존 동작("고객 미팅" Event 생성)이 유지된다
        Lead target = getLead();
        Datetime meetingTime = Datetime.now().addDays(2);

        LeadConvertService.Request req = new LeadConvertService.Request();
        req.leadId = target.Id;
        req.meetingDateTime = meetingTime;

        Test.startTest();
        List<LeadConvertService.Response> responses =
            LeadConvertService.convertLeads(new List<LeadConvertService.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, responses[0].isSuccess, '기존 방식 호출이 성공해야 한다');
        System.assertEquals(1, [
            SELECT COUNT() FROM Event
            WHERE Subject = '고객 미팅' AND WhatId = :responses[0].opportunityId
        ], '플래그를 안 넘긴 호출은 기존대로 고객 미팅 Event를 생성해야 한다');
    }
}