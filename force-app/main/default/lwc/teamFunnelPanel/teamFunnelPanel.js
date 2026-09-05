import { LightningElement, wire } from 'lwc';
import getFunnelAnalysis from '@salesforce/apex/TeamFunnelController.getFunnelAnalysis';

const EMPTY = {};

export default class TeamFunnelPanel extends LightningElement {
    analysis = EMPTY;
    error;

    @wire(getFunnelAnalysis)
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

    // Funnel rows with display strings; the stage-to-next drop is shown as a
    // red "감소" figure to match the reference, so 0 reads as no drop.
    get funnelRows() {
        const stages = this.analysis.stages ?? [];
        return stages.map((stage) => ({
            key: stage.stageName,
            stageName: stage.stageName,
            countDisplay: `${stage.count ?? 0}건`,
            feeDisplay: formatEok(stage.feeRevenue),
            conversionDisplay: stage.isWon ? '-' : `${stage.conversionPercent ?? 0}%`,
            dwellDisplay: `${(stage.avgDwellDays ?? 0)}일`,
            dropDisplay: stage.dropFromPrevPercent ? `▼ ${stage.dropFromPrevPercent}%` : '-',
            dropClass: stage.dropFromPrevPercent ? 'drop drop_down' : 'drop'
        }));
    }

    get hasFunnel() {
        return this.funnelRows.length > 0;
    }

    // Monthly trend bars, each scaled against the tallest month so the chart
    // fills its box regardless of absolute won amounts.
    get monthlyBars() {
        const points = this.analysis.monthlyTrend ?? [];
        const max = points.reduce((m, p) => Math.max(m, p.feeRevenue ?? 0), 0);
        return points.map((point) => ({
            key: point.monthLabel,
            monthLabel: point.monthLabel,
            feeDisplay: formatEok(point.feeRevenue),
            newCount: point.newCount ?? 0,
            barStyle: `height:${max === 0 ? 0 : Math.round(((point.feeRevenue ?? 0) / max) * 100)}%;`
        }));
    }

    get hasMonthly() {
        return this.monthlyBars.length > 0;
    }

    get committedDisplay() {
        return formatEok(this.analysis.forecast?.committed);
    }

    get bestCaseDisplay() {
        return formatEok(this.analysis.forecast?.bestCase);
    }

    get pipelineDisplay() {
        return formatEok(this.analysis.forecast?.pipeline);
    }

    get overallConversionDisplay() {
        return `${this.analysis.overallConversionPercent ?? 0}%`;
    }

    get leakageDisplay() {
        return `${this.analysis.leakageCount ?? 0}건`;
    }

    get avgDwellDisplay() {
        return `${this.analysis.avgDealDwellDays ?? 0}일`;
    }
}

// Money on this card reads in 억원 units to match the reference funnel table.
function formatEok(value) {
    if (!value) {
        return '0억';
    }
    const eok = value / 100000000;
    return `${Number(eok.toFixed(eok >= 10 ? 0 : 1)).toLocaleString('ko-KR')}억`;
}