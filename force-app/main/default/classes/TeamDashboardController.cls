/**
 * Team-level KPI summary for a manager's RM team — block 1 of the RM team
 * management dashboard (팀장 전용).
 *
 * The team is the set of RMs whose user role sits directly under the running
 * manager's role (UserRole.ParentRoleId), matching how BoniDashboardService
 * resolves a manager's team. When the running user has no subordinate roles the
 * figures fall back to the running user's own records, so the card is never
 * empty for an individual contributor previewing the page.
 *
 * Fee revenue — not deal amount — is the money figure, from the product's own
 * default rate (Amount × Primary_Product__r.Default_Fee_Rate__c / 100). A large
 * deal on a low-margin product is worth less than a small one on a high-margin
 * product, so amount would misstate performance. This mirrors MyKpiController
 * and OpportunityKpiController. See CONTEXT.md.
 */
public with sharing class TeamDashboardController {

    // An open deal with no contact for longer than this many days is "at risk".
    private static final Integer RISK_DAYS = 14;

    /**
     * One RM's contribution to the team, for the "RM 수익 TOP5" ranking.
     */
    public class RmRow {
        @AuraEnabled public Id rmId;
        @AuraEnabled public String rmName;
        @AuraEnabled public Decimal achievedFee;
        @AuraEnabled public Integer openDeals;
        @AuraEnabled public Integer newOpps;

        RmRow(Id rmId, String rmName) {
            this.rmId = rmId;
            this.rmName = rmName;
            this.achievedFee = 0;
            this.openDeals = 0;
            this.newOpps = 0;
        }
    }

    /**
     * One slice of the stage donut: an active stage and what sits in it.
     */
    public class StageSlice {
        @AuraEnabled public String stageName;
        @AuraEnabled public Integer count;
        @AuraEnabled public Decimal feeRevenue;
        @AuraEnabled public Boolean isWon;

        StageSlice(String stageName, Boolean isWon) {
            this.stageName = stageName;
            this.isWon = isWon;
            this.count = 0;
            this.feeRevenue = 0;
        }
    }

    /**
     * The full block-1 payload: headline KPIs, the RM ranking, and the stage
     * donut, plus the labels the card needs.
     */
    public class TeamSummary {
        @AuraEnabled public String periodLabel;
        @AuraEnabled public Integer teamSize;

        @AuraEnabled public Decimal teamTargetFee;
        @AuraEnabled public Decimal teamAchievedFee;
        @AuraEnabled public Integer achievementPercent;

        @AuraEnabled public Decimal expectedFee;
        @AuraEnabled public Integer openDealCount;
        @AuraEnabled public Integer newOppCount;
        @AuraEnabled public Integer riskDealCount;
        @AuraEnabled public Integer avgConversionPercent;

        @AuraEnabled public List<RmRow> rmRanking;
        @AuraEnabled public List<StageSlice> stageSlices;

        TeamSummary() {
            this.teamTargetFee = 0;
            this.teamAchievedFee = 0;
            this.achievementPercent = 0;
            this.expectedFee = 0;
            this.openDealCount = 0;
            this.newOppCount = 0;
            this.riskDealCount = 0;
            this.avgConversionPercent = 0;
            this.rmRanking = new List<RmRow>();
            this.stageSlices = new List<StageSlice>();
        }
    }

    /**
     * Half-year bounds plus the KPI target key and the label the card shows.
     */
    private class PerformancePeriod {
        Date startDate;
        Date endDate;
        String key;
        String label;
    }

    /**
     * Returns the running manager's team KPI summary for the half-year
     * containing today.
     *
     * @return The block-1 figures for the manager's team.
     * @example
     * TeamDashboardController.TeamSummary summary = TeamDashboardController.getTeamSummary();
     */
    @AuraEnabled(cacheable=true)
    public static TeamSummary getTeamSummary() {
        try {
            PerformancePeriod current = halfYearOf(Date.today());
            List<Id> memberIds = resolveTeamMemberIds();

            TeamSummary summary = new TeamSummary();
            summary.periodLabel = current.label;
            summary.teamSize = memberIds.size();

            KPI_Target__mdt target = targetFor(current.key);
            summary.teamTargetFee = target == null || target.Target_Fee__c == null ? 0 : target.Target_Fee__c;

            Map<Id, RmRow> rowsByRm = rmRowsFor(memberIds);

            summary.teamAchievedFee = accumulateWonFee(memberIds, current, rowsByRm);
            summary.newOppCount = accumulateNewOpps(memberIds, current, rowsByRm);

            summary.stageSlices = buildStageSlices();
            populatePipeline(memberIds, summary, rowsByRm);

            summary.achievementPercent = percentOf(summary.teamAchievedFee, summary.teamTargetFee);
            summary.avgConversionPercent = conversionPercent(memberIds, current);
            summary.rmRanking = topRms(rowsByRm.values());

            return summary;
        } catch (Exception e) {
            throw new AuraHandledException('팀 대시보드를 불러오지 못했습니다: ' + e.getMessage());
        }
    }

    /**
     * The RMs whose role sits directly under the running manager's role. Falls
     * back to the running user when there are no subordinate roles.
     */
    private static List<Id> resolveTeamMemberIds() {
        Id meId = UserInfo.getUserId();
        List<Id> ids = new List<Id>();
        // Role-hierarchy resolution runs in system mode: UserRoleId and
        // UserRole.ParentRoleId are org-structure fields that USER_MODE blocks
        // without "View Roles and Role Hierarchy", which RMs/managers lack. The
        // record queries below stay in USER_MODE, where FLS actually matters.
        User me = [SELECT UserRoleId FROM User WHERE Id = :meId LIMIT 1];
        if (me.UserRoleId != null) {
            for (User u : [
                SELECT Id FROM User
                WHERE IsActive = true AND UserRole.ParentRoleId = :me.UserRoleId
            ]) {
                ids.add(u.Id);
            }
        }
        if (ids.isEmpty()) {
            ids.add(meId);
        }
        return ids;
    }

    /**
     * A blank ranking row per team member, keyed by user id, so every RM shows
     * up even with no deals yet.
     */
    private static Map<Id, RmRow> rmRowsFor(List<Id> memberIds) {
        Map<Id, RmRow> rowsByRm = new Map<Id, RmRow>();
        for (User u : [SELECT Id, Name FROM User WHERE Id IN :memberIds WITH USER_MODE]) {
            rowsByRm.put(u.Id, new RmRow(u.Id, u.Name));
        }
        return rowsByRm;
    }

    /**
     * Adds up won fee revenue for the period across the team and per RM.
     */
    private static Decimal accumulateWonFee(
        List<Id> memberIds,
        PerformancePeriod period,
        Map<Id, RmRow> rowsByRm
    ) {
        Decimal teamFee = 0;
        for (Opportunity opp : [
            SELECT OwnerId, Amount, Primary_Product__r.Default_Fee_Rate__c
            FROM Opportunity
            WHERE IsWon = true
              AND OwnerId IN :memberIds
              AND CloseDate >= :period.startDate
              AND CloseDate <= :period.endDate
            WITH USER_MODE
        ]) {
            Decimal fee = feeOf(opp);
            teamFee += fee;
            RmRow row = rowsByRm.get(opp.OwnerId);
            if (row != null) {
                row.achievedFee += fee;
            }
        }
        return teamFee;
    }

    /**
     * Counts opportunities created within the period across the team and per RM.
     */
    private static Integer accumulateNewOpps(
        List<Id> memberIds,
        PerformancePeriod period,
        Map<Id, RmRow> rowsByRm
    ) {
        Datetime periodStart = Datetime.newInstance(period.startDate, Time.newInstance(0, 0, 0, 0));
        Datetime periodEnd = Datetime.newInstance(period.endDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        Integer total = 0;
        for (Opportunity opp : [
            SELECT OwnerId
            FROM Opportunity
            WHERE OwnerId IN :memberIds
              AND CreatedDate >= :periodStart
              AND CreatedDate < :periodEnd
            WITH USER_MODE
        ]) {
            total++;
            RmRow row = rowsByRm.get(opp.OwnerId);
            if (row != null) {
                row.newOpps++;
            }
        }
        return total;
    }

    /**
     * One slice per active stage, closed-lost excluded, in sort order — so a gap
     * in the middle of the funnel is visible on the donut.
     */
    private static List<StageSlice> buildStageSlices() {
        List<StageSlice> slices = new List<StageSlice>();
        for (OpportunityStage stage : [
            SELECT MasterLabel, IsWon, IsClosed
            FROM OpportunityStage
            WHERE IsActive = true
            WITH USER_MODE
            ORDER BY SortOrder NULLS LAST
        ]) {
            if (stage.IsClosed && !stage.IsWon) {
                continue;
            }
            slices.add(new StageSlice(stage.MasterLabel, stage.IsWon));
        }
        return slices;
    }

    /**
     * Fills the open-pipeline figures: open deal count, probability-weighted
     * expected fee, at-risk count, the stage donut, and per-RM open counts.
     *
     * The population is open deals plus deals won this quarter, so the donut's
     * won slice does not grow without bound as the year goes on; lost deals are
     * left out entirely.
     */
    private static void populatePipeline(
        List<Id> memberIds,
        TeamSummary summary,
        Map<Id, RmRow> rowsByRm
    ) {
        Date today = Date.today();
        Date quarterStart = quarterStartOf(today);
        Date quarterEnd = quarterStart.addMonths(3).addDays(-1);

        Map<String, StageSlice> slicesByStage = new Map<String, StageSlice>();
        for (StageSlice slice : summary.stageSlices) {
            slicesByStage.put(slice.stageName, slice);
        }

        for (Opportunity opp : [
            SELECT OwnerId, StageName, Amount, Probability, CloseDate, IsClosed,
                   CreatedDate, Last_Meeting_Date__c, Primary_Product__r.Default_Fee_Rate__c
            FROM Opportunity
            WHERE OwnerId IN :memberIds
              AND (
                  IsClosed = false
                  OR (IsWon = true AND CloseDate >= :quarterStart AND CloseDate <= :quarterEnd)
              )
            WITH USER_MODE
        ]) {
            Decimal fee = feeOf(opp);
            StageSlice slice = slicesByStage.get(opp.StageName);
            if (slice != null) {
                slice.count++;
                slice.feeRevenue += fee;
            }

            if (opp.IsClosed) {
                continue;
            }

            summary.openDealCount++;
            RmRow row = rowsByRm.get(opp.OwnerId);
            if (row != null) {
                row.openDeals++;
            }

            Decimal probability = opp.Probability == null ? 0 : opp.Probability;
            summary.expectedFee += fee * probability / 100;

            Integer sinceContact = lastTouchOf(opp).daysBetween(today);
            if (sinceContact > RISK_DAYS) {
                summary.riskDealCount++;
            }
        }
    }

    /**
     * Team conversion rate for the period: deals won as a share of deals closed
     * (won + lost). Returns 0 when nothing closed, rather than dividing by zero.
     */
    private static Integer conversionPercent(List<Id> memberIds, PerformancePeriod period) {
        Integer won = 0;
        Integer closed = 0;
        // Bind plain locals, not member expressions (:period.startDate): an
        // aggregate GROUP BY under WITH USER_MODE that binds an object field
        // throws "Variable does not exist: tmpVarN" on the platform.
        Date periodStartDate = period.startDate;
        Date periodEndDate = period.endDate;
        for (AggregateResult ar : [
            SELECT IsWon won, COUNT(Id) total
            FROM Opportunity
            WHERE IsClosed = true
              AND OwnerId IN :memberIds
              AND CloseDate >= :periodStartDate
              AND CloseDate <= :periodEndDate
            WITH USER_MODE
            GROUP BY IsWon
        ]) {
            Integer count = (Integer) ar.get('total');
            closed += count;
            if ((Boolean) ar.get('won')) {
                won += count;
            }
        }
        return closed == 0 ? 0 : (Decimal.valueOf(won) / closed * 100).setScale(0, System.RoundingMode.HALF_UP).intValue();
    }

    /**
     * The team's RMs ranked by achieved fee, highest first, capped at five.
     */
    private static List<RmRow> topRms(List<RmRow> rows) {
        List<RmRow> sorted = new List<RmRow>(rows);
        sorted.sort(new ByAchievedFeeDesc());
        List<RmRow> top = new List<RmRow>();
        for (RmRow row : sorted) {
            if (top.size() == 5) {
                break;
            }
            top.add(row);
        }
        return top;
    }

    /**
     * Orders RM rows by achieved fee, highest first.
     */
    private class ByAchievedFeeDesc implements Comparator<RmRow> {
        public Integer compare(RmRow a, RmRow b) {
            if (a.achievedFee == b.achievedFee) {
                return 0;
            }
            return a.achievedFee > b.achievedFee ? -1 : 1;
        }
    }

    /**
     * Fee revenue on one deal, from the product's own rate. Deals with no
     * product or no rate earn nothing rather than defaulting to a house rate
     * that would silently misstate the figure. Mirrors MyKpiController.
     */
    private static Decimal feeOf(Opportunity opp) {
        if (opp.Amount == null || opp.Primary_Product__r == null) {
            return 0;
        }
        Decimal rate = opp.Primary_Product__r.Default_Fee_Rate__c;
        return rate == null ? 0 : opp.Amount * rate / 100;
    }

    /**
     * The last day the RM had contact with the deal, falling back to the day it
     * was created when no meeting has been logged.
     */
    private static Date lastTouchOf(Opportunity opp) {
        return opp.Last_Meeting_Date__c == null ? opp.CreatedDate.date() : opp.Last_Meeting_Date__c;
    }

    private static KPI_Target__mdt targetFor(String periodKey) {
        for (KPI_Target__mdt target : KPI_Target__mdt.getAll().values()) {
            if (target.Period__c == periodKey) {
                return target;
            }
        }
        return null;
    }

    private static Integer percentOf(Decimal value, Decimal target) {
        if (target == null || target <= 0) {
            return 0;
        }
        return (value / target * 100).setScale(0, System.RoundingMode.HALF_UP).intValue();
    }

    private static Date quarterStartOf(Date d) {
        return Date.newInstance(d.year(), ((d.month() - 1) / 3) * 3 + 1, 1);
    }

    /**
     * The half-year containing the given date, keyed to match KPI_Target__mdt.
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