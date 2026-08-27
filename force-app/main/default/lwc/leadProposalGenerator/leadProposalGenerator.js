import { LightningElement, api, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/LeadProposalController.getContext';
import generate from '@salesforce/apex/LeadProposalController.generate';

const EOK = 100000000;

export default class LeadProposalGenerator extends NavigationMixin(LightningElement) {
    _recordId;
    _started = false;

    isLoading = true;
    isGenerating = false;
    errorMessage;

    @track context;
    @track rows = [];
    backgroundMemo = '';
    assumedAmount;

    result;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        // Quick Action 진입 시 recordId 가 늦게 채워지는 race condition 대응
        if (value && !this._started) {
            this._started = true;
            this.load();
        }
    }

    async load() {
        try {
            const ctx = await getContext({ leadId: this.recordId });
            this.context = ctx;
            this.rows = (ctx.catalog || []).map((item) => ({
                ...item,
                selected: item.recommended,
                yieldRate: null
            }));
            this.sortRows();
        } catch (error) {
            this.errorMessage = this.messageOf(error, '제안서 화면을 여는 중 오류가 발생했습니다.');
        } finally {
            this.isLoading = false;
        }
    }

    // 추천된 상품을 위로 올린다. 그 안에서는 서버가 내려준 순서(상품군·기간)를 유지한다.
    sortRows() {
        const picked = this.rows.filter((r) => r.selected);
        const rest = this.rows.filter((r) => !r.selected);
        this.rows = [...picked, ...rest];
    }

    get displayRows() {
        return this.rows.map((r) => ({
            ...r,
            rowClass: r.selected ? 'lpg-row lpg-row-on' : 'lpg-row',
            feeText: r.feeRate === null || r.feeRate === undefined ? '-' : `${r.feeRate}%`
        }));
    }

    get selectedRows() {
        return this.rows.filter((r) => r.selected);
    }

    get hasSelection() {
        return this.selectedRows.length > 0;
    }

    get isGenerateDisabled() {
        return !this.hasSelection || this.isGenerating;
    }

    get hasFinancials() {
        return this.context && this.context.hasFinancials;
    }

    get hasAgentRecommendation() {
        return this.context && this.context.hasAgentRecommendation;
    }

    // 에이전트 추천이 있을 때와 없을 때를 눈에 띄게 구분한다.
    // 없는데 파란 "추천 근거" 상자로 보이면 RM 이 추천을 받은 것으로 오해한다.
    get rationaleTitle() {
        return this.hasAgentRecommendation ? '에이전트 추천 (미팅 준비 브리핑과 동일)' : '자동 추천 없음';
    }

    get rationaleClass() {
        return this.hasAgentRecommendation ? 'lpg-rationale' : 'lpg-rationale lpg-rationale-none';
    }

    get financeLine() {
        const c = this.context;
        if (!c || !c.hasFinancials) {
            return '';
        }
        const parts = [`현금성자산 ${this.eok(c.cash)}`];
        if (c.shortTermInstruments) {
            parts.push(`단기금융상품 ${this.eok(c.shortTermInstruments)}`);
        }
        if (c.shortTermBorrowings) {
            parts.push(`단기차입금 ${this.eok(c.shortTermBorrowings)}`);
        }
        return `${parts.join(' · ')}  (${c.finReportLabel}, ${c.finPeriodYm})`;
    }

    get assumedAmountHelp() {
        if (!this.assumedAmount) {
            return '비워두면 예상 수익 비교표 없이 상품 목록만 출력됩니다.';
        }
        return `${this.eok(this.assumedAmount)} 기준으로 상품별 세전·세후 수익을 계산합니다.`;
    }

    eok(value) {
        if (!value) {
            return '-';
        }
        return `${Math.round(value / EOK).toLocaleString('ko-KR')}억원`;
    }

    handleToggle(event) {
        const id = event.currentTarget.dataset.id;
        this.rows = this.rows.map((r) => (r.productId === id ? { ...r, selected: event.target.checked } : r));
    }

    handleYieldChange(event) {
        const id = event.currentTarget.dataset.id;
        const raw = event.target.value;
        const parsed = raw === '' || raw === null ? null : parseFloat(raw);
        this.rows = this.rows.map((r) => (r.productId === id ? { ...r, yieldRate: parsed } : r));
    }

    handleMemoChange(event) {
        this.backgroundMemo = event.target.value;
    }

    handleAmountChange(event) {
        const raw = event.target.value;
        this.assumedAmount = raw === '' || raw === null ? null : parseFloat(raw);
    }

    async handleGenerate() {
        const missing = this.selectedRows.filter((r) => r.yieldRate === null || r.yieldRate === undefined);
        if (missing.length > 0) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '적용 수익률을 입력해 주세요',
                    message: `${missing.map((r) => r.name).join(', ')} 의 수익률이 비어 있습니다.`,
                    variant: 'warning'
                })
            );
            return;
        }

        this.isGenerating = true;
        this.errorMessage = undefined;
        try {
            this.result = await generate({
                leadId: this.recordId,
                selections: this.selectedRows.map((r) => ({ productId: r.productId, yieldRate: r.yieldRate })),
                backgroundMemo: this.backgroundMemo,
                assumedAmount: this.assumedAmount || null
            });
        } catch (error) {
            this.errorMessage = this.messageOf(error, '제안서 생성 중 오류가 발생했습니다.');
        } finally {
            this.isGenerating = false;
        }
    }

    handleOpenFile() {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: this.result.contentDocumentId }
        });
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    messageOf(error, fallback) {
        return error?.body?.message || error?.message || fallback;
    }
}