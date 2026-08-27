import { LightningElement, wire, track, api } from 'lwc';
import getAccounts from '@salesforce/apex/BORNGrowthOppController.getAccounts';
import getAnalysis from '@salesforce/apex/BORNGrowthOppController.getAnalysis';

const CHART_W = 620;
const CHART_H = 200;
const PAD = 30;

export default class BornGrowthOpportunity extends LightningElement {
    @api recordId; // when placed on a record page, preselects that account
    @track accountOptions = [];
    selectedAccountId;
    data;
    loading = false;
    errorMsg;

    @wire(getAccounts)
    wiredAccounts({ data, error }) {
        if (data) {
            this.accountOptions = data.map((o) => ({ label: o.label, value: o.value }));
            if (this.recordId && !this.selectedAccountId) {
                this.selectedAccountId = this.recordId;
                this.loadAnalysis();
            }
        } else if (error) {
            this.errorMsg = this.reduceError(error);
        }
    }

    handleAccountChange(event) {
        this.selectedAccountId = event.detail.value;
        this.loadAnalysis();
    }

    loadAnalysis() {
        if (!this.selectedAccountId) {
            return;
        }
        this.loading = true;
        this.errorMsg = undefined;
        getAnalysis({ accountId: this.selectedAccountId })
            .then((res) => {
                this.data = res;
            })
            .catch((err) => {
                this.errorMsg = this.reduceError(err);
                this.data = undefined;
            })
            .finally(() => {
                this.loading = false;
            });
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return 'Unknown error';
    }

    get hasData() {
        return this.data != null;
    }

    // ---- formatting helpers ----
    fmtKRW(v) {
        if (v === null || v === undefined) {
            return '-';
        }
        const eok = v / 100000000; // 억원
        return `${eok.toLocaleString('ko-KR', { maximumFractionDigits: 0 })} 억원`;
    }

    get profileRevenue() {
        return this.data ? this.fmtKRW(this.data.annualRevenue) : '-';
    }
    get profileEmployees() {
        return this.data && this.data.numberOfEmployees != null
            ? this.data.numberOfEmployees.toLocaleString('ko-KR') + ' 명'
            : '-';
    }
    get cashDisplay() {
        return this.data ? this.fmtKRW(this.data.cash) : '-';
    }
    get shortTermDisplay() {
        return this.data ? this.fmtKRW(this.data.shortTerm) : '-';
    }
    get estFundsDisplay() {
        return this.data ? this.fmtKRW(this.data.estimatedInvestableFunds) : '-';
    }
    get closedWonDisplay() {
        return this.data ? this.fmtKRW(this.data.closedWonAmount) : '-';
    }
    get proxyDisplay() {
        return this.data && this.data.hasProxy ? this.fmtKRW(this.data.whitespaceProxy) : '-';
    }

    get ownedRows() {
        if (!this.data || !this.data.ownedProducts) {
            return [];
        }
        return this.data.ownedProducts.map((p, i) => ({
            key: i,
            name: p.name || '(상품 미지정)',
            family: p.family || '-',
            amount: this.fmtKRW(p.amount)
        }));
    }
    get hasOwned() {
        return this.data && this.data.ownedProducts && this.data.ownedProducts.length > 0;
    }
    get whitespaceRows() {
        if (!this.data || !this.data.whitespaceProducts) {
            return [];
        }
        return this.data.whitespaceProducts.map((n, i) => ({ key: i, name: n }));
    }
    get hasWhitespace() {
        return this.data && this.data.whitespaceProducts && this.data.whitespaceProducts.length > 0;
    }

    get noRecommendation() {
        return this.data && !this.data.hasUpsell && !this.data.hasCrossSell;
    }

    // ---- inline SVG line chart (no external libs) ----
    get hasTrend() {
        return this.data && this.data.trend && this.data.trend.length > 0;
    }

    get chartViewBox() {
        return `0 0 ${CHART_W} ${CHART_H}`;
    }

    get chart() {
        if (!this.hasTrend) {
            return null;
        }
        const pts = this.data.trend;
        const cashVals = pts.map((p) => (p.cash == null ? 0 : p.cash));
        const stVals = pts.map((p) => (p.shortTerm == null ? 0 : p.shortTerm));
        const maxV = Math.max(1, ...cashVals, ...stVals);
        const n = pts.length;
        const xStep = n > 1 ? (CHART_W - 2 * PAD) / (n - 1) : 0;
        const yFor = (v) => CHART_H - PAD - (v / maxV) * (CHART_H - 2 * PAD);
        const xFor = (i) => PAD + i * xStep;

        const cashLine = cashVals.map((v, i) => `${xFor(i)},${yFor(v)}`).join(' ');
        const stLine = stVals.map((v, i) => `${xFor(i)},${yFor(v)}`).join(' ');

        const cashDots = cashVals.map((v, i) => ({ key: 'c' + i, cx: xFor(i), cy: yFor(v) }));
        const labels = pts.map((p, i) => ({
            key: 'l' + i,
            x: xFor(i),
            y: CHART_H - PAD + 14,
            text: p.label
        })).filter((_, i) => n <= 8 || i % 2 === 0); // thin out labels when dense

        return {
            width: CHART_W,
            height: CHART_H,
            cashLine,
            stLine,
            cashDots,
            labels,
            baselineY: CHART_H - PAD
        };
    }
}