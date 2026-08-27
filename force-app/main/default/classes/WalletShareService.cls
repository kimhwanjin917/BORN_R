/**
 * Computes customer wallet, our outstanding balance and wallet share per product family
 * (docs/54 definition ported from the Tableau workbook, extended to 5 families in docs/55).
 *
 * Wallet (denominator) comes from the latest CorporateFinancialStatement__c of the account:
 *  - RP / 자금운용 share the "cash wallet" = 단기금융상품 + 현금및현금성자산
 *  - 채권 = 사채, falling back to 장기차입금 when 사채 is empty (basis is reported)
 *  - 퇴직연금 / IPO have no statement-derived wallet (wallet = null)
 * Our balance (numerator) = Won Opportunity Amount outstanding as of the reference date:
 *  closeDate <= asOf < maturity, where maturity = RP만기일 (or +91d) for RP/자금운용, +3y for 채권, none for 퇴직연금.
 *
 * Read-only: no DML. All SOQL runs in USER_MODE.
 */
public with sharing class WalletShareService {
    public static final String FAMILY_RP = 'RP';
    public static final String FAMILY_CASH_MGMT = '자금운용';
    public static final String FAMILY_BOND = '채권';
    public static final String FAMILY_PENSION = '퇴직연금';
    public static final String FAMILY_IPO = 'IPO';
    public static final List<String> WALLET_FAMILIES = new List<String>{ FAMILY_RP, FAMILY_CASH_MGMT, FAMILY_BOND, FAMILY_PENSION };

    private static final Integer DEFAULT_RP_TENOR_DAYS = 91;
    private static final Integer BOND_TENOR_YEARS = 3;
    private static final Map<String, Integer> QUARTER_BY_PERIOD = new Map<String, Integer>{ '1분기' => 1, '2분기' => 2, '3분기' => 3, '4분기' => 4 };

    /** Wallet figures for one account × product family. */
    public class FamilyWallet {
        @AuraEnabled public String family;
        @AuraEnabled public Decimal wallet;        // null when not derivable
        @AuraEnabled public Decimal ourBalance = 0;
        @AuraEnabled public Decimal share;         // 0..1, null when wallet is null/0
        @AuraEnabled public String basis;          // e.g. '단기금융상품+현금', '사채', '장기차입금(폴백)'
        @AuraEnabled public Boolean hasDeal = false;
    }

    /** Aggregated wallet view for one account. */
    public class AccountWallet {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String industry;
        @AuraEnabled public Decimal totalAssets;
        @AuraEnabled public Decimal priorityScore;      // Account.Priority_Score__c (RM priority, may be null)
        @AuraEnabled public Decimal priorCashWallet;    // cash wallet ~4 quarters earlier (null if unavailable)
        @AuraEnabled public Decimal priorDebtWallet;    // bonds+long-term borrowings ~4 quarters earlier
        @AuraEnabled public Decimal latestDebtWallet;   // bonds+long-term borrowings of the latest statement
        @AuraEnabled public String segment;
        @AuraEnabled public String statementPeriod;   // e.g. '2026 Q2'
        @AuraEnabled public Decimal expectedWallet = 0; // sum of derivable wallets (cash counted once)
        @AuraEnabled public Decimal ourBalance = 0;
        @AuraEnabled public Decimal whitespace = 0;
        @AuraEnabled public Decimal share;             // ourBalance / expectedWallet
        @AuraEnabled public Map<String, FamilyWallet> byFamily = new Map<String, FamilyWallet>();
    }

    /**
     * @param accountIds accounts to evaluate
     * @param asOf reference date for outstanding balances (defaults to today)
     * @return wallet view per account id (accounts without a statement are still returned with null wallets)
     */
    public static Map<Id, AccountWallet> compute(Set<Id> accountIds, Date asOf) {
        Map<Id, AccountWallet> result = new Map<Id, AccountWallet>();
        if (accountIds == null || accountIds.isEmpty()) {
            return result;
        }
        Date referenceDate = asOf ?? Date.today();

        for (Account account : [
            SELECT Id, Name, Industry, Priority_Score__c FROM Account WHERE Id IN :accountIds WITH USER_MODE LIMIT 2000
        ]) {
            AccountWallet view = new AccountWallet();
            view.accountId = account.Id;
            view.accountName = account.Name;
            view.industry = account.Industry;
            view.priorityScore = account.Priority_Score__c;
            for (String family : WALLET_FAMILIES) {
                FamilyWallet familyWallet = new FamilyWallet();
                familyWallet.family = family;
                view.byFamily.put(family, familyWallet);
            }
            result.put(account.Id, view);
        }

        applyLatestStatements(result);
        applyOutstandingBalances(result, referenceDate);
        finalizeTotals(result);
        return result;
    }

    /** Picks the latest statement (by year, quarter) per account and fills wallets. */
    private static void applyLatestStatements(Map<Id, AccountWallet> views) {
        Map<Id, CorporateFinancialStatement__c> latestByAccount = new Map<Id, CorporateFinancialStatement__c>();
        Map<Id, List<CorporateFinancialStatement__c>> historyByAccount = new Map<Id, List<CorporateFinancialStatement__c>>();
        for (CorporateFinancialStatement__c statement : [
            SELECT Account__c, Fiscal_Year__c, Period_Type__c, Total_Assets__c, Bonds_Payable__c,
                   Long_Term_Borrowings__c, Short_Term_Financial_Instruments__c, Cash_And_Equivalents__c
            FROM CorporateFinancialStatement__c
            WHERE Account__c IN :views.keySet() AND Fiscal_Year__c != null AND Period_Type__c != null
            WITH USER_MODE
            ORDER BY Fiscal_Year__c DESC
            LIMIT 5000
        ]) {
            CorporateFinancialStatement__c current = latestByAccount.get(statement.Account__c);
            if (current == null || rank(statement) > rank(current)) {
                latestByAccount.put(statement.Account__c, statement);
            }
            List<CorporateFinancialStatement__c> history = historyByAccount.get(statement.Account__c);
            if (history == null) {
                history = new List<CorporateFinancialStatement__c>();
                historyByAccount.put(statement.Account__c, history);
            }
            history.add(statement);
        }

        for (Id accountId : latestByAccount.keySet()) {
            CorporateFinancialStatement__c statement = latestByAccount.get(accountId);
            AccountWallet view = views.get(accountId);
            view.totalAssets = statement.Total_Assets__c;
            view.segment = RadarSettings.segmentFor(statement.Total_Assets__c);
            view.statementPeriod = statement.Fiscal_Year__c.intValue() + ' Q' + QUARTER_BY_PERIOD.get(statement.Period_Type__c);
            view.latestDebtWallet = (statement.Bonds_Payable__c ?? 0) + (statement.Long_Term_Borrowings__c ?? 0);
            CorporateFinancialStatement__c prior = priorStatement(historyByAccount.get(accountId), rank(statement));
            if (prior != null) {
                view.priorCashWallet = (prior.Short_Term_Financial_Instruments__c ?? 0) + (prior.Cash_And_Equivalents__c ?? 0);
                view.priorDebtWallet = (prior.Bonds_Payable__c ?? 0) + (prior.Long_Term_Borrowings__c ?? 0);
            }

            Decimal cashWallet = (statement.Short_Term_Financial_Instruments__c ?? 0) + (statement.Cash_And_Equivalents__c ?? 0);
            setWallet(view.byFamily.get(FAMILY_RP), cashWallet, '단기금융상품+현금');
            setWallet(view.byFamily.get(FAMILY_CASH_MGMT), cashWallet, '단기금융상품+현금');
            if (statement.Bonds_Payable__c != null && statement.Bonds_Payable__c > 0) {
                setWallet(view.byFamily.get(FAMILY_BOND), statement.Bonds_Payable__c, '사채');
            } else if (statement.Long_Term_Borrowings__c != null && statement.Long_Term_Borrowings__c > 0) {
                setWallet(view.byFamily.get(FAMILY_BOND), statement.Long_Term_Borrowings__c, '장기차입금(폴백)');
            }
        }
        for (AccountWallet view : views.values()) {
            if (view.segment == null) {
                view.segment = RadarSettings.segmentFor(null);
            }
        }
    }

    /** Statement closest to four quarters before the latest one (falls back to the oldest available, never the latest itself). */
    private static CorporateFinancialStatement__c priorStatement(List<CorporateFinancialStatement__c> history, Long latestRank) {
        Long targetRank = latestRank - 10;
        CorporateFinancialStatement__c best;
        Long bestDistance;
        for (CorporateFinancialStatement__c statement : history) {
            Long statementRank = rank(statement);
            if (statementRank >= latestRank) {
                continue;
            }
            Long distance = Math.abs(statementRank - targetRank);
            if (best == null || distance < bestDistance) {
                best = statement;
                bestDistance = distance;
            }
        }
        return best;
    }

    private static void setWallet(FamilyWallet familyWallet, Decimal amount, String basis) {
        familyWallet.wallet = amount;
        familyWallet.basis = basis;
    }

    private static Long rank(CorporateFinancialStatement__c statement) {
        Integer quarter = QUARTER_BY_PERIOD.get(statement.Period_Type__c) ?? 0;
        return (Long) statement.Fiscal_Year__c.intValue() * 10 + quarter;
    }

    /** Sums Won amounts still outstanding at the reference date into the matching family. */
    private static void applyOutstandingBalances(Map<Id, AccountWallet> views, Date asOf) {
        for (Opportunity opportunity : [
            SELECT AccountId, Amount, CloseDate, RP_Maturity_Date__c, Primary_Product__r.Family
            FROM Opportunity
            WHERE AccountId IN :views.keySet() AND IsWon = true AND Amount != null AND Primary_Product__c != null
            WITH USER_MODE
            LIMIT 10000
        ]) {
            String family = opportunity.Primary_Product__r.Family;
            AccountWallet view = views.get(opportunity.AccountId);
            FamilyWallet familyWallet = view.byFamily.get(family);
            if (familyWallet == null) {
                continue;
            }
            familyWallet.hasDeal = true;
            if (isOutstanding(opportunity, family, asOf)) {
                familyWallet.ourBalance += opportunity.Amount;
            }
        }
    }

    /**
     * @return true when the deal was closed on/before asOf and matures after asOf
     */
    public static Boolean isOutstanding(Opportunity opportunity, String family, Date asOf) {
        if (opportunity.CloseDate == null || opportunity.CloseDate > asOf) {
            return false;
        }
        Date maturity = maturityOf(opportunity, family);
        return maturity == null || maturity > asOf;
    }

    /**
     * @return maturity date by family rule; null means perpetual
     */
    public static Date maturityOf(Opportunity opportunity, String family) {
        if (family == FAMILY_RP || family == FAMILY_CASH_MGMT) {
            return opportunity.RP_Maturity_Date__c ?? opportunity.CloseDate.addDays(DEFAULT_RP_TENOR_DAYS);
        }
        if (family == FAMILY_BOND) {
            return opportunity.CloseDate.addYears(BOND_TENOR_YEARS);
        }
        return null;
    }

    private static void finalizeTotals(Map<Id, AccountWallet> views) {
        for (AccountWallet view : views.values()) {
            Decimal expected = 0;
            Decimal ours = 0;
            Boolean cashCounted = false;
            for (FamilyWallet familyWallet : view.byFamily.values()) {
                ours += familyWallet.ourBalance;
                if (familyWallet.wallet != null && familyWallet.wallet > 0) {
                    familyWallet.share = familyWallet.ourBalance / familyWallet.wallet;
                    Boolean isCash = familyWallet.family == FAMILY_RP || familyWallet.family == FAMILY_CASH_MGMT;
                    if (!isCash || !cashCounted) {
                        expected += familyWallet.wallet;
                    }
                    if (isCash) {
                        cashCounted = true;
                    }
                }
            }
            view.expectedWallet = expected;
            view.ourBalance = ours;
            view.whitespace = Math.max(expected - ours, 0);
            view.share = expected > 0 ? ours / expected : null;
        }
    }
}