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
        lc.setConvertedStatus([
            SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true ORDER BY IsDefault DESC LIMIT 1
        ].MasterLabel);
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