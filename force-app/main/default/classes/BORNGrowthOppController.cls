/**
 * Read-only controller for the "고객 성장 기회 분석" LWC (bornGrowthOpportunity).
 * Surfaces, per Account: base profile, an ESTIMATED investable-funds proxy from
 * real financial statements, Closed Won product mix, product whitespace vs the
 * Product2 catalog, and existing Recommendation__c review flags.
 *
 * No wallet-share %, success %, or predicted amounts are produced — the Org has
 * no data to support those. All queries are read-only.
 */
public with sharing class BORNGrowthOppController {

    public class AccountOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class TrendPoint {
        @AuraEnabled public String label;
        @AuraEnabled public Decimal cash;
        @AuraEnabled public Decimal shortTerm;
    }

    public class ProductLine {
        @AuraEnabled public String name;
        @AuraEnabled public String family;
        @AuraEnabled public Decimal amount;
    }

    public class AnalysisResult {
        // 1. profile
        @AuraEnabled public String accountName;
        @AuraEnabled public String industry;
        @AuraEnabled public Decimal annualRevenue;
        @AuraEnabled public Integer numberOfEmployees;
        // 2. estimated wallet
        @AuraEnabled public Decimal cash;
        @AuraEnabled public Decimal shortTerm;
        @AuraEnabled public Decimal estimatedInvestableFunds;
        @AuraEnabled public Decimal closedWonAmount;
        @AuraEnabled public Decimal whitespaceProxy;
        @AuraEnabled public Boolean hasProxy;
        @AuraEnabled public String latestPeriodLabel;
        @AuraEnabled public Boolean hasFinancials;
        // 3. trend
        @AuraEnabled public List<TrendPoint> trend;
        // 4/5. products
        @AuraEnabled public List<ProductLine> ownedProducts;
        @AuraEnabled public List<String> whitespaceProducts;
        // 6. recommendations
        @AuraEnabled public Boolean hasUpsell;
        @AuraEnabled public Boolean hasCrossSell;
        @AuraEnabled public Integer upsellCount;
        @AuraEnabled public Integer crossSellCount;
    }

    @AuraEnabled(cacheable=true)
    public static List<AccountOption> getAccounts() {
        List<AccountOption> options = new List<AccountOption>();
        for (Account a : [
            SELECT Id, Name FROM Account ORDER BY Name ASC LIMIT 200
        ]) {
            AccountOption o = new AccountOption();
            o.label = a.Name;
            o.value = a.Id;
            options.add(o);
        }
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static AnalysisResult getAnalysis(Id accountId) {
        AnalysisResult r = new AnalysisResult();

        // --- 1. profile ---
        Account acc = [
            SELECT Name, Industry, AnnualRevenue, NumberOfEmployees
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        r.accountName = acc.Name;
        r.industry = acc.Industry;
        r.annualRevenue = acc.AnnualRevenue;
        r.numberOfEmployees = acc.NumberOfEmployees;

        // --- 2/3. financials (quarterly time series) ---
        List<CorporateFinancialStatement__c> fins = [
            SELECT Fiscal_Year__c, Period_Type__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c
            FROM CorporateFinancialStatement__c
            WHERE Account__c = :accountId
            ORDER BY Fiscal_Year__c ASC, Period_Type__c ASC
        ];
        r.trend = new List<TrendPoint>();
        r.hasFinancials = !fins.isEmpty();
        for (CorporateFinancialStatement__c f : fins) {
            TrendPoint p = new TrendPoint();
            Integer fy = (f.Fiscal_Year__c == null) ? null : Integer.valueOf(f.Fiscal_Year__c);
            p.label = (fy == null ? '' : String.valueOf(fy)) +
                      (f.Period_Type__c == null ? '' : ' ' + f.Period_Type__c);
            p.cash = f.Cash_And_Equivalents__c;
            p.shortTerm = f.Short_Term_Financial_Instruments__c;
            r.trend.add(p);
        }
        if (!fins.isEmpty()) {
            CorporateFinancialStatement__c latest = fins[fins.size() - 1];
            r.cash = latest.Cash_And_Equivalents__c;
            r.shortTerm = latest.Short_Term_Financial_Instruments__c;
            r.latestPeriodLabel = r.trend[r.trend.size() - 1].label;
            Decimal c = (latest.Cash_And_Equivalents__c == null) ? 0 : latest.Cash_And_Equivalents__c;
            Decimal s = (latest.Short_Term_Financial_Instruments__c == null) ? 0 : latest.Short_Term_Financial_Instruments__c;
            r.estimatedInvestableFunds = c + s;
        }

        // --- 4. current Closed Won products ---
        r.ownedProducts = new List<ProductLine>();
        Decimal wonTotal = 0;
        Set<String> ownedNames = new Set<String>();
        for (Opportunity o : [
            SELECT Amount, Primary_Product__r.Name, Product_Family__c
            FROM Opportunity
            WHERE AccountId = :accountId AND IsWon = true
            ORDER BY Amount DESC NULLS LAST
        ]) {
            ProductLine pl = new ProductLine();
            pl.name = (o.Primary_Product__r == null) ? null : o.Primary_Product__r.Name;
            pl.family = o.Product_Family__c;
            pl.amount = o.Amount;
            r.ownedProducts.add(pl);
            if (o.Amount != null) { wonTotal += o.Amount; }
            if (pl.name != null) { ownedNames.add(pl.name); }
        }
        r.closedWonAmount = wonTotal;

        // proxy: only when financials exist and result is non-negative
        r.hasProxy = false;
        if (r.estimatedInvestableFunds != null && r.estimatedInvestableFunds > 0) {
            Decimal proxy = r.estimatedInvestableFunds - wonTotal;
            if (proxy >= 0) {
                r.whitespaceProxy = proxy;
                r.hasProxy = true;
            }
        }

        // --- 5. product whitespace vs catalog (real financial products only) ---
        r.whitespaceProducts = new List<String>();
        for (Product2 p : [
            SELECT Name FROM Product2
            WHERE IsActive = true AND Family != null
            ORDER BY Name ASC
        ]) {
            if (!ownedNames.contains(p.Name)) {
                r.whitespaceProducts.add(p.Name);
            }
        }

        // --- 6. recommendation review flags ---
        r.upsellCount = 0;
        r.crossSellCount = 0;
        for (AggregateResult ar : [
            SELECT Type__c t, COUNT(Id) c
            FROM Recommendation__c
            WHERE Account__c = :accountId
            GROUP BY Type__c
        ]) {
            String t = (String) ar.get('t');
            Integer c = (Integer) ar.get('c');
            if (t == '업셀') { r.upsellCount = c; }
            else if (t == '크로스셀') { r.crossSellCount = c; }
        }
        r.hasUpsell = r.upsellCount > 0;
        r.hasCrossSell = r.crossSellCount > 0;

        return r;
    }
}