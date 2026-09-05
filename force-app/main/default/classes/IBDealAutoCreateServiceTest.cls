@IsTest
private class IBDealAutoCreateServiceTest {

    private static final Decimal TEST_AMOUNT = 8000000000.00;

    @TestSetup
    static void setup() {
        String stamp = String.valueOf(Datetime.now().getTime());

        Account acc = new Account(
            Name = 'IBA Test Issuer',
            Business_Registration_Number__c = stamp.right(10)
        );
        insert acc;

        insert new List<Product2>{
            new Product2(Name = 'IBA IPO 주선', Family = 'IPO',  IsActive = true),
            new Product2(Name = 'IBA 회사채',   Family = '채권', IsActive = true)
        };
    }

    private static Account issuer() {
        return [SELECT Id FROM Account WHERE Name = 'IBA Test Issuer' LIMIT 1];
    }

    private static Product2 productOf(String family) {
        return [SELECT Id FROM Product2 WHERE Family = :family AND Name LIKE 'IBA%' LIMIT 1];
    }

    private static Opportunity buildOpp(String name, Id accId, Id productId) {
        return new Opportunity(
            Name               = name,
            StageName          = '미팅',
            CloseDate          = Date.today().addDays(30),
            AccountId          = accId,
            Amount             = TEST_AMOUNT,
            Primary_Product__c = productId
        );
    }

    private static List<IB_Deal__c> dealsFor(Id oppId) {
        return [
            SELECT Id, Issuer_Account__c, Issue_Amount__c, Status__c,
                   Confidentiality_Level__c, Information_Barrier_Status__c, Barrier_Start_At__c
            FROM IB_Deal__c
            WHERE Source_Opportunity__c = :oppId
        ];
    }

    @IsTest
    static void ipoOpportunityCreatesDeal() {
        Account acc = issuer();
        Opportunity o = buildOpp('IPO Deal', acc.Id, productOf('IPO').Id);

        Test.startTest();
        insert o;
        Test.stopTest();

        List<IB_Deal__c> deals = dealsFor(o.Id);
        Assert.areEqual(1, deals.size(), 'IPO 딜에는 IB_Deal 이 생겨야 한다');
        Assert.areEqual(acc.Id, deals[0].Issuer_Account__c, '발행사가 옮겨져야 한다');
        Assert.areEqual(TEST_AMOUNT, deals[0].Issue_Amount__c, '발행 금액이 옮겨져야 한다');
        Assert.areEqual('Pipeline', deals[0].Status__c);
        Assert.areEqual('High', deals[0].Confidentiality_Level__c);
        Assert.areEqual('Active', deals[0].Information_Barrier_Status__c);
        Assert.isNotNull(deals[0].Barrier_Start_At__c, '차단벽 시작일시가 찍혀야 한다');
    }

    @IsTest
    static void bondOpportunityCreatesNothing() {
        Opportunity o = buildOpp('Bond Deal', issuer().Id, productOf('채권').Id);

        Test.startTest();
        insert o;
        Test.stopTest();

        Assert.areEqual(0, dealsFor(o.Id).size(), '채권 상품군은 대상이 아니다');
    }

    @IsTest
    static void noProductCreatesNothing() {
        Opportunity o = buildOpp('No Product Deal', issuer().Id, null);

        Test.startTest();
        insert o;
        Test.stopTest();

        Assert.areEqual(0, dealsFor(o.Id).size(), '주력 상품이 없으면 대상이 아니다');
    }

    @IsTest
    static void ownerBecomesTeamMember() {
        Opportunity o = buildOpp('IPO Owner Deal', issuer().Id, productOf('IPO').Id);

        Test.startTest();
        insert o;
        Test.stopTest();

        IB_Deal__c d = dealsFor(o.Id)[0];
        List<IB_Deal_Team_Member__c> members = [
            SELECT User__c, Role__c, Access_Level__c, Wall_Crossed_At__c
            FROM IB_Deal_Team_Member__c
            WHERE IB_Deal__c = :d.Id
        ];
        Assert.areEqual(1, members.size(), '원 담당자가 딜팀 멤버로 등록되어야 한다');
        Assert.areEqual(UserInfo.getUserId(), members[0].User__c);
        Assert.areEqual('Lead', members[0].Role__c);
        Assert.areEqual('Full', members[0].Access_Level__c);
        Assert.isNotNull(members[0].Wall_Crossed_At__c, '월크로스 일시가 기록되어야 한다');
    }

    @IsTest
    static void changingProductToIpoCreatesDeal() {
        Opportunity o = buildOpp('Becomes IPO', issuer().Id, productOf('채권').Id);
        insert o;
        Assert.areEqual(0, dealsFor(o.Id).size(), '사전 조건: 아직 없어야 한다');

        Test.startTest();
        update new Opportunity(Id = o.Id, Primary_Product__c = productOf('IPO').Id);
        Test.stopTest();

        Assert.areEqual(1, dealsFor(o.Id).size(), '상품을 IPO 로 바꾸면 생성되어야 한다');
    }

    @IsTest
    static void noDuplicateOnRepeatedUpdate() {
        Opportunity o = buildOpp('IPO No Dup', issuer().Id, productOf('IPO').Id);
        insert o;
        Assert.areEqual(1, dealsFor(o.Id).size());

        Test.startTest();
        update new Opportunity(Id = o.Id, Primary_Product__c = productOf('채권').Id);
        update new Opportunity(Id = o.Id, Primary_Product__c = productOf('IPO').Id);
        Test.stopTest();

        Assert.areEqual(1, dealsFor(o.Id).size(), '이미 있으면 중복 생성하지 않는다');
    }

    @IsTest
    static void bulkInsertIsHandled() {
        Id ipoId = productOf('IPO').Id;
        Id accId = issuer().Id;
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 50; i++) {
            opps.add(buildOpp('Bulk IPO ' + i, accId, ipoId));
        }

        Test.startTest();
        insert opps;
        Test.stopTest();

        Set<Id> ids = new Map<Id, Opportunity>(opps).keySet();
        Assert.areEqual(50, [SELECT COUNT() FROM IB_Deal__c WHERE Source_Opportunity__c IN :ids],
            '대량 처리에서도 건마다 하나씩 생겨야 한다');
    }

    @IsTest
    static void emptyInputIsSafe() {
        Test.startTest();
        IBDealAutoCreateService.handle(null, null);
        IBDealAutoCreateService.handle(new List<Opportunity>(), null);
        Assert.areEqual(0, IBDealAutoCreateService.withProductSetOrChanged(null, null).size());
        Test.stopTest();
    }

    /** 상품이 없는 저장은 SOQL 을 전혀 쓰지 않아야 한다. */
    @IsTest
    static void nonCandidateSaveCostsNoQuery() {
        Opportunity o = buildOpp('No Product Cost', issuer().Id, null);
        insert o;

        Test.startTest();
        Integer before = Limits.getQueries();
        IBDealAutoCreateService.handle(new List<Opportunity>{ o }, null);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, used, '주력 상품이 없으면 SOQL 을 쓰지 않아야 한다');
    }

    /** IPO 가 아닌 저장은 상품 조회 1회로 끝나야 한다(트랜잭션 내 캐시). */
    @IsTest
    static void bondSaveCostsOneCachedQuery() {
        Opportunity o = buildOpp('Bond Cost', issuer().Id, productOf('채권').Id);
        insert o;

        Test.startTest();
        Integer before = Limits.getQueries();
        IBDealAutoCreateService.handle(new List<Opportunity>{ o }, null);
        Integer first = Limits.getQueries() - before;

        Integer beforeSecond = Limits.getQueries();
        IBDealAutoCreateService.handle(new List<Opportunity>{ o }, null);
        Integer second = Limits.getQueries() - beforeSecond;
        Test.stopTest();

        // 앞선 insert 에서 트리거가 이미 돌아 캐시가 채워져 있으면 0회다.
        Assert.isTrue(first <= 1, '첫 호출은 상품 조회 최대 1회여야 한다. 실제: ' + first);
        Assert.areEqual(0, second, '두 번째부터는 캐시라 조회가 없어야 한다');
        Assert.areEqual(0, dealsFor(o.Id).size(), '채권은 딜이 생기면 안 된다');
    }
}