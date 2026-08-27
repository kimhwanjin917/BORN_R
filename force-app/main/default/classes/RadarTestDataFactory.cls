/**
 * Test data for the Opportunity Radar test classes. Creates only records the radar reads:
 * Account, Product2 (one per family), CorporateFinancialStatement__c, Opportunity, ExternalSignal__c, Asset.
 */
@IsTest
public class RadarTestDataFactory {
    public static final String INDUSTRY = '제조업';
    public static final Decimal EOK = 100000000;

    public static Map<String, Product2> createProducts() {
        Map<String, Product2> byFamily = new Map<String, Product2>{
            'RP' => new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true),
            '자금운용' => new Product2(Name = '법인 자금운용', Family = '자금운용', IsActive = true),
            '채권' => new Product2(Name = '회사채', Family = '채권', IsActive = true),
            '퇴직연금' => new Product2(Name = '퇴직연금', Family = '퇴직연금', IsActive = true),
            'IPO' => new Product2(Name = 'IPO 주선', Family = 'IPO', IsActive = true)
        };
        insert byFamily.values();
        return byFamily;
    }

    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(
                Name = 'Radar Test Account ' + i,
                Industry = INDUSTRY,
                Business_Registration_Number__c = String.valueOf(900000000 + i).leftPad(10, '0')
            ));
        }
        if (doInsert) {
            insert accounts;
        }
        return accounts;
    }

    /** One statement per account for the given year/quarter. Amounts in KRW. */
    public static List<CorporateFinancialStatement__c> createStatements(List<Account> accounts, Integer year, Integer quarter,
            Decimal totalAssets, Decimal bonds, Decimal longTermBorrowings, Decimal shortTermInstruments, Decimal cash) {
        List<CorporateFinancialStatement__c> statements = new List<CorporateFinancialStatement__c>();
        for (Account account : accounts) {
            statements.add(new CorporateFinancialStatement__c(
                Account__c = account.Id,
                External_Key__c = 'RADAR-' + account.Id + '-' + year + 'Q' + quarter,
                Fiscal_Year__c = year,
                Period_Type__c = quarter + '분기',
                Total_Assets__c = totalAssets,
                Bonds_Payable__c = bonds,
                Long_Term_Borrowings__c = longTermBorrowings,
                Short_Term_Financial_Instruments__c = shortTermInstruments,
                Cash_And_Equivalents__c = cash
            ));
        }
        insert statements;
        return statements;
    }

    public static Opportunity buildOpportunity(Account account, Product2 product, Decimal amount, Date closeDate, Date rpMaturity, Boolean won) {
        return new Opportunity(
            Name = account.Name + ' ' + product.Name,
            AccountId = account.Id,
            Primary_Product__c = product.Id,
            Amount = amount,
            CloseDate = closeDate,
            RP_Maturity_Date__c = rpMaturity,
            StageName = won ? 'Closed Won' : 'Closed Lost'
        );
    }

    public static ExternalSignal__c buildSignal(Account account, String type, Date signalDate, Date maturity) {
        return new ExternalSignal__c(
            Account__c = account.Id,
            External_Key__c = 'RADAR-SIG-' + account.Id + '-' + type + '-' + signalDate.format(),
            Signal_Type__c = type,
            Signal_Date__c = signalDate,
            Maturity_Date__c = maturity,
            Title__c = 'test signal'
        );
    }
}