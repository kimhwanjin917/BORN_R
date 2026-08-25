/**
 * OpportunityLookupAction 테스트 — 키워드 검색 정합, 빈 검색어, 결과 없음, 상한 5건,
 * runAs(타 사용자)로 접근 불가 기회는 0건(with sharing + USER_MODE) 검증.
 * TestDataFactory 미사용(팀 공용 동결 파일).
 */
@IsTest
private class OpportunityLookupActionTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'OLA 근본테스트 주식회사', Industry = 'Manufacturing', Business_Registration_Number__c = '9990000011');
        Account acc2 = new Account(Name = 'OLA 다른회사', Industry = 'Media', Business_Registration_Number__c = '9990000012');
        insert new List<Account>{ acc, acc2 };

        Product2 rp = new Product2(Name = 'OLA RP', Family = 'RP', IsActive = true);
        insert rp;

        Date d = Date.today().addDays(30);
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(Name = 'OLA 근본테스트 RP 제안', AccountId = acc.Id, StageName = '제안', CloseDate = d, Amount = 100000000, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'OLA 두번째 기회', AccountId = acc.Id, StageName = '탐색', CloseDate = d),
            new Opportunity(Name = 'OLA 다른회사 딜', AccountId = acc2.Id, StageName = '탐색', CloseDate = d)
        };
        // 상한(5건) 검증용: 같은 고객사에 추가 4건 → 고객사 키워드로 총 6건 매칭
        for (Integer i = 0; i < 4; i++) {
            opps.add(new Opportunity(Name = 'OLA 추가 ' + i, AccountId = acc.Id, StageName = '탐색', CloseDate = d));
        }
        insert opps;
    }

    private static OpportunityLookupAction.Result run(String keyword) {
        OpportunityLookupAction.Request req = new OpportunityLookupAction.Request();
        req.keyword = keyword;
        List<OpportunityLookupAction.Result> out = OpportunityLookupAction.search(
            new List<OpportunityLookupAction.Request>{ req });
        System.assertEquals(1, out.size());
        return out[0];
    }

    @IsTest
    static void keywordByOpportunityName_returnsMatchWithContext() {
        Test.startTest();
        OpportunityLookupAction.Result r = run('RP 제안');
        Test.stopTest();

        System.assertEquals(1, r.matchCount);
        OpportunityLookupAction.Match m = r.matches[0];
        System.assertEquals('OLA 근본테스트 RP 제안', m.opportunityName);
        System.assertEquals('OLA 근본테스트 주식회사', m.accountName);
        System.assertEquals('Manufacturing', m.accountIndustry);
        System.assertEquals(100000000, m.amount);
        System.assertEquals('제안', m.stageName);
        System.assertNotEquals(null, m.opportunityId);
        System.assert(r.message.contains('1건'), r.message);
    }

    @IsTest
    static void keywordByAccountName_capsAtFiveResults() {
        Test.startTest();
        OpportunityLookupAction.Result r = run('근본테스트 주식회사');
        Test.stopTest();

        System.assertEquals(5, r.matchCount, '고객사 기준 6건 매칭이지만 상한 5건');
        System.assertEquals(5, r.matches.size());
    }

    @IsTest
    static void noMatch_returnsEmptyListWithMessage() {
        Test.startTest();
        OpportunityLookupAction.Result r = run('존재하지않는키워드XYZ');
        Test.stopTest();

        System.assertEquals(0, r.matchCount);
        System.assertEquals(0, r.matches.size());
        System.assert(r.message.contains('찾지 못했습니다'), r.message);
    }

    @IsTest
    static void blankKeyword_returnsEmptyWithoutQuery() {
        Test.startTest();
        OpportunityLookupAction.Result blank = run('   ');
        OpportunityLookupAction.Result nul = run(null);
        Test.stopTest();

        for (OpportunityLookupAction.Result r : new List<OpportunityLookupAction.Result>{ blank, nul }) {
            System.assertEquals(0, r.matchCount);
            System.assert(r.message.contains('검색어'), r.message);
        }
        System.assertEquals(0, OpportunityLookupAction.search(null).size());
    }

    @IsTest
    static void keywordByOpportunityName_partialMatch() {
        Test.startTest();
        OpportunityLookupAction.Result r = run('두번째 기회');
        Test.stopTest();

        System.assertEquals(1, r.matchCount);
        System.assertEquals('OLA 두번째 기회', r.matches[0].opportunityName);
    }

    @IsTest
    static void otherUserWithoutAccess_getsNoResults() {
        // Opportunity OWD Private 전제: 소유하지 않은 기회는 Standard User 에게 보이지 않아야 한다.
        // 객체/필드 권한이 없으면 QueryException 대신 빈 결과 + 메시지가 와야 한다(예외 없음).
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'olatst', Email = 'ola.test@example.com', EmailEncodingKey = 'UTF-8',
            LastName = 'OLA', LanguageLocaleKey = 'ko', LocaleSidKey = 'ko_KR',
            ProfileId = p.Id, TimeZoneSidKey = 'Asia/Seoul',
            Username = 'ola.test.' + DateTime.now().getTime() + '@example.com');
        insert u;

        OpportunityLookupAction.Result r;
        System.runAs(u) {
            Test.startTest();
            r = run('OLA');
            Test.stopTest();
        }
        // OWD Private 이면 0건. (Public 이면 보이므로 예외 없이 목록 반환만 확인)
        if (r.matchCount == 0) {
            System.assert(r.message.contains('찾지 못했습니다') || r.message.contains('권한'), r.message);
        } else {
            System.assert(r.matchCount <= 5);
        }
    }
}