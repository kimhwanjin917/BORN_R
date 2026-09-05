import { LightningElement, wire } from 'lwc';
import getTeamSummary from '@salesforce/apex/TeamDashboardController.getTeamSummary';

const EMPTY = {};

// Donut palette, one hue per stage slice in sort order; wraps if a stage list
// runs longer than the palette.
const SLICE_COLORS = [
    '#3b6cf6',
    '#34c77b',
    '#8f7bf2',
    '#f2a63b',
    '#e06a9c',
    '#4bc2d6',
    '#b0b6c6'
];
const DONUT_CIRCUMFERENCE = 100;

export default class TeamKpiSummary extends LightningElement {
    summary = EMPTY;
    error;

    @wire(getTeamSummary)
    wiredSummary({ data, error }) {
        if (data) {
            this.summary = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.summary = EMPTY;
        }
    }

    get periodLabel() {
        return this.summary.periodLabel;
    }

    get targetFeeDisplay() {
        return formatKrw(this.summary.teamTargetFee);
    }

    get achievedFeeDisplay() {
        return formatKrw(this.summary.teamAchievedFee);
    }

    get achievementDisplay() {
        return `${this.summary.achievementPercent ?? 0}%`;
    }

    get expectedFeeDisplay() {
        return formatKrw(this.summary.expectedFee);
    }

    get openDealDisplay() {
        return `${this.summary.openDealCount ?? 0}건`;
    }

    get newOppDisplay() {
        return `${this.summary.newOppCount ?? 0}건`;
    }

    get riskDealDisplay() {
        return `${this.summary.riskDealCount ?? 0}건`;
    }

    get conversionDisplay() {
        return `${this.summary.avgConversionPercent ?? 0}%`;
    }

    get achievementBarStyle() {
        return barWidth(this.summary.achievementPercent);
    }

    // Total open pipeline fee shown in the donut hole.
    get pipelineTotalDisplay() {
        const slices = this.summary.stageSlices ?? [];
        const total = slices.reduce((sum, s) => sum + (s.feeRevenue ?? 0), 0);
        return formatKrw(total);
    }

    // Each stage becomes an SVG arc plus a legend row: share of total count,
    // the dash offset that positions the arc, and its colour.
    get donutSlices() {
        const slices = this.summary.stageSlices ?? [];
        const totalCount = slices.reduce((sum, s) => sum + (s.count ?? 0), 0);
        let offset = 0;
        return slices.map((slice, index) => {
            const count = slice.count ?? 0;
            const share = totalCount === 0 ? 0 : (count / totalCount) * DONUT_CIRCUMFERENCE;
            const color = SLICE_COLORS[index % SLICE_COLORS.length];
            const row = {
                key: slice.stageName,
                stageName: slice.stageName,
                count,
                color,
                percentDisplay: totalCount === 0 ? '0.0%' : `${((count / totalCount) * 100).toFixed(1)}%`,
                dashArray: `${share} ${DONUT_CIRCUMFERENCE - share}`,
                dashOffset: DONUT_CIRCUMFERENCE / 4 - offset,
                swatchStyle: `background:${color};`
            };
            offset += share;
            return row;
        });
    }

    get hasSlices() {
        return this.donutSlices.length > 0;
    }

    // The team ranking with a display-ready rank, fee, and a capped bar. Only
    // the fields the controller actually returns are shown.
    get rankingRows() {
        const rows = this.summary.rmRanking ?? [];
        const top = rows.reduce((max, r) => Math.max(max, r.achievedFee ?? 0), 0);
        return rows.map((row, index) => ({
            key: row.rmId,
            rank: index + 1,
            rmName: row.rmName,
            achievedFeeDisplay: formatKrw(row.achievedFee),
            openDeals: row.openDeals ?? 0,
            newOpps: row.newOpps ?? 0,
            barStyle: `width:${top === 0 ? 0 : Math.round(((row.achievedFee ?? 0) / top) * 100)}%;`
        }));
    }

    get hasRanking() {
        return this.rankingRows.length > 0;
    }
}

// Bars cap at 100% so an over-achiever doesn't overflow the track.
function barWidth(percent) {
    return `width:${Math.min(Math.max(percent ?? 0, 0), 100)}%;`;
}

// Korean money reads in 억/만 units, not thousands separators. Mirrors myKpiCard.
function formatKrw(value) {
    if (!value) {
        return '0원';
    }
    if (value >= 100000000) {
        return `${trim(value / 100000000)}억원`;
    }
    if (value >= 10000) {
        return `${trim(value / 10000)}만원`;
    }
    return `${Math.round(value).toLocaleString('ko-KR')}원`;
}

function trim(value) {
    return Number(value.toFixed(1)).toLocaleString('ko-KR');
}