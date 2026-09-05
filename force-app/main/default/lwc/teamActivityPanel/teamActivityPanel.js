import { LightningElement, wire } from 'lwc';
import getActivityAnalysis from '@salesforce/apex/TeamActivityController.getActivityAnalysis';

const EMPTY = {};

// Dwell heat thresholds (days) → cell colour class. Low dwell is calm blue,
// high dwell is hot red, matching the reference heatmap.
const HEAT_STOPS = [
    { max: 7, cls: 'heat_1' },
    { max: 14, cls: 'heat_2' },
    { max: 21, cls: 'heat_3' },
    { max: 30, cls: 'heat_4' }
];
const HEAT_HOT = 'heat_5';

// Scatter plot geometry: activity on x, achievement % on y, drawn in a
// 0..100 viewBox with a fixed achievement ceiling so dots stay in the box.
const ACHIEVEMENT_CEILING = 150;

export default class TeamActivityPanel extends LightningElement {
    analysis = EMPTY;
    error;

    @wire(getActivityAnalysis)
    wiredAnalysis({ data, error }) {
        if (data) {
            this.analysis = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.analysis = EMPTY;
        }
    }

    get periodLabel() {
        return this.analysis.periodLabel;
    }

    get stageNames() {
        return this.analysis.stageNames ?? [];
    }

    get hasRows() {
        return (this.analysis.rows ?? []).length > 0;
    }

    // One heatmap row per RM: the RM name plus a coloured cell per stage.
    get heatmapRows() {
        const rows = this.analysis.rows ?? [];
        return rows.map((row) => ({
            key: row.rmId,
            rmName: row.rmName,
            cells: (row.dwellByStage ?? []).map((days, index) => ({
                key: `${row.rmId}-${index}`,
                display: days ?? 0,
                cls: `heat-cell ${heatClass(days)}`
            }))
        }));
    }

    // RM KPI detail table rows — the fields the controller returns.
    get kpiRows() {
        const rows = this.analysis.rows ?? [];
        return rows.map((row) => ({
            key: row.rmId,
            rmName: row.rmName,
            achievementDisplay: `${row.achievementPercent ?? 0}%`,
            openDeals: row.openDeals ?? 0,
            wonDeals: row.wonDeals ?? 0,
            achievedFeeDisplay: formatEok(row.achievedFee),
            activityCount: row.activityCount ?? 0
        }));
    }

    // Scatter dots positioned by activity (x) and achievement (y). X is scaled
    // against the busiest RM so the cloud spreads across the plot.
    get scatterDots() {
        const rows = this.analysis.rows ?? [];
        const maxActivity = rows.reduce((m, r) => Math.max(m, r.activityCount ?? 0), 0);
        return rows.map((row) => {
            const x = maxActivity === 0 ? 0 : ((row.activityCount ?? 0) / maxActivity) * 100;
            const yPct = Math.min((row.achievementPercent ?? 0) / ACHIEVEMENT_CEILING, 1) * 100;
            return {
                key: row.rmId,
                rmName: row.rmName,
                style: `left:${x.toFixed(1)}%;bottom:${yPct.toFixed(1)}%;`
            };
        });
    }
}

function heatClass(days) {
    const value = days ?? 0;
    if (value <= 0) {
        return 'heat_0';
    }
    for (const stop of HEAT_STOPS) {
        if (value <= stop.max) {
            return stop.cls;
        }
    }
    return HEAT_HOT;
}

// Money on this card reads in 억원 units to match the reference table.
function formatEok(value) {
    if (!value) {
        return '0억';
    }
    const eok = value / 100000000;
    return `${Number(eok.toFixed(eok >= 10 ? 0 : 1)).toLocaleString('ko-KR')}억`;
}