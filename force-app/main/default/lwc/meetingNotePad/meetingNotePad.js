import { LightningElement, api } from 'lwc';
import {
    FlowAttributeChangeEvent,
    FlowNavigationNextEvent
} from 'lightning/flowSupport';

const DAYS_IN_YEAR = 365;

export default class MeetingNotePad extends LightningElement {
    @api availableActions = [];

    _rawContent = '';
    _followUpQuestion = '';
    _recommendation = '';

    dealAmount = null;
    annualYield = null;
    feeRate = null;
    termDays = null;
    isSubmitting = false;

    @api
    get rawContent() {
        return this._rawContent;
    }

    set rawContent(value) {
        this._rawContent = value || '';
    }

    @api
    get followUpQuestion() {
        return this._followUpQuestion;
    }

    set followUpQuestion(value) {
        this._followUpQuestion = value || '';
    }

    @api
    get recommendation() {
        return this._recommendation;
    }

    set recommendation(value) {
        this._recommendation = this.normalizeRecommendation(value);
    }

    @api
    get normalizedRecommendation() {
        return this._recommendation;
    }

    get rawContentValue() {
        return this._rawContent;
    }

    get followUpQuestionValue() {
        return this._followUpQuestion;
    }

    get rawContentLength() {
        return this._rawContent.length;
    }

    get hasRecommendation() {
        return Boolean(this._recommendation.trim());
    }

    get primaryButtonLabel() {
        return this.hasRecommendation ? '추가 질문 보내기' : '메모 등록';
    }

    get grossInterest() {
        return this.calculateAnnualizedAmount(this.annualYield);
    }

    get firmRevenue() {
        return this.calculateAnnualizedAmount(this.feeRate);
    }

    get clientBenefit() {
        return this.grossInterest - this.firmRevenue;
    }

    get clientNetYield() {
        return this.numberValue(this.annualYield) - this.numberValue(this.feeRate);
    }

    get formattedClientBenefit() {
        return this.formatCurrency(this.clientBenefit);
    }

    get formattedClientNetYield() {
        return this.formatPercent(this.clientNetYield);
    }

    get formattedFirmRevenue() {
        return this.formatCurrency(this.firmRevenue);
    }

    get formattedFirmYield() {
        return this.formatPercent(this.numberValue(this.feeRate));
    }

    handleRawContentChange(event) {
        this._rawContent = event.target.value;
        event.target.setCustomValidity('');
        event.target.reportValidity();
    }

    handleFollowUpQuestionChange(event) {
        this._followUpQuestion = event.target.value;
        event.target.setCustomValidity('');
        event.target.reportValidity();
    }

    handleCalculatorChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value === '' ? null : Number(event.target.value);
    }

    handlePrimaryAction() {
        if (this.isSubmitting || !this.validatePrimaryInput()) {
            return;
        }

        this.isSubmitting = true;
        this.dispatchEvent(new FlowAttributeChangeEvent('rawContent', this._rawContent));
        this.dispatchEvent(
            new FlowAttributeChangeEvent('followUpQuestion', this._followUpQuestion)
        );

        if (this.availableActions.includes('NEXT')) {
            this.dispatchEvent(new FlowNavigationNextEvent());
            return;
        }

        this.isSubmitting = false;
    }

    validatePrimaryInput() {
        if (this.hasRecommendation) {
            const followUp = this.template.querySelector('[data-id="follow-up"]');
            const isBlank = !this._followUpQuestion.trim();
            followUp.setCustomValidity(isBlank ? '추가 질문을 입력해주세요.' : '');
            followUp.reportValidity();
            return !isBlank;
        }

        const rawContent = this.template.querySelector('[data-id="raw-content"]');
        const isBlank = !this._rawContent.trim();
        rawContent.setCustomValidity(isBlank ? '미팅 내용을 입력해주세요.' : '');
        rawContent.reportValidity();
        return !isBlank;
    }

    normalizeRecommendation(value) {
        if (!value) {
            return '';
        }

        if (typeof value !== 'string') {
            return value?.value?.message || value?.message || String(value);
        }

        const trimmed = value.trim();
        try {
            const parsed = JSON.parse(trimmed);
            return parsed?.value?.message || parsed?.message || trimmed;
        } catch (error) {
            return trimmed;
        }
    }

    calculateAnnualizedAmount(rate) {
        const principal = this.numberValue(this.dealAmount);
        const days = this.numberValue(this.termDays);
        const percentage = this.numberValue(rate) / 100;
        return principal * percentage * (days / DAYS_IN_YEAR);
    }

    numberValue(value) {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : 0;
    }

    formatCurrency(value) {
        return `${new Intl.NumberFormat('ko-KR', {
            maximumFractionDigits: 0
        }).format(value)}원`;
    }

    formatPercent(value) {
        return `${new Intl.NumberFormat('ko-KR', {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }).format(value)}%`;
    }
}