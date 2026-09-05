/**
 * Reads Opportunity Radar tunables from Radar_Setting__mdt with safe defaults.
 * Pure accessor: no SOQL (uses getAll), no DML.
 */
public with sharing class RadarSettings {
    private static Map<String, Decimal> valuesByName;

    private static final Map<String, Decimal> DEFAULTS = new Map<String, Decimal>{
        'Weight_SimilarWon' => 30, 'Weight_Signal' => 30, 'Weight_Financial' => 20, 'Weight_Priority' => 20,
        'Target_Share_Pct' => 20, 'Upsell_Threshold_Pct' => 30, 'Maturity_Window_Days' => 90,
        'Segment_Large_Assets' => 1000000000000L, 'Segment_Growth_Assets' => 300000000000L, 'Recent_Outcome_Days' => 30,
        // Both are measured against the ADDRESSABLE wallet, so they are deliberately separate from the
        // legacy Upsell_Threshold_Pct (30), which was written against the raw balance sheet figure and
        // would drop nearly every upsell candidate if reused here.
        'Upsell_Fill_Target_Pct' => 100, 'Whitespace_Reference_Eok' => 3000,
        // An account we have never traded with is a prospecting job, not a queue item an RM can act on
        // today, so its priority is held back rather than letting raw balance-sheet size take rank 1.
        'New_Logo_Priority_Pct' => 50
    };

    /**
     * @param developerName Radar_Setting__mdt DeveloperName
     * @return configured value, or the built-in default when the record is missing
     */
    public static Decimal get(String developerName) {
        if (valuesByName == null) {
            valuesByName = new Map<String, Decimal>();
            for (Radar_Setting__mdt setting : Radar_Setting__mdt.getAll().values()) {
                valuesByName.put(setting.DeveloperName, setting.Value__c);
            }
        }
        Decimal configured = valuesByName.get(developerName);
        return configured != null ? configured : DEFAULTS.get(developerName);
    }

    public static Decimal weightSimilarWon() { return get('Weight_SimilarWon'); }
    public static Decimal weightFinancial() { return get('Weight_Financial'); }
    public static Decimal weightSignal() { return get('Weight_Signal'); }
    public static Decimal weightPriority() { return get('Weight_Priority'); }
    public static Decimal targetSharePct() { return get('Target_Share_Pct'); }
    public static Decimal upsellThresholdPct() { return get('Upsell_Threshold_Pct'); }
    /** Share of the addressable wallet we aim to hold before a family stops being an upsell candidate. */
    public static Decimal upsellFillTargetPct() { return get('Upsell_Fill_Target_Pct'); }
    /** Whitespace (in 억) that scores a full 100 when normalising the RM priority ranking. */
    public static Decimal whitespaceReferenceEok() { return get('Whitespace_Reference_Eok'); }
    /** Share of its priority an account with no trading history of ours keeps. */
    public static Decimal newLogoPriorityPct() { return get('New_Logo_Priority_Pct'); }
    public static Integer maturityWindowDays() { return get('Maturity_Window_Days').intValue(); }
    public static Integer recentOutcomeDays() { return get('Recent_Outcome_Days').intValue(); }
    public static Decimal segmentLargeAssets() { return get('Segment_Large_Assets'); }
    public static Decimal segmentGrowthAssets() { return get('Segment_Growth_Assets'); }

    /**
     * @param totalAssets latest total assets (KRW)
     * @return 대기업 / 성장기업 / 중견기업 by asset thresholds
     */
    public static String segmentFor(Decimal totalAssets) {
        if (totalAssets == null) {
            return '중견기업';
        }
        if (totalAssets >= segmentLargeAssets()) {
            return '대기업';
        }
        return totalAssets >= segmentGrowthAssets() ? '성장기업' : '중견기업';
    }
}