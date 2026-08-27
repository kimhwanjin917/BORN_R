import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import getMeetingContext from '@salesforce/apex/MeetingSessionContextController.getMeetingContext';
import {
    FlowAttributeChangeEvent,
    FlowNavigationNextEvent
} from 'lightning/flowSupport';

const DAYS_IN_YEAR = 365;

// The Flow creates a new component instance for each screen. Keep the draft in
// page memory so memo/fee inputs remain visible after recommendation without
// writing sensitive meeting text to browser storage.
const draftCache = new Map();

function safeParseJson(str) {
    try {
        return JSON.parse(str);
    } catch (_) {
        return null;
    }
}

export default class MeetingNotePad extends LightningElement {
    @api availableActions = [];

    _rawContent = '';
    _followUpQuestion = '';
    _recommendation = '';
    _sanitizedContent = '';
    _maskedCount = 0;
    _isSubmitting = false;
    _recordId = '';

    @track _selectedProductName = '';
    @track _selectedRecommendationText = '';
    @track showConfirmModal = false;
    @track _pendingProductName = '';
    @track _isFollowUpExpanded = false;
    @track showMaskingModal = false;
    @track showBriefing = false;
    @track contextLoading = false;
    @track contextError = '';
    @track context = {};

    dealAmount = null;
    annualYield = null;
    feeRate = null;
    termDays = null;

    connectedCallback() {
        // Screen Flows opened through /flow/... keep input variables in the
        // query string but do not automatically bind them to LWC properties.
        // Read only the current page URL so the context header works without a
        // Flow version change.
        if (!this._recordId) {
            try {
                const pageRecordId = new URLSearchParams(window.location.search).get('recordId');
                if (pageRecordId) this.recordId = pageRecordId;
            } catch (_) {
                // CurrentPageReference remains as the Lightning-hosted fallback.
            }
        }
    }

    // ─── Flow input / output @api properties ──────────────────────────────

    @api
    get recordId() { return this._recordId; }
    set recordId(value) {
        if (value && value !== this._recordId) {
            this._recordId = value;
            this._restoreDraft();
            this._loadContext();
        }
    }

    @wire(CurrentPageReference)
    setCurrentPageReference(pageReference) {
        const stateRecordId = pageReference?.state?.recordId ||
            pageReference?.state?.c__recordId ||
            pageReference?.attributes?.recordId;
        if (stateRecordId && !this._recordId) {
            this.recordId = stateRecordId;
        }
    }

    @api
    get rawContent() { return this._rawContent; }
    set rawContent(value) { this._rawContent = value || ''; }

    @api
    get followUpQuestion() { return this._followUpQuestion; }
    set followUpQuestion(value) { this._followUpQuestion = value || ''; }

    @api
    get recommendation() { return this._recommendation; }
    set recommendation(value) {
        this._recommendation = this._extractRecommendationText(value);
    }

    @api
    get sanitizedContent() { return this._sanitizedContent; }
    set sanitizedContent(value) { this._sanitizedContent = value || ''; }

    @api
    get maskedCount() { return this._maskedCount; }
    set maskedCount(value) { this._maskedCount = Number(value) || 0; }

    @api
    get isSubmitting() { return this._isSubmitting; }
    set isSubmitting(value) { this._isSubmitting = Boolean(value); }

    // outputOnly – consumed by Flow downstream
    @api
    get normalizedRecommendation() { return this._recommendation; }

    @api
    get selectedProductName() { return this._selectedProductName; }
    set selectedProductName(value) { this._selectedProductName = value || ''; }

    @api
    get selectedRecommendationText() { return this._selectedRecommendationText; }
    set selectedRecommendationText(value) { this._selectedRecommendationText = value || ''; }

    // ─── Template getters ──────────────────────────────────────────────────

    get rawContentValue() { return this._rawContent; }
    get followUpQuestionValue() { return this._followUpQuestion; }
    get rawContentLength() { return this._rawContent.length; }

    get hasRecommendation() {
        return Boolean(this._recommendation && this._recommendation.trim());
    }

    get isSaved() {
        return this.hasRecommendation ||
            Boolean(this._sanitizedContent && this._sanitizedContent.trim());
    }

    get hasSanitizedContent() {
        return Boolean(this._sanitizedContent && this._sanitizedContent.trim());
    }

    // The memo stays editable through recommendation and confirmation.
    get showMemoEditor() { return true; }

    get contextName() { return this.context.recordName || '고객 정보 확인 중'; }
    get contextObjectLabel() { return this.context.objectLabel || 'Salesforce'; }
    get contextCompany() { return this.context.companyName || '연결된 기업 정보 없음'; }
    get contextOwner() { return this.context.ownerName || '담당자 미지정'; }
    get contextStatus() { return this.context.status || '미팅 준비'; }
    get contextBriefing() {
        return this.context.briefing || '저장된 기업 브리핑이 없습니다. 미팅 메모를 바탕으로 내용을 보완할 수 있습니다.';
    }
    get contextRecommendationReason() {
        return this.context.recommendationReason || '기업 정보와 현재 영업 단계를 기준으로 추천 근거를 생성할 준비가 되었습니다.';
    }
    get briefingButtonLabel() { return this.showBriefing ? '브리핑 닫기' : '기업 브리핑'; }
    get briefingChevron() { return this.showBriefing ? 'utility:chevronup' : 'utility:chevrondown'; }
    get maskingStatusLabel() {
        if (!this.isSaved) return '메모 등록 전';
        return this._maskedCount > 0 ? `${this._maskedCount}건 마스킹 완료` : '마스킹 완료';
    }

    get primaryButtonLabel() {
        if (this.hasRecommendation) {
            return (this._isFollowUpExpanded && this._followUpQuestion.trim())
                ? '추가 질문 보내기'
                : '추천 확정';
        }
        return '메모 등록';
    }

    // ─── Follow-up collapsible ─────────────────────────────────────────────

    get isFollowUpExpanded() { return String(this._isFollowUpExpanded); }

    get followUpChevron() {
        return this._isFollowUpExpanded ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get followUpPanelClass() {
        return this._isFollowUpExpanded
            ? 'mnp-followup__panel mnp-followup__panel--open'
            : 'mnp-followup__panel';
    }

    // ─── Confirmation modal ────────────────────────────────────────────────

    get confirmModalMessage() {
        return `${this._pendingProductName}(으)로 확정하시겠습니까?`;
    }

    // ─── Product cards ─────────────────────────────────────────────────────

    get hasProductCards() { return this._buildProductCards().length > 0; }
    get productCards() { return this._buildProductCards(); }
    get recommendationSummary() { return this._recommendation; }

    _buildProductCards() {
        if (!this._recommendation || !this._recommendation.trim()) return [];

        const parsed = safeParseJson(this._recommendation);
        if (!parsed) return [];

        let items = null;
        if (Array.isArray(parsed)) {
            items = parsed;
        } else if (Array.isArray(parsed.recommendations)) {
            items = parsed.recommendations;
        } else if (Array.isArray(parsed.products)) {
            items = parsed.products;
        } else if (Array.isArray(parsed.items)) {
            items = parsed.items;
        }

        if (!items || items.length === 0) return [];

        return items.slice(0, 3).map((item, idx) => {
            const name = item.name || item.productName || item.product_name || `상품 ${idx + 1}`;
            const reason = item.reason || item.description || item.rationale || '';
            const fit = item.fit || item.expectedFit || item.expected_fit || '';
            const rawScore = item.score || item.matchScore || item.match_score || '';
            const isSelected = this._selectedProductName === name;
            return {
                id: `pcard-${idx}`,
                name,
                reason,
                fit,
                score: rawScore ? `${rawScore}` : '',
                cardClass: `mnp-product-card${isSelected ? ' mnp-product-card--selected' : ''}`,
                buttonVariant: isSelected ? 'success' : 'brand'
            };
        });
    }

    // ─── Calculator ────────────────────────────────────────────────────────

    get grossInterest() { return this._annualizedAmount(this.annualYield); }
    get firmRevenue() { return this._annualizedAmount(this.feeRate); }
    get clientBenefit() { return this.grossInterest - this.firmRevenue; }
    get clientNetYield() {
        return this._num(this.annualYield) - this._num(this.feeRate);
    }
    get formattedClientBenefit() { return this._fmtCurrency(this.clientBenefit); }
    get formattedClientNetYield() { return this._fmtPercent(this.clientNetYield); }
    get formattedFirmRevenue() { return this._fmtCurrency(this.firmRevenue); }
    get formattedFirmYield() { return this._fmtPercent(this._num(this.feeRate)); }

    // ─── Event handlers ────────────────────────────────────────────────────

    handleRawContentChange(event) {
        this._rawContent = event.target.value;
        this._cacheDraft();
        event.target.setCustomValidity('');
        event.target.reportValidity();
    }

    handleFollowUpQuestionChange(event) {
        this._followUpQuestion = event.target.value;
        this._cacheDraft();
        event.target.setCustomValidity('');
        event.target.reportValidity();
    }

    handleCalculatorChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value === '' ? null : Number(event.target.value);
        this._cacheDraft();
    }

    handleToggleBriefing() { this.showBriefing = !this.showBriefing; }
    handleOpenMaskingModal() { this.showMaskingModal = true; }
    handleCloseMaskingModal() { this.showMaskingModal = false; }

    handleToggleFollowUp() {
        this._isFollowUpExpanded = !this._isFollowUpExpanded;
    }

    handleSelectProduct(event) {
        this._pendingProductName = event.currentTarget.dataset.productName;
        this.showConfirmModal = true;
    }

    handleModalCancel() {
        this.showConfirmModal = false;
        this._pendingProductName = '';
    }

    handleModalConfirm() {
        this._selectedProductName = this._pendingProductName;
        this._selectedRecommendationText = this._recommendation;
        this.showConfirmModal = false;
        this._pendingProductName = '';
        this.dispatchEvent(
            new FlowAttributeChangeEvent('selectedProductName', this._selectedProductName)
        );
        this.dispatchEvent(
            new FlowAttributeChangeEvent('selectedRecommendationText', this._selectedRecommendationText)
        );
    }

    handlePrimaryAction() {
        if (this._isSubmitting || !this._validatePrimaryInput()) return;

        this._isSubmitting = true;
        this._cacheDraft();
        this.dispatchEvent(new FlowAttributeChangeEvent('rawContent', this._rawContent));
        this.dispatchEvent(
            new FlowAttributeChangeEvent('followUpQuestion', this._followUpQuestion)
        );

        if (this.availableActions.includes('NEXT')) {
            this.dispatchEvent(new FlowNavigationNextEvent());
            return;
        }
        this._isSubmitting = false;
    }

    // ─── Private helpers ───────────────────────────────────────────────────

    _validatePrimaryInput() {
        if (this.hasRecommendation) {
            // Only require follow-up text when the panel is open and the user
            // clicked "추가 질문 보내기"; "추천 확정" path skips this check.
            if (this._isFollowUpExpanded && this._followUpQuestion.trim() === '') {
                const el = this.template.querySelector('[data-id="follow-up"]');
                if (el) {
                    el.setCustomValidity('추가 질문을 입력하거나 패널을 닫아주세요.');
                    el.reportValidity();
                }
                return false;
            }
            return true;
        }

        const el = this.template.querySelector('[data-id="raw-content"]');
        const isBlank = !this._rawContent.trim();
        if (el) {
            el.setCustomValidity(isBlank ? '미팅 내용을 입력해주세요.' : '');
            el.reportValidity();
        }
        return !isBlank;
    }

    async _loadContext() {
        if (!this._recordId || this.contextLoading) return;
        this.contextLoading = true;
        this.contextError = '';
        try {
            const result = await getMeetingContext({ recordId: this._recordId });
            this.context = result || {};
            if (!this._sanitizedContent && result?.sanitizedContent) {
                this._sanitizedContent = result.sanitizedContent;
            }
            if (!this._maskedCount && result?.maskedCount) {
                this._maskedCount = Number(result.maskedCount) || 0;
            }
        } catch (error) {
            this.contextError = error?.body?.message || '고객 컨텍스트를 불러오지 못했습니다.';
        } finally {
            this.contextLoading = false;
        }
    }

    _cacheDraft() {
        if (!this._recordId) return;
        draftCache.set(this._recordId, {
            rawContent: this._rawContent,
            followUpQuestion: this._followUpQuestion,
            dealAmount: this.dealAmount,
            annualYield: this.annualYield,
            feeRate: this.feeRate,
            termDays: this.termDays
        });
    }

    _restoreDraft() {
        const draft = draftCache.get(this._recordId);
        if (!draft) return;
        if (!this._rawContent) this._rawContent = draft.rawContent || '';
        if (!this._followUpQuestion) this._followUpQuestion = draft.followUpQuestion || '';
        this.dealAmount = draft.dealAmount ?? this.dealAmount;
        this.annualYield = draft.annualYield ?? this.annualYield;
        this.feeRate = draft.feeRate ?? this.feeRate;
        this.termDays = draft.termDays ?? this.termDays;
    }

    _extractRecommendationText(value) {
        if (!value) return '';
        if (typeof value !== 'string') {
            return value?.value?.message || value?.message || String(value);
        }
        const trimmed = value.trim();
        const parsed = safeParseJson(trimmed);
        if (parsed) {
            return parsed?.value?.message || parsed?.message || trimmed;
        }
        return trimmed;
    }

    _annualizedAmount(rate) {
        const principal = this._num(this.dealAmount);
        const days = this._num(this.termDays);
        const pct = this._num(rate) / 100;
        return principal * pct * (days / DAYS_IN_YEAR);
    }

    _num(value) {
        const p = Number(value);
        return Number.isFinite(p) ? p : 0;
    }

    _fmtCurrency(value) {
        return `${new Intl.NumberFormat('ko-KR', { maximumFractionDigits: 0 }).format(value)}원`;
    }

    _fmtPercent(value) {
        return `${new Intl.NumberFormat('ko-KR', {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }).format(value)}%`;
    }
}