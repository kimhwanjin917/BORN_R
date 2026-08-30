import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getMyKpi from '@salesforce/apex/MyKpiController.getMyKpi';

const EMPTY = {};

export default class MyKpiCard extends NavigationMixin(LightningElement) {
    kpi = EMPTY;
    error;

    @wire(getMyKpi)
    wiredKpi({ data, error }) {
        if (data) {
            this.kpi = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.kpi = EMPTY;
        }
    }

    get periodLabel() {
        return this.kpi.periodLabel;
    }

    // The first tile is labelled by half-year — "2026 하반기 수수료" — so the figure and
    // the period it covers read as one thing.
    get feeLabel() {
        const label = this.kpi.periodLabel;
        return label ? `${label} 수수료` : '수수료';
    }

    get feePercentDisplay() {
        return `${this.kpi.feePercent ?? 0}%`;
    }

    get feeAmountDisplay() {
        const fee = this.kpi.feeRevenue ?? 0;
        return `${formatKrw(fee)} / ${formatKrw(this.kpi.feeTarget ?? 0)}`;
    }

    get newAccountsDisplay() {
        return `${this.kpi.newAccounts ?? 0} / ${this.kpi.newAccountTarget ?? 0}`;
    }

    // 팀 내 순위 타일은 화면에서 내렸고, MyKpiController의 순위 계산도 함께
    // 걷어냈다. 되살리려면 컨트롤러 쪽 집계부터 다시 넣어야 한다.

    get feeBarStyle() {
        return barWidth(this.kpi.feePercent);
    }

    get newBarStyle() {
        return barWidth(this.kpi.newAccountPercent);
    }

    // The list view is the whole object, not this year's won deals — the
    // tile is a way in, not a filtered drill-down.
    handleTileClick(event) {
        const objectApiName = event.currentTarget.dataset.object;
        if (!objectApiName) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName, actionName: 'list' },
            state: { filterName: 'Recent' }
        });
    }

    handleTileKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleTileClick(event);
        }
    }
}

// Bars cap at 100% so an over-achiever doesn't overflow the track.
function barWidth(percent) {
    return `width:${Math.min(Math.max(percent ?? 0, 0), 100)}%;`;
}

// Korean money reads in 억/만 units, not thousands separators.
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