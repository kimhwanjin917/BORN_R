@IsTest
private class MeetingPrepBriefingOpportunityTest {

    @IsTest
    static void shouldGenerateAndReadOpportunityBriefingUsingContentNote() {
        Account account = new Account(
            Name = 'V2 브리핑 테스트 회사',
            Industry = 'Manufacturing',
            Business_Registration_Number__c = '9990000099'
        );
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'V2 브리핑 테스트 기회',
            AccountId = account.Id,
            StageName = '미팅',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        MeetingPrepBriefingController.testResponseOverride = '영구 저장 테스트 브리핑';
        Test.startTest();
        MeetingPrepBriefingController.BriefingResult generated =
            MeetingPrepBriefingController.generateBriefing(opportunity.Id);
        MeetingPrepBriefingController.BriefingResult loaded =
            MeetingPrepBriefingController.getBriefing(opportunity.Id);
        Test.stopTest();

        Assert.areEqual('영구 저장 테스트 브리핑', generated.briefing, '생성 결과를 반환해야 한다');
        Assert.areEqual('영구 저장 테스트 브리핑', loaded.briefing, 'ContentNote에서 읽어야 한다');
        Assert.areNotEqual(null, loaded.updatedAt, '저장 시각을 읽어야 한다');

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :opportunity.Id
            LIMIT 10
        ];
        Assert.areEqual(1, links.size(), 'Opportunity에 브리핑 노트를 연결해야 한다');
        ContentNote saved = [
            SELECT Title, Content
            FROM ContentNote
            WHERE Id = :links[0].ContentDocumentId
            LIMIT 1
        ];
        Assert.areEqual(MeetingPrepBriefingController.OPPORTUNITY_NOTE_TITLE, saved.Title, '노트 제목이 맞아야 한다');
        Assert.areEqual('영구 저장 테스트 브리핑', saved.Content.toString(), '브리핑 본문을 영구 저장해야 한다');
    }

    @IsTest
    static void shouldInvalidateStoredFinancialFallbackWhenDataExists() {
        Account account = new Account(
            Name = 'Fallback 무효화 테스트 회사',
            Industry = 'Manufacturing',
            Business_Registration_Number__c = '9990000088'
        );
        insert account;
        insert new CorporateFinancialStatement__c(
            Account__c = account.Id,
            Fiscal_Year__c = 2025,
            Period_Type__c = '4분기',
            Revenue__c = 1000000000,
            Total_Assets__c = 2000000000,
            Cash_And_Equivalents__c = 500000000
        );
        Opportunity opportunity = new Opportunity(
            Name = 'Fallback 무효화 테스트 기회',
            AccountId = account.Id,
            StageName = '미팅',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        ContentNote note = new ContentNote(
            Title = MeetingPrepBriefingController.OPPORTUNITY_NOTE_TITLE,
            Content = Blob.valueOf('제공된 근거 데이터에 재무 수치가 포함되어 있지 않아 확인할 수 없습니다.')
        );
        insert note;
        insert new ContentDocumentLink(
            ContentDocumentId = note.Id,
            LinkedEntityId = opportunity.Id,
            ShareType = 'V'
        );

        MeetingPrepBriefingController.BriefingResult invalidated =
            MeetingPrepBriefingController.getBriefing(opportunity.Id);
        Assert.isNull(invalidated.briefing, '재무 데이터가 있는데 fallback 문구는 무효화해야 한다');
        Assert.isNull(invalidated.updatedAt, '무효화된 fallback의 시각은 반환하지 않아야 한다');

        MeetingPrepBriefingController.testResponseOverride =
            '■ 한줄 요약: 재무 추이 상세 데이터 접근이 불가하여 구체적 매출·자산·현금흐름 수치를 제시할 수 없습니다.\n\n'
            + '■ 재무 하이라이트: (불릿)\n'
            + '- 제공된 근거 데이터 내에서 확인 가능한 항목이 없어, 재무 변화의 구체적 흐름은 미확인 상태입니다.\n'
            + '- 재무 세부 자료 제공 시 주요 항목 변동을 기반으로 논의해야 합니다.';
        MeetingPrepBriefingController.BriefingResult regenerated;
        Test.startTest();
        regenerated = MeetingPrepBriefingController.generateBriefing(opportunity.Id);
        Test.stopTest();
        Assert.isTrue(regenerated.briefing.contains('10억 원'), '원천 재무 수치를 fallback보다 우선해야 한다');
    }

    @IsTest
    static void shouldInvalidateStoredExternalSignalFallbackWhenSignalsExist() {
        Account account = new Account(
            Name = '외부 시그널 fallback 테스트 회사',
            Industry = 'Manufacturing',
            Business_Registration_Number__c = '9990000077'
        );
        insert account;
        insert new ExternalSignal__c(
            Account__c = account.Id,
            Signal_Type__c = '뉴스',
            Signal_Date__c = Date.today(),
            Title__c = '외부 시그널 테스트 뉴스',
            Summary__c = '테스트 외부 시그널 요약'
        );
        Opportunity opportunity = new Opportunity(
            Name = '외부 시그널 fallback 테스트 기회',
            AccountId = account.Id,
            StageName = '미팅',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        ContentNote note = new ContentNote(
            Title = MeetingPrepBriefingController.OPPORTUNITY_NOTE_TITLE,
            Content = Blob.valueOf('■ 한줄 요약: CRM에 등록된 재무·시그널 상세가 제공되지 않아 확정적 결론은 불가합니다.')
        );
        insert note;
        insert new ContentDocumentLink(
            ContentDocumentId = note.Id,
            LinkedEntityId = opportunity.Id,
            ShareType = 'V'
        );

        MeetingPrepBriefingController.BriefingResult invalidated =
            MeetingPrepBriefingController.getBriefing(opportunity.Id);

        Assert.isTrue(
            MeetingPrepBriefingController.isExternalSignalFallback(
                '외부 신호의 상세 내용은 제공되지 않았습니다.'),
            '화면에 표시된 외부 신호 fallback 문구를 인식해야 한다');
        Assert.isNull(invalidated.briefing, '외부 시그널 데이터가 있는데 fallback 문구는 무효화해야 한다');
        Assert.isNull(invalidated.updatedAt, '무효화된 외부 시그널 fallback의 시각은 반환하지 않아야 한다');
    }

    @IsTest
    static void shouldReplaceGeneratedExternalSignalFallbackWithSourceSignals() {
        Account account = new Account(
            Name = '외부 시그널 생성 보강 테스트 회사',
            Industry = 'Manufacturing',
            Business_Registration_Number__c = '9990000076'
        );
        insert account;
        insert new ExternalSignal__c(
            Account__c = account.Id,
            Signal_Type__c = '수주',
            Signal_Date__c = Date.today(),
            Title__c = '실제 외부 시그널 제목',
            Summary__c = '실제 외부 시그널 요약'
        );
        Opportunity opportunity = new Opportunity(
            Name = '외부 시그널 생성 보강 테스트 기회',
            AccountId = account.Id,
            StageName = '미팅',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;

        MeetingPrepBriefingController.testResponseOverride =
            '■ 한줄 요약: 테스트 요약\n'
            + '■ 최근 동향: 외부 시그널 상세가 제공되지 않았습니다.\n'
            + '■ 미팅 포인트: 확인 질문';

        Test.startTest();
        MeetingPrepBriefingController.BriefingResult generated =
            MeetingPrepBriefingController.generateBriefing(opportunity.Id);
        Test.stopTest();

        Assert.isTrue(
            generated.briefing.contains('실제 외부 시그널 제목'),
            '생성 결과에는 실제 외부 시그널 제목이 들어가야 한다'
        );
        Assert.isTrue(
            generated.briefing.contains('실제 외부 시그널 요약'),
            '생성 결과에는 실제 외부 시그널 요약이 들어가야 한다'
        );
        Assert.isFalse(
            generated.briefing.contains('외부 시그널 상세가 제공되지 않았습니다'),
            '생성 결과에 외부 시그널 fallback이 남으면 안 된다'
        );
    }
}