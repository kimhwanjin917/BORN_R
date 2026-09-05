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
        Assert.areEqual(500 * EOK, rp.reportedWallet, 'reported RP wallet = 단기금융상품 + 현금 of latest quarter');
        Assert.areEqual(100 * EOK, rp.wallet, 'addressable RP wallet = 500억 × 20% target share');
        Assert.areEqual(100 * EOK, rp.ourBalance, 'RP won amount is outstanding before maturity');
        Assert.areEqual(1, rp.share, 'share = 100 / 100 addressable: we already hold the whole reachable slice');
        Assert.areEqual('성장기업', view.segment, '5,000억 total assets → 성장기업');
        Assert.areEqual(100 * EOK, view.expectedWallet, 'cash wallet counted once across RP/자금운용');
        Assert.areEqual(500 * EOK, view.reportedWallet, 'raw figure kept alongside the addressable one');
        Assert.areEqual(0, view.whitespace, 'whitespace floors at 0 once the addressable wallet is full');
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
        Assert.areEqual(50 * EOK, rp.maturedAmount, 'money that matured inside the trailing window is a rollover cue');
        Assert.areEqual(today.addDays(-29), rp.lastMaturedOn, 'the maturity date is kept for urgency ranking');
    }

    /**
     * A maturity on or before the close date cannot exist. Trusting it would mark the deal as
     * permanently repaid, dropping a live balance out of the wallet and out of any rollover proposal.
     */
    @IsTest
    static void shouldFallBackToStandardTenor_WhenMaturityPrecedesCloseDate() {
        Account account = theAccount();
        RadarTestDataFactory.createStatements(new List<Account>{ account }, 2026, 2, 1000 * EOK, 0, 0, 600 * EOK, 400 * EOK);
        Date today = Date.today();
        insert RadarTestDataFactory.buildOpportunity(account, products().get('RP'), 200 * EOK, today.addDays(-10), today.addDays(-200), true);

        Test.startTest();
        WalletShareService.FamilyWallet rp = WalletShareService.compute(new Set<Id>{ account.Id }, today).get(account.Id).byFamily.get('RP');
        Test.stopTest();

        Assert.areEqual(200 * EOK, rp.ourBalance, 'the impossible maturity is ignored, so the deal is still outstanding');
        Assert.areEqual(200 * EOK, rp.maturingAmount, 'standard tenor puts it inside the rollover window');
        Assert.areEqual(today.addDays(81), rp.nextMaturity, 'fallback maturity = close date + 91 days');
    }

    @IsTest
    static void shouldNotFlagMaturing_WhenMaturityIsBeyondTheWindow() {
        Account account = theAccount();
        RadarTestDataFactory.createStatements(new List<Account>{ account }, 2026, 2, 1000 * EOK, 0, 0, 600 * EOK, 400 * EOK);
        Date today = Date.today();
        insert RadarTestDataFactory.buildOpportunity(account, products().get('RP'), 300 * EOK, today.addDays(-10), today.addDays(200), true);

        Test.startTest();
        WalletShareService.FamilyWallet rp = WalletShareService.compute(new Set<Id>{ account.Id }, today).get(account.Id).byFamily.get('RP');
        Test.stopTest();

        Assert.areEqual(300 * EOK, rp.ourBalance, 'still outstanding');
        Assert.areEqual(0, rp.maturingAmount, 'a maturity 200 days out is not a rollover cue yet');
        Assert.isNull(rp.nextMaturity, 'nothing maturing inside the window');
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

        Assert.areEqual(800 * EOK, bond.reportedWallet, 'long-term borrowings used as reported bond wallet');
        Assert.areEqual(80 * EOK, bond.wallet, 'fallback wallet takes the extra 0.5 reach factor: 800 × 20% × 0.5');
        Assert.areEqual('장기차입금(폴백)', bond.basis, 'basis must flag the fallback');
        Assert.areEqual(200 * EOK, bond.ourBalance, 'bond outstanding for 3 years');
        Assert.areEqual(2.5, bond.share, 'share = 200 / 80: holding more than the reachable slice is reported, not clamped');
    }

    /**
     * 사채 is paper we can underwrite directly; 장기차입금 is bank debt we could only reach by refinancing
     * it. Same reported amount must therefore not yield the same addressable wallet.
     */
    @IsTest
    static void shouldDiscountFallbackWalletBelowBondWallet_WhenAmountsAreEqual() {
        Account issuer = theAccount();
        // a second account of our own: the shared setup inserts only one, and its BRN is already taken
        Account borrower = new Account(Name = 'Radar Fallback Account', Business_Registration_Number__c = '0899999999');
        insert borrower;
        RadarTestDataFactory.createStatements(new List<Account>{ issuer }, 2026, 1, 2000 * EOK, 800 * EOK, 0, 0, 0);
        RadarTestDataFactory.createStatements(new List<Account>{ borrower }, 2026, 1, 2000 * EOK, null, 800 * EOK, 0, 0);

        Test.startTest();
        Map<Id, WalletShareService.AccountWallet> views =
            WalletShareService.compute(new Set<Id>{ issuer.Id, borrower.Id }, Date.today());
        Test.stopTest();

        Assert.areEqual(160 * EOK, views.get(issuer.Id).byFamily.get('채권').wallet, '사채 800억 × 20%');
        Assert.areEqual(80 * EOK, views.get(borrower.Id).byFamily.get('채권').wallet, '장기차입금 800억 × 20% × 0.5');
        Assert.areEqual(800 * EOK, views.get(borrower.Id).byFamily.get('채권').reportedWallet, 'raw figure is untouched by the discount');
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

        Opportunity stated = new Opportunity(CloseDate = Date.newInstance(2026, 6, 10), RP_Maturity_Date__c = Date.newInstance(2026, 8, 1));
        Assert.areEqual(Date.newInstance(2026, 8, 1), WalletShareService.maturityOf(stated, 'RP'), 'a valid stated maturity wins');

        Opportunity backwards = new Opportunity(CloseDate = Date.newInstance(2026, 6, 10), RP_Maturity_Date__c = Date.newInstance(2025, 5, 4));
        Assert.areEqual(Date.newInstance(2026, 9, 9), WalletShareService.maturityOf(backwards, 'RP'), 'a maturity before the close date falls back to the standard tenor');
    }
}