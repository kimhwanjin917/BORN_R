import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import getState from '@salesforce/apex/DealTermCollabController.getState';
import createContract from '@salesforce/apex/DealTermCollabController.createContract';
import submitReply from '@salesforce/apex/DealTermCollabController.submitReply';
import BONI from '@salesforce/resourceUrl/BoniImages';

const POLL_MS = 5000;

/**
 * docs/58 Scene 3 — Opportunity 레코드 페이지의 상품팀 조건 협의 패널.
 * WAITING(수수료 입력 전) → REVIEWING(딜 채널 생성, 5초 폴링) → REPLIED(회신 도착, 계약서 생성 버튼) → DONE.
 */
export default class DealTermCollab extends LightningElement {
    @api recordId;
    state;
    error;
    isLoading = true;
    isCreating = false;
    isSubmitting = false;
    pollTimer;
    replyForm = { rpYield: null, appliedFeeRate: null, couponRate: null, issuerName: '' };

    connectedCallback() {
        this.load();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    async load() {
        try {
            this.state = await getState({ opportunityId: this.recordId });
            this.error = undefined;
            if (this.state.stage === 'REVIEWING') {
                this.startPolling();
            } else {
                this.stopPolling();
            }
        } catch (e) {
            this.error = e?.body?.message || e?.message || '상태를 불러오지 못했습니다.';
        } finally {
            this.isLoading = false;
        }
    }

    startPolling() {
        if (this.pollTimer) return;
        this.pollTimer = setInterval(async () => {
            const prev = this.state?.stage;
            await this.load();
            if (prev === 'REVIEWING' && this.state?.stage === 'REPLIED') {
                getRecordNotifyChange([{ recordId: this.recordId }]);
                this.dispatchEvent(new ShowToastEvent({
                    title: '상품팀 회신 도착',
                    message: `${this.state.replyBy} 님이 조건을 회신했습니다.`,
                    variant: 'success'
                }));
            }
        }, POLL_MS);
    }

    stopPolling() {
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = undefined;
        }
    }

    async handleCreateContract() {
        this.isCreating = true;
        try {
            this.state = await createContract({ opportunityId: this.recordId });
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({
                title: '계약서 생성 완료',
                message: this.state.message || `계약 ${this.state.contractNumber}`,
                variant: 'success'
            }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: '계약서 생성 실패',
                message: e?.body?.message || e?.message,
                variant: 'error'
            }));
        } finally {
            this.isCreating = false;
        }
    }

    handleReplyChange(event) {
        const { name, value } = event.target;
        this.replyForm = { ...this.replyForm, [name]: value };
    }

    /** Salesforce 화면에서 상품팀 회신 — Slack 카드 회신과 같은 처리(필드 갱신 + Slack 채널에 회신 완료 카드). */
    async handleSubmitReply() {
        this.isSubmitting = true;
        const num = (v) => (v === '' || v === null || v === undefined ? null : Number(v));
        try {
            this.stopPolling();
            this.state = await submitReply({
                opportunityId: this.recordId,
                rpYield: num(this.replyForm.rpYield),
                appliedFeeRate: num(this.replyForm.appliedFeeRate),
                couponRate: num(this.replyForm.couponRate),
                issuerName: this.replyForm.issuerName || null
            });
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({
                title: '회신 완료',
                message: this.state.message,
                variant: 'success'
            }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: '회신 실패',
                message: e?.body?.message || e?.message,
                variant: 'error'
            }));
            if (this.state?.stage === 'REVIEWING') this.startPolling();
        } finally {
            this.isSubmitting = false;
        }
    }

    handleRefresh() {
        this.isLoading = true;
        this.load();
    }

    get isWaiting() { return this.state?.stage === 'WAITING'; }
    get isReviewing() { return this.state?.stage === 'REVIEWING'; }
    get isReplied() { return this.state?.stage === 'REPLIED'; }
    get isDone() { return this.state?.stage === 'DONE'; }
    /** docs/60 별건 — 완료 화면 보니(깃발 포즈) */
    get boniFlagUrl() { return BONI + '/flag.png'; }
    get hasFee() { return this.state?.feeRate != null; }
    get feeText() { return this.hasFee ? `${this.state.feeRate}%` : ''; }
    get baseFeeText() { return this.state?.baseFeeRate == null ? '' : `${this.state.baseFeeRate}%`; }
    get replyAtText() {
        return this.state?.replyAt
            ? new Date(this.state.replyAt).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })
            : '';
    }
    get contractUrl() { return this.state?.contractId ? `/${this.state.contractId}` : ''; }
    get pdfUrl() {
        return this.state?.contractDocumentId
            ? `/sfc/servlet.shepherd/document/download/${this.state.contractDocumentId}`
            : '';
    }
}