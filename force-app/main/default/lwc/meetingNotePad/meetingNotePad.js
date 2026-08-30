import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import getMeetingContext from '@salesforce/apex/MeetingSessionContextController.getMeetingContext';
import saveMeetingNote from '@salesforce/apex/MeetingSessionContextController.saveMeetingNote';
import getRecommendation from '@salesforce/apex/MeetingSessionContextController.getRecommendation';
import saveDealTerms from '@salesforce/apex/MeetingSessionContextController.saveDealTerms';
import BONI from '@salesforce/resourceUrl/BoniImages'; // docs/60 별건(보니)
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
    _recommendation = '';
    _sanitizedContent = '';
    _maskedCount = 0;
    _isSubmitting = false;
    _recordId = '';

    @track _selectedProductName = '';
    @track _selectedRecommendationText = '';
    @track showConfirmModal = false;
    @track _pendingProductName = '';
    @track showMaskingModal = false;
    @track saving = false;
    // 모달 진행 상태: '' | 'saving' | 'masked' | 'recommending' | 'done' | 'recoFailed'
    @track saveStep = '';
    @track recoError = '';
    _pollTimer = null;
    _pollAttempts = 0;
    _meetingNoteId = null;      // 재등록 시 같은 Note 를 update 한다(중복 생성 방지)
    _opportunityId = '';        // saveMeetingNote 가 돌려주는 연결 영업기회 Id
    saveError = '';
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

    // Flow 버전들이 참조 중이라 삭제 불가 — UI 없음, 항상 빈 문자열
    @api
    get followUpQuestion() { return ''; }
    set followUpQuestion(value) {}

    @api
    get rawContent() { return this._rawContent; }
    set rawContent(value) { this._rawContent = value || ''; }

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

    // outputOnly – [미팅 저장] 시 Flow 의 MeetingNoteConfirmAction 에 넘길 메모 Id (docs/60)
    @api
    get meetingNoteId() { return this._meetingNoteId; }

    // outputOnly – 메모가 연결된 영업기회 Id. 완료 팝업 [확인] 시 이동 대상 (Flow 에서 boniDoneBanner 로 전달)
    @api
    get opportunityId() { return this._opportunityId; }

    @api
    get selectedProductName() { return this._selectedProductName; }
    set selectedProductName(value) { this._selectedProductName = value || ''; }

    @api
    get selectedRecommendationText() { return this._selectedRecommendationText; }
    set selectedRecommendationText(value) { this._selectedRecommendationText = value || ''; }

    // ─── Template getters ──────────────────────────────────────────────────

    get rawContentValue() { return this._rawContent; }
    get rawContentLength() { return this._rawContent.length; }

    /** docs/60 별건(보니) — 추천 빈 상태 일러스트 */
    get boniTabletUrl() { return BONI + '/tablet.png'; }
    /** 추천 생성 중 — 보니가 차트를 설명하는 일러스트 */
    get boniChartUrl() { return BONI + '/chart.png'; }

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

    // docs/60 — 하단 버튼은 언제나 "미팅 저장"(최종 저장만). 추천은 이 화면 안에서 끝낸다.
    get primaryButtonLabel() { return '미팅 저장'; }
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

    handleCalculatorChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value === '' ? null : Number(event.target.value);
        this._cacheDraft();
    }

    handleToggleBriefing() { this.showBriefing = !this.showBriefing; }
    get saveDisabled() {
        return this.saving || !(this._rawContent && this._rawContent.trim());
    }

    get saveButtonLabel() {
        return this.saving ? '등록 중…' : '메모 등록';
    }

    /**
     * 메모 등록. Flow 다음 Screen 으로 이동하지 않는다.
     * 저장 → MeetingNoteTrigger 가 MaskingService 로 마스킹 → 저장본 재조회 순서라
     * 마스킹이 끝난 뒤에만 모달을 연다.
     */
    async handleSaveMemo() {
        if (this.saveDisabled) {
            return;
        }
        this.saving = true;
        this.saveError = '';
        this.recoError = '';
        this.saveStep = 'saving';
        this.showMaskingModal = true;
        try {
            const result = await saveMeetingNote({
                recordId: this._recordId,
                rawContent: this._rawContent,
                meetingNoteId: this._meetingNoteId
            });
            this._meetingNoteId = result?.meetingNoteId || this._meetingNoteId;
            this._sanitizedContent = result?.sanitizedContent || '';
            this._maskedCount = Number(result?.maskedCount) || 0;
            this._opportunityId = result?.opportunityId || '';
            this.saveStep = 'masked';
            // 저장·마스킹은 여기서 이미 성공이다. 추천 실패가 이 상태를 되돌리지 않는다.
            if (!result?.opportunityId) {
                // docs/60 — 기회에 연결되지 않은 미팅(일정만 있는 경우 등)은 추천 대상이 아니다. 기다리지 않고 바로 안내.
                this.saveStep = 'noOpportunity';
            } else {
                this._startRecommendationPolling();
            }
        } catch (error) {
            this.saveError = this._saveErrorText(error);
            this.saveStep = '';
            this.showMaskingModal = false;
        } finally {
            this.saving = false;
        }
    }

    /**
     * 추천은 저장 후 비동기로 생성되므로 짧게 폴링한다.
     * 실패/타임아웃이어도 메모 저장과 마스킹 결과는 그대로 유지한다.
     */
    _startRecommendationPolling() {
        if (!this._meetingNoteId) {
            return;
        }
        this.saveStep = 'recommending';
        this._pollAttempts = 0;
        this._clearPollTimer();
        this._pollTimer = setInterval(() => {
            this._pollAttempts += 1;
            getRecommendation({ meetingNoteId: this._meetingNoteId })
                .then((state) => {
                    if (!state?.ready) {
                        // 에이전트 응답이 보통 20~30초 걸리므로 최대 90초(2초×45회) 기다린다. (docs/60)
                        if (this._pollAttempts >= 45) {
                            this._clearPollTimer();
                            this.recoError = '추천 생성이 지연되고 있습니다. 잠시 후 다시 확인해 주세요.';
                            this.saveStep = 'recoFailed';
                        }
                        return;
                    }
                    this._clearPollTimer();
                    if (state.failed) {
                        this.recoError = state.errorMessage || '상품 추천을 불러오지 못했습니다.';
                        this.saveStep = 'recoFailed';
                    } else {
                        this._recommendation = state.recommendation || '';
                        this.saveStep = 'done';
                    }
                })
                .catch((error) => {
                    this._clearPollTimer();
                    this.recoError = this._saveErrorText(error);
                    this.saveStep = 'recoFailed';
                });
        }, 2000);
    }

    _clearPollTimer() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }

    disconnectedCallback() {
        this._clearPollTimer();
    }

    // ─── 모달 진행 상태 표시용 getter ────────────────────────────────────
    get stepSaveDone()      { return this.saveStep !== '' && this.saveStep !== 'saving'; }
    get stepMaskDone()      { return this.stepSaveDone; }
    get stepRecommending()  { return this.saveStep === 'recommending'; }
    get stepRecoDone()      { return this.saveStep === 'done'; }
    get stepRecoFailed()    { return this.saveStep === 'recoFailed'; }
    get stepNoOpportunity() { return this.saveStep === 'noOpportunity'; }
    get modalBusy()         { return this.saveStep === 'saving' || this.saveStep === 'recommending'; }
    /** 저장·마스킹이 끝나면 바로 닫을 수 있다. 추천 대기는 모달 밖(추천 카드)에서 보여준다. */
    get modalCloseDisabled() { return this.saveStep === 'saving'; }
    get maskedCountLabel()  { return `개인정보 ${this._maskedCount}건 마스킹 완료`; }

    _saveErrorText(error) {
        return error?.body?.message || error?.message || '메모를 저장하지 못했습니다.';
    }

    handleOpenMaskingModal() { this.showMaskingModal = true; }
    // 모달을 닫아도 추천 폴링은 계속된다. 결과는 오른쪽 추천 카드에 자동 표시.
    handleCloseMaskingModal() {
        if (this.modalCloseDisabled) return;
        this.showMaskingModal = false;
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

    /**
     * docs/60 — [미팅 저장]: 이미 등록된 메모(+추천)를 최종 저장하는 Flow 단계로 넘긴다.
     * 메모 등록 전이면 막는다. 에이전트 호출은 여기서 하지 않는다.
     */
    async handlePrimaryAction() {
        if (this._isSubmitting) return;
        if (!this._meetingNoteId) {
            this.saveError = '먼저 [메모 등록]으로 메모를 저장해 주세요.';
            return;
        }
        this._clearPollTimer();
        this._isSubmitting = true;
        this._cacheDraft();
        // docs/58·60 연장 — 미팅 저장 시 수수료 조건을 기회에 저장. 실패해도 저장 흐름은 막지 않는다.
        try {
            await saveDealTerms({
                recordId: this._recordId,
                dealAmount: this.dealAmount,
                annualYield: this.annualYield,
                feeRate: this.feeRate,
                termDays: this.termDays
            });
        } catch (error) {
            // 조건 저장 실패는 미팅 저장을 막지 않는다.
        }
        this.dispatchEvent(new FlowAttributeChangeEvent('rawContent', this._rawContent));
        this.dispatchEvent(new FlowAttributeChangeEvent('meetingNoteId', this._meetingNoteId));
        this.dispatchEvent(new FlowAttributeChangeEvent('opportunityId', this._opportunityId));
        this.dispatchEvent(
            new FlowAttributeChangeEvent('normalizedRecommendation', this._recommendation)
        );

        if (this.availableActions.includes('NEXT') || this.availableActions.includes('FINISH')) {
            this.dispatchEvent(new FlowNavigationNextEvent());
            return;
        }
        this._isSubmitting = false;
    }

    // ─── Private helpers ───────────────────────────────────────────────────

    _validatePrimaryInput() {
        if (this.hasRecommendation) {
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