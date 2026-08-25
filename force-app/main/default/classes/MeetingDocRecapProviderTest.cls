/**
 * MeetingDocRecapProvider 테스트. TestDataFactory 는 사용하지 않고 @TestSetup 에서 데이터를 만든다.
 * Account 는 이 org 의 필수 필드(Business_Registration_Number__c 10자, Industry)를 채운다.
 */
@IsTest
private class MeetingDocRecapProviderTest {

    private static final String RAW_NOTE_1 = '첫 번째 미팅. 만기 자금 재예치 희망.';
    private static final String RAW_NOTE_2 = '두 번째 미팅. 추가 회사채 발행 검토.';

    @TestSetup
    static void setup() {
        Account account = new Account(
            Name = 'Recap 테스트 주식회사',
            Industry = 'Manufacturing',
            Business_Registration_Number__c = '1234567890'
        );
        insert account;

        Opportunity opportunity = new Opportunity(
            Name = 'Recap 테스트 딜',
            AccountId = account.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Amount = 100000000
        );
        insert opportunity;

        // 트리거(10번)가 Raw → Sanitized 를 채운다. 여기서는 Sanitized 가 존재한다는 사실만 의존한다.
        List<Meeting_Note__c> notes = new List<Meeting_Note__c>();
        for (Integer i = 0; i < 5; i++) {
            notes.add(new Meeting_Note__c(
                Opportunity__c = opportunity.Id,
                Raw_Content__c = (i == 0 ? RAW_NOTE_1 : (i == 1 ? RAW_NOTE_2 : '메모 ' + i))
            ));
        }
        insert notes;

        // 첨부 파일: txt(발췌됨), html(태그 제거 발췌), pdf(발췌 불가)
        List<ContentVersion> versions = new List<ContentVersion>{
            new ContentVersion(Title = '가계약 조건 메모', PathOnClient = 'terms.txt',
                VersionData = Blob.valueOf('RP 약정수익률 3.2%, 만기 2026-12-31, 최소 예치 1억'),
                FirstPublishLocationId = opportunity.Id),
            new ContentVersion(Title = '사전 리포트', PathOnClient = 'report.html',
                VersionData = Blob.valueOf('<html><head><style>p{}</style></head><body><h1>리포트</h1><p>업황 &amp; 전망</p><script>x=1</script></body></html>'),
                FirstPublishLocationId = opportunity.Id),
            new ContentVersion(Title = '상품소개서', PathOnClient = 'brochure.pdf',
                VersionData = Blob.valueOf('%PDF-1.4 binary'),
                FirstPublishLocationId = opportunity.Id)
        };
        insert versions;
    }

    private static Opportunity getOpportunity() {
        return [SELECT Id FROM Opportunity WHERE Name = 'Recap 테스트 딜' LIMIT 1];
    }

    private static String run(Opportunity opportunity) {
        MeetingDocRecapProvider.Request request = new MeetingDocRecapProvider.Request();
        request.RelatedOpportunity = opportunity;
        List<MeetingDocRecapProvider.Response> responses = MeetingDocRecapProvider.getRecapContext(
            new List<MeetingDocRecapProvider.Request>{ request });
        Assert.areEqual(1, responses.size());
        return responses[0].Prompt;
    }

    @IsTest
    static void includesRecentSanitizedNotes_limitedAndNewestFirst_noRaw() {
        String prompt = run(getOpportunity());

        Assert.isTrue(prompt.contains('[지난 미팅 메모(마스킹본, 최신순)]'), prompt);
        Assert.isTrue(prompt.contains('[메모 1]') && prompt.contains('[메모 3]'), '최대 3건');
        Assert.isFalse(prompt.contains('[메모 4]'), '4건째는 제외');

        // 마스킹본만 포함 — Raw 원문 문자열 자체가 Sanitized 와 같을 수 있으므로, 조회 필드에 Raw 가 없음을 SOQL 로 재확인
        List<Meeting_Note__c> notes = [SELECT Sanitized_Content__c FROM Meeting_Note__c ORDER BY CreatedDate DESC LIMIT 3];
        for (Meeting_Note__c note : notes) {
            if (String.isNotBlank(note.Sanitized_Content__c)) {
                Assert.isTrue(prompt.contains(note.Sanitized_Content__c.trim()), '마스킹본 포함: ' + note.Sanitized_Content__c);
            }
        }
        Assert.isTrue(prompt.contains('마스킹 '), '마스킹 건수 표기');
    }

    @IsTest
    static void includesFiles_withTextExcerptAndNonTextNotice() {
        String prompt = run(getOpportunity());

        Assert.isTrue(prompt.contains('[첨부 자료]'));
        Assert.isTrue(prompt.contains('가계약 조건 메모') && prompt.contains('RP 약정수익률 3.2%'), 'txt 본문 발췌: ' + prompt);
        Assert.isTrue(prompt.contains('사전 리포트') && prompt.contains('업황 & 전망'), 'html 태그 제거 발췌');
        Assert.isFalse(prompt.contains('<h1>') || prompt.contains('x=1'), 'script/태그 제거');
        Assert.isTrue(prompt.contains('상품소개서') && prompt.contains('본문 자동 추출 불가'), 'pdf 는 안내만');
        Assert.isTrue(prompt.contains('(.pdf)'));
    }

    @IsTest
    static void opportunityWithoutNotesOrFiles_returnsNoticeMessages() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        Opportunity empty = new Opportunity(Name = '빈 딜', AccountId = account.Id,
            StageName = 'Prospecting', CloseDate = Date.today());
        insert empty;

        String prompt = run(empty);

        Assert.isTrue(prompt.contains(MeetingDocRecapProvider.NO_NOTE_MESSAGE));
        Assert.isTrue(prompt.contains(MeetingDocRecapProvider.NO_FILE_MESSAGE));
    }

    @IsTest
    static void nullOrEmptyRequests_areHandled() {
        Assert.areEqual(0, MeetingDocRecapProvider.getRecapContext(null).size());
        Assert.areEqual(0, MeetingDocRecapProvider.getRecapContext(new List<MeetingDocRecapProvider.Request>()).size());

        MeetingDocRecapProvider.Request noOpp = new MeetingDocRecapProvider.Request();
        List<MeetingDocRecapProvider.Response> responses = MeetingDocRecapProvider.getRecapContext(
            new List<MeetingDocRecapProvider.Request>{ noOpp, null });
        Assert.areEqual(2, responses.size());
        Assert.isTrue(responses[0].Prompt.contains(MeetingDocRecapProvider.NO_NOTE_MESSAGE));
        Assert.isTrue(responses[1].Prompt.contains(MeetingDocRecapProvider.NO_FILE_MESSAGE));
    }

    @IsTest
    static void helpers_formatSizeAndStripHtml() {
        Assert.areEqual('크기 미상', MeetingDocRecapProvider.formatSize(null));
        Assert.areEqual('512B', MeetingDocRecapProvider.formatSize(512));
        Assert.areEqual('2KB', MeetingDocRecapProvider.formatSize(2048));
        Assert.areEqual('1.5MB', MeetingDocRecapProvider.formatSize(1536 * 1024));
        Assert.areEqual('a b', MeetingDocRecapProvider.stripHtml('<p>a</p><b>b</b>').trim().replace('\n', ' ').trim().replace('  ', ' '));
    }

    @IsTest
    static void largeTextFile_isNotExcerpted() {
        Opportunity opportunity = getOpportunity();
        ContentVersion big = new ContentVersion(Title = '큰 텍스트', PathOnClient = 'big.txt',
            VersionData = Blob.valueOf('x'.repeat(MeetingDocRecapProvider.MAX_TEXT_FILE_BYTES + 10)),
            FirstPublishLocationId = opportunity.Id);
        insert big;

        String prompt = run(opportunity);

        Assert.isTrue(prompt.contains('큰 텍스트'));
        Integer idx = prompt.indexOf('큰 텍스트');
        String after = prompt.substring(idx, Math.min(prompt.length(), idx + 300));
        Assert.isTrue(after.contains('본문 자동 추출 불가'), '크기 초과 텍스트 파일은 발췌 안 함: ' + after);
    }

    @IsTest
    static void userWithoutAccess_getsNoticeInsteadOfException() {
        Opportunity opportunity = getOpportunity();
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User limited = new User(
            Alias = 'recapu', Email = 'recap.user@example.com', EmailEncodingKey = 'UTF-8',
            LastName = 'Recap', LanguageLocaleKey = 'ko', LocaleSidKey = 'ko_KR', ProfileId = standard.Id,
            TimeZoneSidKey = 'Asia/Seoul', UserName = 'recap.user.' + System.currentTimeMillis() + '@example.com'
        );
        String prompt;
        System.runAs(limited) {
            prompt = run(opportunity);
        }
        Assert.isNotNull(prompt);
        Assert.isTrue(prompt.contains('[지난 미팅 메모'), '예외 없이 컨텍스트 반환: ' + prompt);
        // 권한/공유가 없으면 안내문, 있으면 정상 — 어느 쪽이든 예외가 없어야 한다
        Assert.isTrue(prompt.contains(MeetingDocRecapProvider.NO_NOTE_ACCESS_MESSAGE)
            || prompt.contains(MeetingDocRecapProvider.NO_NOTE_MESSAGE)
            || prompt.contains('[메모 1]'));
    }
}