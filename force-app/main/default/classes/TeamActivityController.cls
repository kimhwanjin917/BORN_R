/**
 * Dwell-time and activity analysis for a manager's RM team — block 3 of the RM
 * team management dashboard (팀장 전용).
 *
 * The team is resolved the same way as blocks 1 and 2 (TeamDashboardController,
 * TeamFunnelController): the RMs whose role sits directly under the running
 * manager's role, falling back to the running user when there are no
 * subordinate roles.
 *
 * Fee revenue — not deal amount — is the money figure, from the product's own
 * default rate (Amount × Primary_Product__r.Default_Fee_Rate__c / 100),
 * mirroring the other dashboard controllers and MyKpiController. See CONTEXT.md.
 *
 * This block drives three visuals off a single per-RM row so the LWC and Slack
 * surfaces can share one payload:
 *   - a stage-dwell heatmap (RM × stage): row.dwellByStage aligns to stageNames;
 *   - an RM KPI detail table: fee/target/achievement plus deal and activity counts;
 *   - an activity-vs-performance scatter: activityCount (x) against achievementPercent (y).
 *
 * Dwell is measured on open deals only, in their current active stage
 * (LastStageChangeDate → today, falling back to CreatedDate), so the heatmap
 * reflects where live pipeline is sitting rather than the history of closed
 * deals. Only active, not-yet-closed stages become heatmap columns.
 *
 * KPI_Target__mdt carries a single team-level fee target, so each RM's target
 * is the team target split evenly across the team; a per-RM target metadata
 * does not exist and inventing house rates per RM would misstate attainment.
 */
public with sharing class TeamActivityController {

    /**
     * One RM's row, shared by the KPI table, the dwell heatmap, and the
     * activity-vs-performance scatter.
     */
    public class RmActivityRow {
        @AuraEnabled public Id rmId;
        @AuraEnabled public String rmName;

        @AuraEnabled public Decimal achievedFee;
        @AuraEnabled public Decimal targetFee;
        @AuraEnabled public Integer achievementPercent;

        @AuraEnabled public Integer openDeals;
        @AuraEnabled public Integer wonDeals;
        @AuraEnabled public Integer activityCount;

        // Average current-stage dwell in days, one entry per stage in stageNames.
        @AuraEnabled public List<Decimal> dwellByStage;

        RmActivityRow(Id rmId, String rmName, Integer stageCount) {
            this.rmId = rmId;
            this.rmName = rmName;
            this.achievedFee = 0;
            this.targetFee = 0;
            this.achievementPercent = 0;
            this.openDeals = 0;
            this.wonDeals = 0;
            this.activityCount = 0;
            this.dwellByStage = new List<Decimal>();
            for (Integer i = 0; i < stageCount; i++) {
                this.dwellByStage.add(0);
            }
        }
    }

    /**
     * The full block-3 payload: the heatmap's stage columns and one row per RM,
     * plus the labels the card needs.
     */
    public class ActivityAnalysis {
        @AuraEnabled public String periodLabel;
        @AuraEnabled public Integer teamSize;
        @AuraEnabled public Decimal teamTargetFee;

        @AuraEnabled public List<String> stageNames;
        @AuraEnabled public List<RmActivityRow> rows;

        ActivityAnalysis() {
            this.teamTargetFee = 0;
            this.stageNames = new List<String>();
            this.rows = new List<RmActivityRow>();
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
     * Returns the running manager's team dwell-and-activity analysis for the
     * half-year containing today.
     *
     * @return The block-3 figures for the manager's team.
     * @example
     * TeamActivityController.ActivityAnalysis analysis = TeamActivityController.getActivityAnalysis();
     */
    @AuraEnabled(cacheable=true)
    public static ActivityAnalysis getActivityAnalysis() {
        try {
            PerformancePeriod current = halfYearOf(Date.today());
            List<Id> memberIds = resolveTeamMemberIds();

            ActivityAnalysis analysis = new ActivityAnalysis();
            analysis.periodLabel = current.label;
            analysis.teamSize = memberIds.size();
            analysis.stageNames = buildStageNames();

            KPI_Target__mdt target = targetFor(current.key);
            analysis.teamTargetFee = target == null || target.Target_Fee__c == null ? 0 : target.Target_Fee__c;

            Map<String, Integer> indexByStage = new Map<String, Integer>();
            for (Integer i = 0; i < analysis.stageNames.size(); i++) {
                indexByStage.put(analysis.stageNames[i], i);
            }

            Map<Id, RmActivityRow> rowsByRm = rmRowsFor(memberIds, analysis.stageNames.size());

            Decimal perRmTarget = perRmTarget(analysis.teamTargetFee, analysis.teamSize);
            for (RmActivityRow row : rowsByRm.values()) {
                row.targetFee = perRmTarget;
            }

            accumulateWonFee(memberIds, current, rowsByRm);
            populateOpenDwell(memberIds, rowsByRm, indexByStage);
            populateActivity(memberIds, current, rowsByRm);

            for (RmActivityRow row : rowsByRm.values()) {
                row.achievementPercent = percentOf(row.achievedFee, row.targetFee);
            }

            analysis.rows = orderedRows(memberIds, rowsByRm);
            return analysis;
        } catch (Exception e) {
            throw new AuraHandledException('팀 활동 분석을 불러오지 못했습니다: ' + e.getMessage());
        }
    }

    /**
     * The RMs whose role sits directly under the running manager's role. Falls
     * back to the running user when there are no subordinate roles. Mirrors
     * TeamDashboardController and TeamFunnelController.
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
     * A blank row per team member, keyed by user id, so every RM shows up on the
     * heatmap and table even with no deals or activity yet.
     */
    private static Map<Id, RmActivityRow> rmRowsFor(List<Id> memberIds, Integer stageCount) {
        Map<Id, RmActivityRow> rowsByRm = new Map<Id, RmActivityRow>();
        for (User u : [SELECT Id, Name FROM User WHERE Id IN :memberIds WITH USER_MODE]) {
            rowsByRm.put(u.Id, new RmActivityRow(u.Id, u.Name, stageCount));
        }
        return rowsByRm;
    }

    /**
     * The active, not-yet-closed stages in sort order — the heatmap columns.
     * Closed stages (won or lost) are excluded: dwell is only meaningful for
     * deals still moving through the pipeline.
     */
    private static List<String> buildStageNames() {
        List<String> names = new List<String>();
        for (OpportunityStage stage : [
            SELECT MasterLabel, IsClosed
            FROM OpportunityStage
            WHERE IsActive = true
            WITH USER_MODE
            ORDER BY SortOrder NULLS LAST
        ]) {
            if (stage.IsClosed) {
                continue;
            }
            names.add(stage.MasterLabel);
        }
        return names;
    }

    /**
     * Adds up won fee revenue for the period per RM, and counts the wins that
     * back each RM's achievement figure.
     */
    private static void accumulateWonFee(
        List<Id> memberIds,
        PerformancePeriod period,
        Map<Id, RmActivityRow> rowsByRm
    ) {
        for (Opportunity opp : [
            SELECT OwnerId, Amount, Primary_Product__r.Default_Fee_Rate__c
            FROM Opportunity
            WHERE IsWon = true
              AND OwnerId IN :memberIds
              AND CloseDate >= :period.startDate
              AND CloseDate <= :period.endDate
            WITH USER_MODE
        ]) {
            RmActivityRow row = rowsByRm.get(opp.OwnerId);
            if (row != null) {
                row.achievedFee += feeOf(opp);
                row.wonDeals++;
            }
        }
    }

    /**
     * Fills each RM's open-deal count and their average current-stage dwell per
     * stage, so the heatmap shows where each RM's live pipeline is piling up.
     */
    private static void populateOpenDwell(
        List<Id> memberIds,
        Map<Id, RmActivityRow> rowsByRm,
        Map<String, Integer> indexByStage
    ) {
        Date today = Date.today();
        Map<Id, Map<Integer, Long>> dwellSum = new Map<Id, Map<Integer, Long>>();
        Map<Id, Map<Integer, Integer>> dwellCount = new Map<Id, Map<Integer, Integer>>();

        for (Opportunity opp : [
            SELECT OwnerId, StageName, CreatedDate, LastStageChangeDate
            FROM Opportunity
            WHERE OwnerId IN :memberIds
              AND IsClosed = false
            WITH USER_MODE
        ]) {
            RmActivityRow row = rowsByRm.get(opp.OwnerId);
            if (row == null) {
                continue;
            }
            row.openDeals++;

            if (!indexByStage.containsKey(opp.StageName)) {
                continue;
            }
            Integer stageIdx = indexByStage.get(opp.StageName);
            addDwell(dwellSum, dwellCount, opp.OwnerId, stageIdx, dwellDaysOf(opp, today));
        }

        for (Id rmId : dwellSum.keySet()) {
            RmActivityRow row = rowsByRm.get(rmId);
            if (row == null) {
                continue;
            }
            Map<Integer, Long> sums = dwellSum.get(rmId);
            Map<Integer, Integer> counts = dwellCount.get(rmId);
            for (Integer stageIdx : sums.keySet()) {
                Integer count = counts.get(stageIdx);
                if (count > 0) {
                    row.dwellByStage[stageIdx] =
                        (Decimal.valueOf(sums.get(stageIdx)) / count).setScale(1, System.RoundingMode.HALF_UP);
                }
            }
        }
    }

    /**
     * Counts each RM's logged activity in the period — tasks by due date and
     * events by start date — the x-axis of the activity-vs-performance scatter.
     */
    private static void populateActivity(
        List<Id> memberIds,
        PerformancePeriod period,
        Map<Id, RmActivityRow> rowsByRm
    ) {
        // Bind plain locals, not member expressions (:period.startDate): an
        // aggregate GROUP BY under WITH USER_MODE that binds an object field
        // throws "Variable does not exist: tmpVarN" on the platform.
        Date periodStartDate = period.startDate;
        Date periodEndDate = period.endDate;
        for (AggregateResult ar : [
            SELECT OwnerId owner, COUNT(Id) total
            FROM Task
            WHERE OwnerId IN :memberIds
              AND ActivityDate >= :periodStartDate
              AND ActivityDate <= :periodEndDate
            WITH USER_MODE
            GROUP BY OwnerId
        ]) {
            RmActivityRow row = rowsByRm.get((Id) ar.get('owner'));
            if (row != null) {
                row.activityCount += (Integer) ar.get('total');
            }
        }

        Datetime periodStart = Datetime.newInstance(period.startDate, Time.newInstance(0, 0, 0, 0));
        Datetime periodEnd = Datetime.newInstance(period.endDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        for (AggregateResult ar : [
            SELECT OwnerId owner, COUNT(Id) total
            FROM Event
            WHERE OwnerId IN :memberIds
              AND StartDateTime >= :periodStart
              AND StartDateTime < :periodEnd
            WITH USER_MODE
            GROUP BY OwnerId
        ]) {
            RmActivityRow row = rowsByRm.get((Id) ar.get('owner'));
            if (row != null) {
                row.activityCount += (Integer) ar.get('total');
            }
        }
    }

    /**
     * Rows in team-member order so the table and heatmap render the same RM
     * sequence every load rather than the map's iteration order.
     */
    private static List<RmActivityRow> orderedRows(List<Id> memberIds, Map<Id, RmActivityRow> rowsByRm) {
        List<RmActivityRow> ordered = new List<RmActivityRow>();
        for (Id memberId : memberIds) {
            RmActivityRow row = rowsByRm.get(memberId);
            if (row != null) {
                ordered.add(row);
            }
        }
        return ordered;
    }

    private static void addDwell(
        Map<Id, Map<Integer, Long>> sumByRm,
        Map<Id, Map<Integer, Integer>> countByRm,
        Id rmId,
        Integer stageIdx,
        Long days
    ) {
        if (!sumByRm.containsKey(rmId)) {
            sumByRm.put(rmId, new Map<Integer, Long>());
            countByRm.put(rmId, new Map<Integer, Integer>());
        }
        Map<Integer, Long> sums = sumByRm.get(rmId);
        Map<Integer, Integer> counts = countByRm.get(rmId);
        Long priorSum = sums.containsKey(stageIdx) ? sums.get(stageIdx) : 0;
        Integer priorCount = counts.containsKey(stageIdx) ? counts.get(stageIdx) : 0;
        sums.put(stageIdx, priorSum + days);
        counts.put(stageIdx, priorCount + 1);
    }

    /**
     * Fee revenue on one deal, from the product's own rate. Deals with no
     * product or no rate earn nothing rather than defaulting to a house rate
     * that would silently misstate the figure. Mirrors the other controllers.
     */
    private static Decimal feeOf(Opportunity opp) {
        if (opp.Amount == null || opp.Primary_Product__r == null) {
            return 0;
        }
        Decimal rate = opp.Primary_Product__r.Default_Fee_Rate__c;
        return rate == null ? 0 : opp.Amount * rate / 100;
    }

    /**
     * Days a still-open deal has sat in its current stage, from the last stage
     * change and falling back to when it was created. Mirrors TeamFunnelController.
     */
    private static Long dwellDaysOf(Opportunity opp, Date today) {
        Date enteredStage = opp.LastStageChangeDate == null
            ? opp.CreatedDate.date()
            : opp.LastStageChangeDate.date();
        return enteredStage.daysBetween(today);
    }

    /**
     * The team fee target split evenly across the team, since KPI_Target__mdt
     * holds no per-RM target.
     */
    private static Decimal perRmTarget(Decimal teamTargetFee, Integer teamSize) {
        if (teamTargetFee == null || teamTargetFee <= 0 || teamSize == null || teamSize <= 0) {
            return 0;
        }
        return (teamTargetFee / teamSize).setScale(2, System.RoundingMode.HALF_UP);
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