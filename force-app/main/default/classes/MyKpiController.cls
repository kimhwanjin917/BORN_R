/**
 * Personal KPI figures for the running user: second-half fee revenue against
 * target and new accounts won against target.
 *
 * Fee revenue — not deal amount — is the performance measure here: a large
 * deal on a low-margin product earns less than a small deal on a high-margin
 * one, so measuring on amount would reward the wrong behaviour. See CONTEXT.md.
 */
public with sharing class MyKpiController {

    /**
     * The two figures behind one KPI card, plus the labels the card needs.
     */
    public class MyKpi {
        @AuraEnabled public String periodLabel;

        @AuraEnabled public Decimal feeRevenue;
        @AuraEnabled public Decimal feeTarget;
        @AuraEnabled public Integer feePercent;

        @AuraEnabled public Integer newAccounts;
        @AuraEnabled public Integer newAccountTarget;
        @AuraEnabled public Integer newAccountPercent;
    }

    /**
     * Half-year bounds plus the label the card shows.
     */
    private class PerformancePeriod {
        Date startDate;
        Date endDate;
        String key;
        String label;
    }

    /**
     * Returns the running user's KPI for the half-year containing today.
     *
     * @return KPI figures for the running user.
     * @example
     * MyKpiController.MyKpi kpi = MyKpiController.getMyKpi();
     */
    @AuraEnabled(cacheable=true)
    public static MyKpi getMyKpi() {
        try {
            Id meId = UserInfo.getUserId();
            PerformancePeriod current = halfYearOf(Date.today());

            MyKpi kpi = new MyKpi();
            kpi.periodLabel = current.label;

            // Targets come from metadata so they can change without a code edit.
            KPI_Target__mdt target = targetFor(current.key);
            kpi.feeTarget = target == null ? 0 : target.Target_Fee__c;
            kpi.newAccountTarget = target == null ? 0 : Integer.valueOf(target.Target_New_Accounts__c);

            Decimal feeRevenue = 0;
            for (Opportunity opp : [
                SELECT Amount, Primary_Product__r.Default_Fee_Rate__c
                FROM Opportunity
                WHERE IsWon = true
                  AND OwnerId = :meId
                  AND CloseDate >= :current.startDate
                  AND CloseDate <= :current.endDate
                WITH USER_MODE
            ]) {
                feeRevenue += feeOf(opp);
            }

            kpi.feeRevenue = feeRevenue;
            kpi.feePercent = percentOf(kpi.feeRevenue, kpi.feeTarget);

            kpi.newAccounts = [
                SELECT COUNT()
                FROM Account
                WHERE OwnerId = :meId
                  AND CreatedDate >= :Datetime.newInstance(current.startDate, Time.newInstance(0, 0, 0, 0))
                  AND CreatedDate < :Datetime.newInstance(current.endDate.addDays(1), Time.newInstance(0, 0, 0, 0))
                WITH USER_MODE
            ];
            kpi.newAccountPercent = percentOf(kpi.newAccounts, kpi.newAccountTarget);

            return kpi;
        } catch (Exception e) {
            throw new AuraHandledException('KPI를 불러오지 못했습니다: ' + e.getMessage());
        }
    }

    /**
     * Fee revenue earned on one won deal, from the product's own rate.
     * Deals with no product or no rate earn nothing rather than defaulting
     * to a house rate that would silently misstate the figure.
     */
    private static Decimal feeOf(Opportunity opp) {
        if (opp.Amount == null || opp.Primary_Product__r == null) {
            return 0;
        }
        Decimal rate = opp.Primary_Product__r.Default_Fee_Rate__c;
        return rate == null ? 0 : opp.Amount * rate / 100;
    }

    private static KPI_Target__mdt targetFor(String periodKey) {
        List<KPI_Target__mdt> targets = [
            SELECT Period__c, Target_Fee__c, Target_New_Accounts__c
            FROM KPI_Target__mdt
            WHERE Period__c = :periodKey
            LIMIT 1
        ];
        return targets.isEmpty() ? null : targets[0];
    }

    private static Integer percentOf(Decimal value, Decimal target) {
        if (target == null || target <= 0) {
            return 0;
        }
        return (value / target * 100).setScale(0, System.RoundingMode.HALF_UP).intValue();
    }

    /**
     * The half-year containing the given date.
     */
    private static PerformancePeriod halfYearOf(Date d) {
        Integer half = d.month() <= 6 ? 1 : 2;
        Integer startMonth = half == 1 ? 1 : 7;
        Date startDate = Date.newInstance(d.year(), startMonth, 1);

        PerformancePeriod period = new PerformancePeriod();
        period.startDate = startDate;
        period.endDate = startDate.addMonths(6).addDays(-1);
        period.key = String.valueOf(d.year()) + '-H' + half;
        period.label = String.valueOf(d.year()) + (half == 1 ? ' 상반기' : ' 하반기');
        return period;
    }
}