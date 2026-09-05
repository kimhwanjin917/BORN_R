/**
 * Risk-zone analysis for a manager's RM team — block 4 of the RM team
 * management dashboard (팀장 전용).
 *
 * The team is resolved the same way as blocks 1 and 2 (TeamDashboardController,
 * TeamFunnelController): the RMs whose role sits directly under the running
 * manager's role, falling back to the running user when there are no
 * subordinate roles.
 *
 * The risk zone is about open deals only — a closed deal can no longer go bad,
 * so it carries no risk. Two independent time measures drive the block:
 *
 *   • Contact staleness — days since the RM last met the deal (Last_Meeting_Date__c,
 *     falling back to creation). This sets the risk level: over 30 days is HIGH,
 *     over 14 is MEDIUM, otherwise LOW. The 14-day threshold matches the "접촉
 *     끊김" line used across OpportunityKpiController and TeamDashboardController.
 *   • Stage dwell — days the deal has sat in its current stage (LastStageChangeDate,
 *     falling back to creation). This drives the dwell distribution and the
 *     long-dwell TOP5 (60일 이상), mirroring TeamFunnelController's dwell logic.
 *
 * Fee revenue — not deal amount — is the money figure, from the product's own
 * default rate (Amount × Primary_Product__r.Default_Fee_Rate__c / 100), mirroring
 * the other dashboard controllers. See CONTEXT.md.
 */
public with sharing class TeamRiskController {

    // Days since last contact before an open deal is flagged. Over MEDIUM but
    // not over HIGH is MEDIUM risk; over HIGH is HIGH risk. The MEDIUM threshold
    // matches the "at risk" line in TeamDashboardController and OpportunityKpiController.
    private static final Integer MEDIUM_RISK_DAYS = 14;
    private static final Integer HIGH_RISK_DAYS = 30;

    // A deal sitting in one stage this long is a long-dwell deal (장기 체류).
    private static final Integer LONG_DWELL_DAYS = 60;

    private static final String LEVEL_HIGH = 'HIGH';
    private static final String LEVEL_MEDIUM = 'MEDIUM';
    private static final String LEVEL_LOW = 'LOW';

    /**
     * One at-risk or long-dwell open deal, carrying both time measures so the
     * risk list and the long-dwell TOP5 can share the same row shape.
     */
    public class RiskDeal {
        @AuraEnabled public Id oppId;
        @AuraEnabled public String oppName;
        @AuraEnabled public String rmName;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal feeRevenue;
        @AuraEnabled public Integer daysSinceContact;
        @AuraEnabled public Integer dwellDays;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public String riskLevel;

        RiskDeal(
            Id oppId,
            String oppName,
            String rmName,
            String stageName,
            Decimal amount,
            Decimal feeRevenue,
            Integer daysSinceContact,
            Integer dwellDays,
            Date closeDate,
            String riskLevel
        ) {
            this.oppId = oppId;
            this.oppName = oppName;
            this.rmName = rmName;
            this.stageName = stageName;
            this.amount = amount;
            this.feeRevenue = feeRevenue;
            this.daysSinceContact = daysSinceContact;
            this.dwellDays = dwellDays;
            this.closeDate = closeDate;
            this.riskLevel = riskLevel;
        }
    }

    /**
     * One bar of the dwell-time distribution: a span of stage-dwell days and how
     * many open deals fall in it.
     */
    public class DwellBucket {
        @AuraEnabled public String label;
        @AuraEnabled public Integer minDays;
        @AuraEnabled public Integer maxDays;
        @AuraEnabled public Integer count;

        DwellBucket(String label, Integer minDays, Integer maxDays) {
            this.label = label;
            this.minDays = minDays;
            this.maxDays = maxDays;
            this.count = 0;
        }

        Boolean holds(Integer dwellDays) {
            if (dwellDays < minDays) {
                return false;
            }
            return maxDays == null || dwellDays <= maxDays;
        }
    }

    /**
     * One slice of the risk-level donut: a level and how many open deals sit at it.
     */
    public class RiskCount {
        @AuraEnabled public String level;
        @AuraEnabled public Integer count;

        RiskCount(String level) {
            this.level = level;
            this.count = 0;
        }
    }

    /**
     * The full block-4 payload: the at-risk deal list, the dwell distribution,
     * the long-dwell TOP5, and the risk-level donut.
     */
    public class RiskZone {
        @AuraEnabled public String periodLabel;
        @AuraEnabled public Integer teamSize;

        @AuraEnabled public Integer openDealCount;
        @AuraEnabled public Integer highRiskCount;
        @AuraEnabled public Integer mediumRiskCount;

        @AuraEnabled public List<RiskDeal> riskDeals;
        @AuraEnabled public List<DwellBucket> dwellDistribution;
        @AuraEnabled public List<RiskDeal> longDwellTop5;
        @AuraEnabled public List<RiskCount> riskDistribution;

        RiskZone() {
            this.openDealCount = 0;
            this.highRiskCount = 0;
            this.mediumRiskCount = 0;
            this.riskDeals = new List<RiskDeal>();
            this.dwellDistribution = new List<DwellBucket>();
            this.longDwellTop5 = new List<RiskDeal>();
            this.riskDistribution = new List<RiskCount>();
        }
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
     * Returns the running manager's team risk-zone analysis over the team's open
     * pipeline.
     *
     * @return The block-4 risk figures for the manager's team.
     * @example
     * TeamRiskController.RiskZone zone = TeamRiskController.getRiskZone();
     */
    @AuraEnabled(cacheable=true)
    public static RiskZone getRiskZone() {
        try {
            PerformancePeriod current = halfYearOf(Date.today());
            List<Id> memberIds = resolveTeamMemberIds();

            RiskZone zone = new RiskZone();
            zone.periodLabel = current.label;
            zone.teamSize = memberIds.size();
            zone.dwellDistribution = buildDwellBuckets();
            zone.riskDistribution = buildRiskCounts();

            populateRiskZone(memberIds, zone);
            return zone;
        } catch (Exception e) {
            throw new AuraHandledException('팀 리스크존을 불러오지 못했습니다: ' + e.getMessage());
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
     * The dwell-distribution bars, ordered shortest span first, the last one
     * open-ended so every open deal lands in exactly one bucket.
     */
    private static List<DwellBucket> buildDwellBuckets() {
        return new List<DwellBucket>{
            new DwellBucket('0-14일', 0, 14),
            new DwellBucket('15-30일', 15, 30),
            new DwellBucket('31-60일', 31, 60),
            new DwellBucket('60일+', 61, null)
        };
    }

    /**
     * The risk-level donut slices, in HIGH → MEDIUM → LOW order so the most
     * urgent level reads first.
     */
    private static List<RiskCount> buildRiskCounts() {
        return new List<RiskCount>{
            new RiskCount(LEVEL_HIGH),
            new RiskCount(LEVEL_MEDIUM),
            new RiskCount(LEVEL_LOW)
        };
    }

    /**
     * Walks the team's open deals once, filling the risk list, the dwell
     * distribution, the risk-level donut, and the long-dwell candidates. Won and
     * lost deals are excluded — only open pipeline can still go at risk.
     */
    private static void populateRiskZone(List<Id> memberIds, RiskZone zone) {
        Date today = Date.today();

        Map<String, RiskCount> countByLevel = new Map<String, RiskCount>();
        for (RiskCount slice : zone.riskDistribution) {
            countByLevel.put(slice.level, slice);
        }

        List<RiskDeal> longDwellCandidates = new List<RiskDeal>();

        for (Opportunity opp : [
            SELECT Id, Name, Owner.Name, StageName, Amount, CloseDate, CreatedDate,
                   LastStageChangeDate, Last_Meeting_Date__c,
                   Primary_Product__r.Default_Fee_Rate__c
            FROM Opportunity
            WHERE OwnerId IN :memberIds
              AND IsClosed = false
            WITH USER_MODE
        ]) {
            zone.openDealCount++;

            Integer daysSinceContact = lastTouchOf(opp).daysBetween(today);
            Integer dwellDays = dwellDaysOf(opp, today);
            String level = riskLevelOf(daysSinceContact);

            RiskCount slice = countByLevel.get(level);
            if (slice != null) {
                slice.count++;
            }
            if (level == LEVEL_HIGH) {
                zone.highRiskCount++;
            } else if (level == LEVEL_MEDIUM) {
                zone.mediumRiskCount++;
            }

            for (DwellBucket bucket : zone.dwellDistribution) {
                if (bucket.holds(dwellDays)) {
                    bucket.count++;
                    break;
                }
            }

            RiskDeal deal = new RiskDeal(
                opp.Id,
                opp.Name,
                opp.Owner == null ? null : opp.Owner.Name,
                opp.StageName,
                opp.Amount,
                feeOf(opp),
                daysSinceContact,
                dwellDays,
                opp.CloseDate,
                level
            );

            if (level == LEVEL_HIGH || level == LEVEL_MEDIUM) {
                zone.riskDeals.add(deal);
            }
            if (dwellDays >= LONG_DWELL_DAYS) {
                longDwellCandidates.add(deal);
            }
        }

        zone.riskDeals.sort(new ByDaysSinceContactDesc());
        longDwellCandidates.sort(new ByDwellDaysDesc());
        zone.longDwellTop5 = firstN(longDwellCandidates, 5);
    }

    /**
     * The risk level for an open deal from how long it has gone without contact:
     * over HIGH_RISK_DAYS is HIGH, over MEDIUM_RISK_DAYS is MEDIUM, else LOW.
     */
    private static String riskLevelOf(Integer daysSinceContact) {
        if (daysSinceContact > HIGH_RISK_DAYS) {
            return LEVEL_HIGH;
        }
        if (daysSinceContact > MEDIUM_RISK_DAYS) {
            return LEVEL_MEDIUM;
        }
        return LEVEL_LOW;
    }

    /**
     * The first n rows of an already-sorted list, or the whole list when it is
     * shorter than n.
     */
    private static List<RiskDeal> firstN(List<RiskDeal> deals, Integer n) {
        List<RiskDeal> top = new List<RiskDeal>();
        for (RiskDeal deal : deals) {
            if (top.size() == n) {
                break;
            }
            top.add(deal);
        }
        return top;
    }

    /**
     * Orders risk deals by days since last contact, most neglected first.
     */
    private class ByDaysSinceContactDesc implements Comparator<RiskDeal> {
        public Integer compare(RiskDeal a, RiskDeal b) {
            if (a.daysSinceContact == b.daysSinceContact) {
                return 0;
            }
            return a.daysSinceContact > b.daysSinceContact ? -1 : 1;
        }
    }

    /**
     * Orders risk deals by stage-dwell days, longest-stuck first.
     */
    private class ByDwellDaysDesc implements Comparator<RiskDeal> {
        public Integer compare(RiskDeal a, RiskDeal b) {
            if (a.dwellDays == b.dwellDays) {
                return 0;
            }
            return a.dwellDays > b.dwellDays ? -1 : 1;
        }
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
     * The last day the RM had contact with the deal, falling back to the day it
     * was created when no meeting has been logged. Mirrors TeamDashboardController.
     */
    private static Date lastTouchOf(Opportunity opp) {
        return opp.Last_Meeting_Date__c == null ? opp.CreatedDate.date() : opp.Last_Meeting_Date__c;
    }

    /**
     * Days a still-open deal has sat in its current stage, from the last stage
     * change and falling back to when it was created. Mirrors TeamFunnelController.
     */
    private static Integer dwellDaysOf(Opportunity opp, Date today) {
        Date enteredStage = opp.LastStageChangeDate == null
            ? opp.CreatedDate.date()
            : opp.LastStageChangeDate.date();
        return enteredStage.daysBetween(today);
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