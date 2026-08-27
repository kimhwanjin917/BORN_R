@isTest
private class MyKpiControllerTest {

    private static final String TOP_RM = 'topkpi@mykpitest.example.com';
    private static final String LOW_RM = 'lowkpi@mykpitest.example.com';
    private static final String OUTSIDER = 'outsider@mykpitest.example.com';

    // A high-margin and a low-margin product, so the tests can show that fee
    // revenue and deal amount tell different stories.
    private static final Decimal HIGH_RATE = 1.0;
    private static final Decimal LOW_RATE = 0.15;

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];

        List<User> users = new List<User>{
            buildUser(TOP_RM, 'Top', admin.Id),
            buildUser(LOW_RM, 'Low', admin.Id),
            buildUser(OUTSIDER, 'Out', admin.Id)
        };
        // User DML must be isolated from the object DML that follows it.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users;
        }

        List<Product2> products = new List<Product2>{
            new Product2(Name = 'High Margin', Default_Fee_Rate__c = HIGH_RATE, IsActive = true),
            new Product2(Name = 'Low Margin', Default_Fee_Rate__c = LOW_RATE, IsActive = true)
        };
        insert products;

        Id topId = users[0].Id;
        Id lowId = users[1].Id;
        Date thisQuarter = quarterStart(Date.today());
        Date lastQuarter = quarterStart(thisQuarter.addMonths(-1));

        insert new List<Opportunity>{
            // This quarter: the small high-margin deal out-earns the large low-margin one.
            wonDeal('Top current', topId, products[0].Id, 300000000, thisQuarter.addDays(5)),
            wonDeal('Low current', lowId, products[1].Id, 1000000000, thisQuarter.addDays(5)),
            // A won deal in the previous quarter — this quarter's figure must not include it.
            wonDeal('Low previous', lowId, products[0].Id, 500000000, lastQuarter.addDays(5)),
            // Open deals never count towards fee revenue.
            new Opportunity(
                Name = 'Top open',
                StageName = 'Prospecting',
                CloseDate = thisQuarter.addDays(10),
                Amount = 900000000,
                OwnerId = topId,
                Primary_Product__c = products[0].Id
            )
        };
    }

    @isTest
    static void feeRevenueUsesProductRateNotDealAmount() {
        Test.startTest();
        MyKpiController.MyKpi kpi = runAsUser(TOP_RM);
        Test.stopTest();

        // 300,000,000 x 1% = 3,000,000 — the open deal is excluded.
        System.assertEquals(3000000, kpi.feeRevenue, '수수료는 성사된 딜의 금액 x 상품 요율');
    }

    @isTest
    static void bigDealOnALowMarginProductEarnsLess() {
        Test.startTest();
        MyKpiController.MyKpi top = runAsUser(TOP_RM);
        MyKpiController.MyKpi low = runAsUser(LOW_RM);
        Test.stopTest();

        // Low RM booked 1,000,000,000 against Top's 300,000,000, but at 0.15%
        // that is only 1,500,000 in fees against 3,000,000.
        System.assertEquals(1500000, low.feeRevenue, '저마진 상품은 금액이 커도 수수료가 낮다');
        System.assert(top.feeRevenue > low.feeRevenue, '거래금액이 작아도 고마진이면 수수료가 높다');
    }

    @isTest
    static void previousQuarterDealsAreExcluded() {
        Test.startTest();
        MyKpiController.MyKpi low = runAsUser(LOW_RM);
        Test.stopTest();

        // Low RM also has a 500,000,000 high-margin deal — 5,000,000 in fees —
        // closed last quarter. Only this quarter's 1,500,000 may count.
        System.assertEquals(1500000, low.feeRevenue, '지난 분기에 성사된 딜은 이번 분기 수수료에 들어가지 않는다');
    }

    @isTest
    static void newAccountsCountOwnedAccountsCreatedThisQuarter() {
        Id topId = [SELECT Id FROM User WHERE Username = :TOP_RM LIMIT 1].Id;
        insert new List<Account>{
            new Account(Name = 'Fresh One', OwnerId = topId, Business_Registration_Number__c = '0000000001'),
            new Account(Name = 'Fresh Two', OwnerId = topId, Business_Registration_Number__c = '0000000002')
        };

        Test.startTest();
        MyKpiController.MyKpi kpi = runAsUser(TOP_RM);
        Test.stopTest();

        System.assertEquals(2, kpi.newAccounts, '이번 분기에 본인이 만든 고객사만');
    }

    @isTest
    static void userWithNothingBookedScoresZero() {
        Test.startTest();
        MyKpiController.MyKpi kpi = runAsUser(OUTSIDER);
        Test.stopTest();

        System.assertEquals(0, kpi.feeRevenue, '성사된 딜이 없으면 0');
        System.assertEquals(0, kpi.newAccounts, '이번 분기에 만든 고객사가 없으면 0');
    }

    @isTest
    static void periodLabelNamesTheCurrentQuarter() {
        Test.startTest();
        MyKpiController.MyKpi kpi = runAsUser(TOP_RM);
        Test.stopTest();

        Integer expected = (Date.today().month() - 1) / 3 + 1;
        System.assertEquals(
            Date.today().year() + ' ' + expected + 'Q',
            kpi.periodLabel,
            '오늘 날짜가 속한 분기를 표시'
        );
    }

    @isTest
    static void percentIsZeroWhenNoTargetIsConfigured() {
        // Targets live in metadata and cannot be inserted here, so this only
        // asserts the division stays safe — never a divide-by-zero.
        Test.startTest();
        MyKpiController.MyKpi kpi = runAsUser(OUTSIDER);
        Test.stopTest();

        System.assert(kpi.feePercent >= 0, '달성률은 음수가 될 수 없다');
        System.assert(kpi.newAccountPercent >= 0, '달성률은 음수가 될 수 없다');
    }

    private static MyKpiController.MyKpi runAsUser(String username) {
        User u = [SELECT Id FROM User WHERE Username = :username LIMIT 1];
        MyKpiController.MyKpi kpi;
        System.runAs(u) {
            kpi = MyKpiController.getMyKpi();
        }
        return kpi;
    }

    private static Opportunity wonDeal(String name, Id ownerId, Id productId, Decimal amount, Date closeDate) {
        return new Opportunity(
            Name = name,
            StageName = 'Closed Won',
            CloseDate = closeDate,
            Amount = amount,
            OwnerId = ownerId,
            Primary_Product__c = productId
        );
    }

    private static User buildUser(String username, String lastName, Id profileId) {
        return new User(
            Username = username,
            LastName = lastName,
            Email = username,
            Alias = lastName.left(8),
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = profileId
        );
    }

    private static Date quarterStart(Date d) {
        return Date.newInstance(d.year(), ((d.month() - 1) / 3) * 3 + 1, 1);
    }
}