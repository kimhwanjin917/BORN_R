import { LightningElement, wire } from 'lwc';
import getRiskZone from '@salesforce/apex/TeamRiskController.getRiskZone';

const EMPTY = {};

// Risk-donut colours, keyed to the levels the controller returns.
const RISK_COLORS = {
    HIGH: '#e0483d',
    MEDIUM: '#f2a63b',
    LOW: '#34c77b'
};
const DONUT_CIRCUMFERENCE = 100;

export default class TeamRiskPanel extends LightningElement {
    zone = EMPTY;
    error;

    @wire(getRiskZone)
    wiredZone({ data, error }) {
        if (data) {
            this.zone = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.zone = EMPTY;
        }
    }

    get periodLabel() {
        return this.zone.periodLabel;
    }

    get openDealDisplay() {
        return `총 ${this.zone.openDealCount ?? 0}건`;
    }

    // At-risk deal list rows (HIGH/MEDIUM), with a level badge class.
    get riskRows() {
        const deals = this.zone.riskDeals ?? [];
        return deals.map((deal) => ({
            key: deal.oppId,
            oppName: deal.oppName,
            rmName: deal.rmName,
            stageName: deal.stageName,
            feeDisplay: formatEok(deal.feeRevenue),
            dwellDisplay: `${deal.dwellDays ?? 0}일`,
            contactDisplay: `${deal.daysSinceContact ?? 0}일 전`,
            closeDate: deal.closeDate,
            level: deal.riskLevel,
            isHigh: deal.riskLevel === 'HIGH',
            badgeClass: `badge badge_${(deal.riskLevel || 'low').toLowerCase()}`
        }));
    }

    get hasRisk() {
        return this.riskRows.length > 0;
    }

    // Dwell-distribution bars scaled against the fullest bucket.
    get dwellBars() {
        const buckets = this.zone.dwellDistribution ?? [];
        const max = buckets.reduce((m, b) => Math.max(m, b.count ?? 0), 0);
        return buckets.map((bucket) => ({
            key: bucket.label,
            label: bucket.label,
            count: bucket.count ?? 0,
            barStyle: `width:${max === 0 ? 0 : Math.round(((bucket.count ?? 0) / max) * 100)}%;`
        }));
    }

    get hasDwell() {
        return this.dwellBars.length > 0;
    }

    // Long-dwell TOP5 rows (60일 이상).
    get longDwellRows() {
        const deals = this.zone.longDwellTop5 ?? [];
        return deals.map((deal) => ({
            key: deal.oppId,
            oppName: deal.oppName,
            rmName: deal.rmName,
            stageName: deal.stageName,
            feeDisplay: formatEok(deal.feeRevenue),
            dwellDisplay: `${deal.dwellDays ?? 0}일`
        }));
    }

    get hasLongDwell() {
        return this.longDwellRows.length > 0;
    }

    get riskTotalDisplay() {
        const slices = this.zone.riskDistribution ?? [];
        const total = slices.reduce((sum, s) => sum + (s.count ?? 0), 0);
        return `총 ${total}건`;
    }

    // Risk-level donut arcs plus legend, one per level in HIGH→MEDIUM→LOW order.
    get riskDonut() {
        const slices = this.zone.riskDistribution ?? [];
        const total = slices.reduce((sum, s) => sum + (s.count ?? 0), 0);
        let offset = 0;
        return slices.map((slice) => {
            const count = slice.count ?? 0;
            const share = total === 0 ? 0 : (count / total) * DONUT_CIRCUMFERENCE;
            const color = RISK_COLORS[slice.level] || '#b0b6c6';
            const row = {
                key: slice.level,
                level: slice.level,
                count,
                color,
                percentDisplay: total === 0 ? '0.0%' : `${((count / total) * 100).toFixed(1)}%`,
                dashArray: `${share} ${DONUT_CIRCUMFERENCE - share}`,
                dashOffset: DONUT_CIRCUMFERENCE / 4 - offset,
                swatchStyle: `background:${color};`
            };
            offset += share;
            return row;
        });
    }

    get hasRiskDonut() {
        return (this.zone.riskDistribution ?? []).length > 0;
    }
}

// Money on this card reads in 억원 units to match the reference table.
function formatEok(value) {
    if (!value) {
        return '0억';
    }
    const eok = value / 100000000;
    return `${Number(eok.toFixed(eok >= 10 ? 0 : 1)).toLocaleString('ko-KR')}억`;
}