/**
 * Pipeline figures for the running user's own opportunities: how the deals sit
 * across the stages, what fee revenue is still in flight, and which deals need
 * attention this week.
 *
 * Fee revenue — not deal amount — is the money figure here. A large deal on a
 * low-margin product is worth less than a small one on a high-margin product,
 * so showing amount would misrepresent what the pipeline is actually worth.
 * See CONTEXT.md.
 */
public with sharing class OpportunityKpiController {

    // Fallbacks for when the component is placed without its properties set.
    private static final String DEFAULT_STALLED_STAGE = '심사';
    private static final Integer DEFAULT_STALLED_DAYS = 14;
    private static final Integer DEFAULT_INACTIVE_DAYS = 30;
    private static final Integer DEFAULT_CLOSING_DAYS = 7;

    /**
     * One column of the pipeline: an active stage and what sits in it.
     */
    public class StageBucket {
        @AuraEnabled public String stageName;
        @AuraEnabled public Integer count;
        @AuraEnabled public Decimal feeRevenue;
        @AuraEnabled public Boolean isWon;

        StageBucket(String stageName, Boolean isWon) {
            this.stageName = stageName;
            this.isWon = isWon;
            this.count = 0;
            this.feeRevenue = 0;
        }
    }

    /**
     * One "우선 확인" chip. `stageName` is set only when the chip belongs to a
     * single stage, so the card can highlight that column.
     */
    public class Alert {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Integer count;
        @AuraEnabled public String stageName;

        Alert(String key, String label, String stageName) {
            this.key = key;
            this.label = label;
            this.stageName = stageName;
            this.count = 0;
        }
    }

    public class Pipeline {
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Decimal openFeeRevenue;
        @AuraEnabled public Integer weekActionCount;
        @AuraEnabled public List<StageBucket> stages;
        @AuraEnabled public List<Alert> alerts;

        Pipeline() {
            this.totalCount = 0;
            this.openFeeRevenue = 0;
            this.weekActionCount = 0;
            this.stages = new List<StageBucket>();
            this.alerts = new List<Alert>();
        }
    }

    /**
     * The running user's pipeline as one card's worth of figures.
     *
     * The population is open deals plus deals won this quarter. Won deals are
     * capped at the quarter so the column does not grow without bound as the
     * year goes on; lost deals are left out entirely, since a pipeline card is
     * about what is still worth working.
     *
     * @param stalledStage  Stage the "접촉 끊김" chip watches. Null → 심사.
     * @param stalledDays   Days without contact before a deal in that stage is stalled. Null → 14.
     * @param inactiveDays  Days without contact before any open deal counts as 미활동. Null → 30.
     * @param closingDays   Window for the "마감 임박" chip. Null → 7.
     * @return Stage buckets, headline figures, and the alert chips.
     * @example
     * OpportunityKpiController.Pipeline p = OpportunityKpiController.getPipeline(null, null, null, null);
     */
    @AuraEnabled(cacheable=true)
    public static Pipeline getPipeline(
        String stalledStage,
        Integer stalledDays,
        Integer inactiveDays,
        Integer closingDays
    ) {
        try {
            String watchedStage = String.isBlank(stalledStage) ? DEFAULT_STALLED_STAGE : stalledStage;
            Integer stalledAfter = stalledDays == null ? DEFAULT_STALLED_DAYS : stalledDays;
            Integer inactiveAfter = inactiveDays == null ? DEFAULT_INACTIVE_DAYS : inactiveDays;
            Integer closingWithin = closingDays == null ? DEFAULT_CLOSING_DAYS : closingDays;

            Date today = Date.today();
            Date quarterStart = quarterStartOf(today);
            Date quarterEnd = quarterStart.addMonths(3).addDays(-1);

            Pipeline pipeline = new Pipeline();

            // Every active stage gets a column, even an empty one: a gap in the
            // middle of the pipeline is exactly what a rep needs to notice.
            Map<String, StageBucket> buckets = new Map<String, StageBucket>();
            for (OpportunityStage stage : [
                SELECT MasterLabel, IsWon, IsClosed
                FROM OpportunityStage
                WHERE IsActive = true
                ORDER BY SortOrder NULLS LAST
            ]) {
                if (stage.IsClosed && !stage.IsWon) {
                    continue;
                }
                StageBucket bucket = new StageBucket(stage.MasterLabel, stage.IsWon);
                buckets.put(stage.MasterLabel, bucket);
                pipeline.stages.add(bucket);
            }

            Alert stalled = new Alert(
                'stalled',
                watchedStage + ' {0}건 접촉 끊김',
                watchedStage
            );
            Alert closing = new Alert('closing', closingWithin + '일 내 마감 {0}건', null);
            Alert inactive = new Alert('inactive', '미활동 {0}건', null);

            for (Opportunity opp : [
                SELECT StageName, Amount, CloseDate, IsClosed, CreatedDate,
                       Last_Meeting_Date__c, Primary_Product__r.Default_Fee_Rate__c
                FROM Opportunity
                WHERE OwnerId = :UserInfo.getUserId()
                  AND (
                      IsClosed = false
                      OR (IsWon = true AND CloseDate >= :quarterStart AND CloseDate <= :quarterEnd)
                  )
                WITH USER_MODE
            ]) {
                pipeline.totalCount++;

                Decimal fee = feeOf(opp);
                StageBucket bucket = buckets.get(opp.StageName);
                if (bucket != null) {
                    bucket.count++;
                    bucket.feeRevenue += fee;
                }

                if (opp.IsClosed) {
                    continue;
                }
                pipeline.openFeeRevenue += fee;

                if (opp.CloseDate != null && opp.CloseDate <= today.addDays(closingWithin)) {
                    closing.count++;
                }

                // A deal that has never been met is measured from the day it was
                // created, so a deal opened yesterday is not reported as neglected.
                Integer sinceContact = lastTouchOf(opp).daysBetween(today);
                if (opp.StageName == watchedStage && sinceContact > stalledAfter) {
                    stalled.count++;
                } else if (sinceContact > inactiveAfter) {
                    // Deals already flagged as stalled are not counted twice — the
                    // narrower chip wins so the two numbers can be added up.
                    inactive.count++;
                }
            }

            pipeline.weekActionCount = openTasksThisWeek(today);

            for (Alert alert : new List<Alert>{ stalled, closing, inactive }) {
                if (alert.count > 0) {
                    pipeline.alerts.add(alert);
                }
            }

            return pipeline;
        } catch (Exception e) {
            throw new AuraHandledException('영업기회 현황을 불러오지 못했습니다: ' + e.getMessage());
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

    /**
     * Open tasks the running user still owes this week — what is left to do,
     * not what has already been done.
     */
    private static Integer openTasksThisWeek(Date today) {
        Date weekStart = today.toStartOfWeek();
        Date weekEnd = weekStart.addDays(6);
        return [
            SELECT COUNT()
            FROM Task
            WHERE OwnerId = :UserInfo.getUserId()
              AND IsClosed = false
              AND ActivityDate >= :weekStart
              AND ActivityDate <= :weekEnd
            WITH USER_MODE
        ];
    }

    private static Date quarterStartOf(Date d) {
        return Date.newInstance(d.year(), ((d.month() - 1) / 3) * 3 + 1, 1);
    }
}