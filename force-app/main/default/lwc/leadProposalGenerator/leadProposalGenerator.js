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

    // 빈 객체로 시작한다. Apex 호출이 실패하면 context 가 채워지지 않는데,
    // undefined 인 채로 템플릿이 context.rationale 을 읽으면 컴포넌트가 통째로 죽어
    // 정작 사용자에게 보여줘야 할 오류 메시지조차 안 나온다.
    @track context = {};
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
            const ctx = await getContext({ recordId: this.recordId });
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

    // 숫자 입력은 onchange 만 걸면 값을 치고 바로 버튼을 눌렀을 때 커밋 전이라 반영되지 않는다.
    // oninput 도 함께 받고, 쉼표를 섞어 쳐도(10,000,000,000) 숫자로 읽는다.
    toNumber(raw) {
        if (raw === '' || raw === null || raw === undefined) {
            return null;
        }
        const cleaned = String(raw).replace(/[,\s]/g, '');
        const parsed = parseFloat(cleaned);
        return Number.isNaN(parsed) ? null : parsed;
    }

    handleYieldChange(event) {
        const id = event.currentTarget.dataset.id;
        const parsed = this.toNumber(event.target.value);
        this.rows = this.rows.map((r) => (r.productId === id ? { ...r, yieldRate: parsed } : r));
    }

    handleMemoChange(event) {
        this.backgroundMemo = event.target.value;
    }

    handleAmountChange(event) {
        this.assumedAmount = this.toNumber(event.target.value);
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

        // 상품 Id 가 빠진 행이 섞이면 서버에서 "상품 Id: null" 로만 보여 원인을 알 수 없다.
        // 화면이 낡은 캐시로 돌 때 실제로 이런 일이 있었다 — 여기서 걸러 안내한다.
        const selections = this.selectedRows
            .filter((r) => r.productId)
            .map((r) => ({ productId: r.productId, yieldRate: r.yieldRate }));
        if (selections.length === 0) {
            this.errorMessage =
                '상품 정보를 읽지 못했습니다. 브라우저를 강력 새로고침(Cmd+Shift+R) 후 다시 시도해 주세요.';
            return;
        }

        this.isGenerating = true;
        this.errorMessage = undefined;
        try {
            // 객체 배열을 그대로 넘기면 Apex 쪽 Selection 의 필드가 전부 null 로 도착한다.
            // (Aura 복합 타입 파라미터 바인딩에서 값이 유실된다 — 여기서는 값이 멀쩡하다.)
            // 문자열로 직렬화해 보내고 Apex 가 JSON.deserialize 로 되돌린다. 객체 배열로 되돌리지 말 것.
            this.result = await generate({
                recordId: this.recordId,
                selectionsJson: JSON.stringify(selections),
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