import { LightningElement, api, wire } from 'lwc';
import getSummary from '@salesforce/apex/ContractRpSummaryController.getSummary';

/**
 * Contract 레코드 페이지에 얹는 RP 확정조건 요약 카드 (조회 전용).
 * 편집 Form 이 아니다 — Contract 에 스냅샷된 확정조건과 자동 계산값을 읽기 쉽게 보여준다.
 * 계산(수익금·세금·환매예정금액)은 서버(ContractRpSummaryController → RpTermConfirmController.calculateRpTerms)에서
 * 계산해 내려온 값을 표시만 한다 — 화면에서 산식을 다시 만들지 않는다.
 */
export default class ContractRpSummary extends LightningElement {
    @api recordId;

    summary;
    error;
    loaded = false;

    @wire(getSummary, { contractId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            this.summary = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || '확정조건 요약을 불러오지 못했습니다.';
            this.summary = undefined;
        }
        this.loaded = true;
    }

    get hasError() {
        return !!this.error;
    }

    // ─── 표시용 포맷 ──────────────────────────────────────────────────
    _won(v) {
        return v === null || v === undefined ? '-' : `${new Intl.NumberFormat('ko-KR').format(v)} 원`;
    }
    _pct(v) {
        return v === null || v === undefined ? '-' : `${v} %`;
    }
    _text(v) {
        return v === null || v === undefined || v === '' ? '-' : v;
    }

    get dealId() { return this._text(this.summary?.dealId); }
    get accountName() { return this._text(this.summary?.accountName); }
    get rmName() { return this._text(this.summary?.rmName); }
    get contactName() { return this._text(this.summary?.contactName); }
    get productName() { return this._text(this.summary?.productName); }

    get dealDirection() { return this._text(this.summary?.dealDirection); }
    get startDate() { return this._text(this.summary?.startDate); }
    get maturityDate() { return this._text(this.summary?.maturityDate); }
    get amountText() { return this._won(this.summary?.amount); }
    get rpYieldText() { return this._pct(this.summary?.rpYield); }
    get yieldStructure() { return this._text(this.summary?.yieldStructure); }
    get yieldBasis() { return this._text(this.summary?.yieldBasis); }
    get feeRateText() { return this._pct(this.summary?.feeRate); }
    get feeAmountText() { return this._won(this.summary?.feeAmount); }
    get collateralRatioText() { return this._pct(this.summary?.collateralRatio); }
    get specialTerms() { return this._text(this.summary?.specialTerms); }

    get daysText() {
        const d = this.summary?.days;
        return d === null || d === undefined ? '-' : `${d} 일`;
    }
    get netInterestText() { return this._won(this.summary?.netInterest); }
    get withholdingTaxText() { return this._won(this.summary?.withholdingTax); }
    get redemptionAmountText() { return this._won(this.summary?.redemptionAmount); }
    get hasCalculation() { return !!this.summary?.hasCalculation; }

    get earlyRedemptionTerms() { return this._text(this.summary?.earlyRedemptionTerms); }
    get status() { return this._text(this.summary?.status); }

    get settlementAccessible() { return !!this.summary?.settlementAccount || this.summary?.settlementAccountAccessible; }
    get settlementAccountText() {
        if (!this.summary?.settlementAccountAccessible) {
            return '접근 권한 없음';
        }
        return this._text(this.summary?.settlementAccount);
    }
}