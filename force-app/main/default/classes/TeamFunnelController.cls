/**
 * Funnel analysis for a manager's RM team — block 2 of the RM team management
 * dashboard (팀장 전용).
 *
 * The team is resolved the same way as block 1 (TeamDashboardController): the
 * RMs whose role sits directly under the running manager's role, falling back
 * to the running user when there are no subordinate roles.
 *
 * Fee revenue — not deal amount — is the money figure, from the product's own
 * default rate (Amount × Primary_Product__r.Default_Fee_Rate__c / 100), mirroring
 * TeamDashboardController, OpportunityKpiController and MyKpiController. See
 * CONTEXT.md.
 *
 * The funnel is a snapshot: open deals sit in their current active stage, deals
 * won in the half-year land in the closed-won stage, and deals lost in the
 * half-year are leakage (their dying stage is not recorded, so they are counted
 * as loss rather than placed in a stage). Stage-to-stage conversion is derived
 * from cumulative "reached" counts — a deal in 심사 has by definition passed
 * through every earlier stage.
 */
public with sharing class TeamFunnelController {

    /**
     * One stage of the funnel: how many deals sit at or beyond it and the flow
     * between it and its neighbours.
     */
    public class FunnelStage {
        @AuraEnabled public String stageName;
        @AuraEnabled public Integer count;
        @AuraEnabled public Decimal feeRevenue;
        @AuraEnabled public Integer reached;
        @AuraEnabled public Integer conversionPercent;
        @AuraEnabled public Integer dropFromPrevPercent;
        @AuraEnabled public Decimal avgDwellDays;
        @AuraEnabled public Boolean isWon;

        FunnelStage(String stageName, Boolean isWon) {
            this.stageName = stageName;
            this.isWon = isWon;
            this.count = 0;
            this.feeRevenue = 0;
            this.reached = 0;
            this.conversionPercent = 0;
            this.dropFromPrevPercent = 0;
            this.avgDwellDays = 0;
        }
    }

    /**
     * One point on the monthly pipeline-generation trend: deals created in a
     * calendar month of the half-year and the fee revenue they carry.
     */
    public class MonthlyPoint {
        @AuraEnabled public String monthLabel;
        @AuraEnabled public Integer newCount;
        @AuraEnabled public Decimal feeRevenue;

        MonthlyPoint(String monthLabel) {
            this.monthLabel = monthLabel;
            this.newCount = 0;
            this.feeRevenue = 0;
        }
    }

    /**
     * Expected fee revenue on open deals, split by the deal's forecast category
     * so the card can show Commit / Best Case / Pipeline side by side.
     */
    public class Forecast {
        @AuraEnabled public Decimal committed;
        @AuraEnabled public Decimal bestCase;
        @AuraEnabled public Decimal pipeline;

        Forecast() {
            this.committed = 0;
            this.bestCase = 0;
            this.pipeline = 0;
        }
    }

    /**
     * The full block-2 payload: the funnel stages, the monthly trend, the
     * forecast split, and the headline funnel figures.
     */
    public class FunnelAnalysis {
        @AuraEnabled public String periodLabel;
        @AuraEnabled public Integer teamSize;

        @AuraEnabled public List<FunnelStage> stages;
        @AuraEnabled public List<MonthlyPoint> monthlyTrend;
        @AuraEnabled public Forecast forecast;

        @AuraEnabled public Integer overallConversionPercent;
        @AuraEnabled public Integer leakageCount;
        @AuraEnabled public Decimal avgDealDwellDays;

        FunnelAnalysis() {
            this.stages = new List<FunnelStage>();
            this.monthlyTrend = new List<MonthlyPoint>();
            this.forecast = new Forecast();
            this.overallConversionPercent = 0;
            this.leakageCount = 0;
            this.avgDealDwellDays = 0;
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
     * Returns the running manager's team funnel analysis for the half-year
     * containing today.
     *
     * @return The block-2 funnel figures for the manager's team.
     * @example
     * TeamFunnelController.FunnelAnalysis analysis = TeamFunnelController.getFunnelAnalysis();
     */
    @AuraEnabled(cacheable=true)
    public static FunnelAnalysis getFunnelAnalysis() {
        try {
            PerformancePeriod current = halfYearOf(Date.today());
            List<Id> memberIds = resolveTeamMemberIds();

            FunnelAnalysis analysis = new FunnelAnalysis();
            analysis.periodLabel = current.label;
            analysis.teamSize = memberIds.size();

            List<FunnelStage> stages = buildFunnelStages();
            Map<String, FunnelStage> stageByName = new Map<String, FunnelStage>();
            for (FunnelStage stage : stages) {
                stageByName.put(stage.stageName, stage);
            }

            populateFunnel(memberIds, current, analysis, stages, stageByName);
            computeFlow(stages);

            analysis.stages = stages;
            analysis.monthlyTrend = buildMonthlyTrend(memberIds, current);
            return analysis;
        } catch (Exception e) {
            throw new AuraHandledException('팀 퍼널 분석을 불러오지 못했습니다: ' + e.getMessage());
        }
    }

    /**
     * The RMs whose role sits directly under the running manager's role. Falls
     * back to the running user when there are no subordinate roles. Mirrors
     * TeamDashboardController.
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
     * One funnel stage per active stage, closed-lost excluded, in sort order —
     * so a gap in the middle of the funnel is visible.
     */
    private static List<FunnelStage> buildFunnelStages() {
        List<FunnelStage> stages = new List<FunnelStage>();
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
            stages.add(new FunnelStage(stage.MasterLabel, stage.IsWon));
        }
        return stages;
    }

    /**
     * Walks the period population once, filling per-stage counts and fee, the
     * forecast split, the leakage count, and the average deal cycle time.
     *
     * The population is open deals (their current active stage) plus deals
     * closed within the half-year: wins land in the closed-won stage, losses
     * count as leakage. This mirrors how TeamDashboardController blends open
     * pipeline with this period's wins.
     */
    private static void populateFunnel(
        List<Id> memberIds,
        PerformancePeriod period,
        FunnelAnalysis analysis,
        List<FunnelStage> stages,
        Map<String, FunnelStage> stageByName
    ) {
        Date today = Date.today();
        Integer wonCount = 0;
        Integer lostCount = 0;
        Integer closedCount = 0;
        Long closedDwellSum = 0;
        Map<String, Long> dwellSumByStage = new Map<String, Long>();
        Map<String, Integer> dwellCountByStage = new Map<String, Integer>();

        for (Opportunity opp : [
            SELECT StageName, Amount, IsClosed, IsWon, CloseDate, CreatedDate,
                   LastStageChangeDate, ForecastCategoryName,
                   Primary_Product__r.Default_Fee_Rate__c
            FROM Opportunity
            WHERE OwnerId IN :memberIds
              AND (
                  IsClosed = false
                  OR (CloseDate >= :period.startDate AND CloseDate <= :period.endDate)
              )
            WITH USER_MODE
        ]) {
            Decimal fee = feeOf(opp);

            if (opp.IsClosed && !opp.IsWon) {
                lostCount++;
                closedCount++;
                closedDwellSum += cycleDaysOf(opp);
                continue;
            }

            FunnelStage stage = stageByName.get(opp.StageName);

            if (opp.IsClosed && opp.IsWon) {
                wonCount++;
                closedCount++;
                closedDwellSum += cycleDaysOf(opp);
                if (stage != null) {
                    stage.count++;
                    stage.feeRevenue += fee;
                    addDwell(dwellSumByStage, dwellCountByStage, opp.StageName, cycleDaysOf(opp));
                }
                continue;
            }

            if (stage != null) {
                stage.count++;
                stage.feeRevenue += fee;
                addDwell(dwellSumByStage, dwellCountByStage, opp.StageName, dwellDaysOf(opp, today));
            }
            addToForecast(analysis.forecast, opp.ForecastCategoryName, fee);
        }

        for (FunnelStage stage : stages) {
            Integer dwellCount = dwellCountByStage.containsKey(stage.stageName)
                ? dwellCountByStage.get(stage.stageName)
                : 0;
            if (dwellCount > 0) {
                stage.avgDwellDays = (Decimal.valueOf(dwellSumByStage.get(stage.stageName)) / dwellCount)
                    .setScale(1, System.RoundingMode.HALF_UP);
            }
        }

        analysis.leakageCount = lostCount;
        Integer closedTotal = wonCount + lostCount;
        analysis.overallConversionPercent = closedTotal == 0 ? 0 : ratio(wonCount, closedTotal);
        analysis.avgDealDwellDays = closedCount == 0
            ? 0
            : (Decimal.valueOf(closedDwellSum) / closedCount).setScale(1, System.RoundingMode.HALF_UP);
    }

    /**
     * Fills each stage's cumulative "reached" count, its conversion rate to the
     * next stage, and its drop from the previous stage. A deal sitting in a
     * given stage has passed through every earlier one, so "reached" accumulates
     * from the last stage backwards.
     */
    private static void computeFlow(List<FunnelStage> stages) {
        Integer runningReached = 0;
        for (Integer i = stages.size() - 1; i >= 0; i--) {
            runningReached += stages[i].count;
            stages[i].reached = runningReached;
        }
        for (Integer i = 0; i < stages.size(); i++) {
            FunnelStage stage = stages[i];
            if (i < stages.size() - 1) {
                stage.conversionPercent = stage.reached == 0 ? 0 : ratio(stages[i + 1].reached, stage.reached);
            } else {
                stage.conversionPercent = 100;
            }
            if (i > 0) {
                Integer reachedPrev = stages[i - 1].reached;
                stage.dropFromPrevPercent = reachedPrev == 0 ? 0 : 100 - ratio(stage.reached, reachedPrev);
            }
        }
    }

    /**
     * Deals created in each of the six months of the half-year, with the fee
     * revenue they carry — the pipeline the team generated over the period.
     */
    private static List<MonthlyPoint> buildMonthlyTrend(List<Id> memberIds, PerformancePeriod period) {
        Map<String, MonthlyPoint> pointByKey = new Map<String, MonthlyPoint>();
        List<MonthlyPoint> points = new List<MonthlyPoint>();
        for (Integer i = 0; i < 6; i++) {
            Date monthDate = period.startDate.addMonths(i);
            MonthlyPoint point = new MonthlyPoint(monthLabelOf(monthDate));
            pointByKey.put(monthKeyOf(monthDate), point);
            points.add(point);
        }

        Datetime periodStart = Datetime.newInstance(period.startDate, Time.newInstance(0, 0, 0, 0));
        Datetime periodEnd = Datetime.newInstance(period.endDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        for (Opportunity opp : [
            SELECT CreatedDate, Amount, Primary_Product__r.Default_Fee_Rate__c
            FROM Opportunity
            WHERE OwnerId IN :memberIds
              AND CreatedDate >= :periodStart
              AND CreatedDate < :periodEnd
            WITH USER_MODE
        ]) {
            MonthlyPoint point = pointByKey.get(monthKeyOf(opp.CreatedDate.date()));
            if (point != null) {
                point.newCount++;
                point.feeRevenue += feeOf(opp);
            }
        }
        return points;
    }

    private static void addToForecast(Forecast forecast, String category, Decimal fee) {
        if (category == 'Commit') {
            forecast.committed += fee;
        } else if (category == 'Best Case') {
            forecast.bestCase += fee;
        } else if (category == 'Pipeline') {
            forecast.pipeline += fee;
        }
    }

    private static void addDwell(
        Map<String, Long> sumByStage,
        Map<String, Integer> countByStage,
        String stageName,
        Long days
    ) {
        Long priorSum = sumByStage.containsKey(stageName) ? sumByStage.get(stageName) : 0;
        Integer priorCount = countByStage.containsKey(stageName) ? countByStage.get(stageName) : 0;
        sumByStage.put(stageName, priorSum + days);
        countByStage.put(stageName, priorCount + 1);
    }

    /**
     * Fee revenue on one deal, from the product's own rate. Deals with no
     * product or no rate earn nothing rather than defaulting to a house rate
     * that would silently misstate the figure. Mirrors TeamDashboardController.
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
     * change and falling back to when it was created.
     */
    private static Long dwellDaysOf(Opportunity opp, Date today) {
        Date enteredStage = opp.LastStageChangeDate == null
            ? opp.CreatedDate.date()
            : opp.LastStageChangeDate.date();
        return enteredStage.daysBetween(today);
    }

    /**
     * Total cycle time of a closed deal, from creation to close.
     */
    private static Long cycleDaysOf(Opportunity opp) {
        if (opp.CloseDate == null) {
            return 0;
        }
        return opp.CreatedDate.date().daysBetween(opp.CloseDate);
    }

    private static Integer ratio(Integer part, Integer whole) {
        if (whole == 0) {
            return 0;
        }
        return (Decimal.valueOf(part) / whole * 100).setScale(0, System.RoundingMode.HALF_UP).intValue();
    }

    private static String monthKeyOf(Date d) {
        return d.year() + '-' + d.month();
    }

    private static String monthLabelOf(Date d) {
        return d.month() + '월';
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