/**
 * Verifies wallet, outstanding balance and share rules of WalletShareService (docs/54 §정의).
 */
@IsTest
private class WalletShareServiceTest {
    private static final Decimal EOK = RadarTestDataFactory.EOK;

    @TestSetup
    static void setup() {
        RadarTestDataFactory.createProducts();
        RadarTestDataFactory.createAccounts(1, true);
    }

    private static Account theAccount() {
        return [SELECT Id, Name FROM Account LIMIT 1];
    }

    private static Map<String, Product2> products() {
        Map<String, Product2> byFamily = new Map<String, Product2>();
        for (Product2 product : [SELECT Id, Name, Family FROM Product2]) {
            byFamily.put(product.Family, product);
        }
        return byFamily;
    }

    @IsTest
    static void shouldUseLatestQuarterAndCashWalletForRp_WhenTwoStatementsExist() {
        Account account = theAccount();
        RadarTestDataFactory.createStatements(new List<Account>{ account }, 2025, 4, 500 * EOK, 0, 0, 100 * EOK, 100 * EOK);
        RadarTestDataFactory.createStatements(new List<Account>{ account }, 2026, 2, 5000 * EOK, 0, 0, 300 * EOK, 200 * EOK);
        Date today = Date.today();
        insert RadarTestDataFactory.buildOpportunity(account, products().get('RP'), 100 * EOK, today.addDays(-10), today.addDays(81), true);

        Test.startTest();
        WalletShareService.AccountWallet view = WalletShareService.compute(new Set<Id>{ account.Id }, today).get(account.Id);
        Test.stopTest();

        Assert.areEqual('2026 Q2', view.statementPeriod, 'latest statement should win');
        WalletShareService.FamilyWallet rp = view.byFamily.get('RP');
        Assert.areEqual(500 * EOK, rp.wallet, 'RP wallet = 단기금융상품 + 현금 of latest quarter');
        Assert.areEqual(100 * EOK, rp.ourBalance, 'RP won amount is outstanding before maturity');
        Assert.areEqual(0.2, rp.share, 'share = 100 / 500');
        Assert.areEqual('성장기업', view.segment, '5,000억 total assets → 성장기업');
        Assert.areEqual(500 * EOK, view.expectedWallet, 'cash wallet counted once across RP/자금운용');
        Assert.areEqual(400 * EOK, view.whitespace, 'whitespace = wallet − ours');
    }

    @IsTest
    static void shouldExcludeMaturedRp_WhenMaturityBeforeReferenceDate() {
        Account account = theAccount();
        RadarTestDataFactory.createStatements(new List<Account>{ account }, 2026, 2, 1000 * EOK, 0, 0, 100 * EOK, 100 * EOK);
        Date today = Date.today();
        insert RadarTestDataFactory.buildOpportunity(account, products().get('RP'), 50 * EOK, today.addDays(-120), today.addDays(-29), true);

        Test.startTest();
        WalletShareService.FamilyWallet rp = WalletShareService.compute(new Set<Id>{ account.Id }, today).get(account.Id).byFamily.get('RP');
        Test.stopTest();

        Assert.areEqual(0, rp.ourBalance, 'matured RP must not count');
        Assert.isTrue(rp.hasDeal, 'a past deal still marks the family as dealt');
        Assert.areEqual(0, rp.share, 'share is 0 when nothing outstanding');
    }

    @IsTest
    static void shouldFallbackToLongTermBorrowings_WhenBondsPayableMissing() {
        Account account = theAccount();
        RadarTestDataFactory.createStatements(new List<Account>{ account }, 2026, 1, 2000 * EOK, null, 800 * EOK, 0, 0);
        Date today = Date.today();
        insert RadarTestDataFactory.buildOpportunity(account, products().get('채권'), 200 * EOK, today.addYears(-1), null, true);

        Test.startTest();
        WalletShareService.FamilyWallet bond = WalletShareService.compute(new Set<Id>{ account.Id }, today).get(account.Id).byFamily.get('채권');
        Test.stopTest();

        Assert.areEqual(800 * EOK, bond.wallet, 'long-term borrowings used as bond wallet');
        Assert.areEqual('장기차입금(폴백)', bond.basis, 'basis must flag the fallback');
        Assert.areEqual(200 * EOK, bond.ourBalance, 'bond outstanding for 3 years');
        Assert.areEqual(0.25, bond.share, 'share = 200 / 800');
    }

    @IsTest
    static void shouldReturnNullWallets_WhenNoStatement() {
        Account account = theAccount();

        Test.startTest();
        WalletShareService.AccountWallet view = WalletShareService.compute(new Set<Id>{ account.Id }, Date.today()).get(account.Id);
        Test.stopTest();

        Assert.isNull(view.byFamily.get('RP').wallet, 'no statement → no wallet');
        Assert.isNull(view.share, 'no wallet → no share');
        Assert.areEqual('중견기업', view.segment, 'unknown assets default to 중견기업');
    }

    @IsTest
    static void shouldReturnEmpty_WhenInputEmpty() {
        Test.startTest();
        Map<Id, WalletShareService.AccountWallet> result = WalletShareService.compute(new Set<Id>(), null);
        Test.stopTest();
        Assert.areEqual(0, result.size(), 'empty input yields empty map');
    }

    @IsTest
    static void shouldComputeMaturityByFamilyRule() {
        Opportunity opportunity = new Opportunity(CloseDate = Date.newInstance(2026, 6, 10));
        Assert.areEqual(Date.newInstance(2026, 9, 9), WalletShareService.maturityOf(opportunity, 'RP'), 'RP default tenor 91 days');
        Assert.areEqual(Date.newInstance(2029, 6, 10), WalletShareService.maturityOf(opportunity, '채권'), 'bond tenor 3 years');
        Assert.isNull(WalletShareService.maturityOf(opportunity, '퇴직연금'), 'pension is perpetual');
    }
}