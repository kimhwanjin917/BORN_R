import { LightningElement, api, wire } from 'lwc';
import { publish, MessageContext } from 'lightning/messageService';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import DEAL_TOAST_CHANNEL from '@salesforce/messageChannel/DealToast__c';
import getInit from '@salesforce/apex/RpTermConfirmController.getInit';
import confirmTerms from '@salesforce/apex/RpTermConfirmController.confirmTerms';

/**
 * Opportunity 모달 Quick Action "조건 확정하기".
 * 저장과 PDF 생성은 Apex 한 번의 호출(confirmTerms) 안에서 같은 트랜잭션으로 처리된다 —
 * 저장이 실패하면 조건서도 남지 않는다. 화면단 검증은 Apex 검증과 같은 규칙을 먼저 보여주기 위한 것이고,
 * 최종 판단은 항상 Apex 가 한다.
 *
 * 자동입력(읽기전용): 거래ID(Opportunity.Name)·고객사·담당 RM·최종 협의 링크·상품팀 확정자.
 * 나머지 값은 Opportunity 에 저장된 값으로 prefill 하되 RM 이 확인/수정할 수 있다.
 * 모달을 여는 것(getInit)은 조회만 한다 — Opportunity 를 update 하지 않는다.
 */
const DAYS_IN_YEAR = 365;
const WITHHOLDING_RATE = 0.14; // 세후 계산 — Apex 와 동일 기준
const FEE_METHOD_RATE = '정률';
const FEE_METHOD_AMOUNT = '정액';

export default class RpTermConfirm extends LightningElement {
    _recordId;
    _loaded = false;

    @api
    set recordId(value) {
        this._recordId = value;
        if (value && !this._loaded) {
            this._loaded = true;
            this.load();
        }
    }
    get recordId() {
        return this._recordId;
    }

    @wire(MessageContext)
    messageContext;

    isLoading = true;
    isSaving = false;
    loadError;
    submitError;
    isReconfirm = false;

    // 읽기전용 자동 표시값
    dealId = '';
    accountName = '';
    ownerName = '';
    slackReplyLink = '';
    productTeamConfirmer = '';

    // 선택지
    productOptions = [];
    yieldStructureOptions = [];
    dealDirectionOptions = [];
    yieldBasisOptions = [];
    feeMethodOptions = [];
    feeBearerOptions = [];
    earlyRedemptionOptions = [];
    customerFinalAgreementOptions = [];

    form = {
        productId: null,
        dealDirection: null,
        startDate: null,
        endDate: null,
        amount: null,
        rpYield: null,
        yieldStructure: null,
        yieldBasis: null,
        feeMethod: null,
        feeRate: null,
        feeAmount: null,
        feeBearer: null,
        earlyRedemption: null,
        specialTerms: null,
        customerFinalAgreement: null,
        couponRate: null,
        collateralRatio: null
    };
    errors = {};

    async load() {
        try {
            const s = await getInit({ opportunityId: this.recordId });
            this.dealId = s.opportunityName || '';
            this.accountName = s.accountName || '';
            this.ownerName = s.ownerName || '';
            this.slackReplyLink = s.slackReplyLink || '';
            this.productTeamConfirmer = s.productTeamConfirmer || '';

            this.productOptions = (s.products || []).map((p) => ({ label: p.name, value: p.id }));
            this.yieldStructureOptions = this.toOptions(s.yieldStructures);
            this.dealDirectionOptions = this.toOptions(s.dealDirections);
            this.yieldBasisOptions = this.toOptions(s.yieldBases);
            this.feeMethodOptions = this.toOptions(s.feeMethods);
            this.feeBearerOptions = this.toOptions(s.feeBearers);
            this.earlyRedemptionOptions = this.toOptions(s.earlyRedemptions);
            this.customerFinalAgreementOptions = this.toOptions(s.customerFinalAgreements);

            this.form = {
                productId: s.productId || null,
                dealDirection: s.dealDirection || null,
                startDate: s.startDate || null,
                endDate: s.endDate || null,
                amount: s.amount,
                rpYield: s.rpYield,
                yieldStructure: s.yieldStructure || null,
                yieldBasis: s.yieldBasis || null,
                feeMethod: s.feeMethod || null,
                feeRate: s.feeRate,
                feeAmount: s.feeAmount,
                feeBearer: s.feeBearer || null,
                earlyRedemption: s.earlyRedemption || null,
                specialTerms: s.specialTerms || null,
                customerFinalAgreement: s.customerFinalAgreement || null,
                couponRate: s.couponRate,
                collateralRatio: s.collateralRatio
            };
            this.isReconfirm = !!s.hasConfirmedPdf;
            this.loadError = undefined;
        } catch (e) {
            this.loadError = this.messageOf(e) || '조건을 불러오지 못했습니다.';
        } finally {
            this.isLoading = false;
        }
    }

    toOptions(values) {
        return (values || []).map((v) => ({ label: v, value: v }));
    }

    handleChange(event) {
        const { name, value } = event.target;
        this.form = { ...this.form, [name]: value === '' ? null : value };
        if (this.errors[name]) {
            const next = { ...this.errors };
            delete next[name];
            this.errors = next;
        }
        this.submitError = undefined;
    }

    // ─── 수수료 방식 조건부 표시 ──────────────────────────────────────
    get isFeeRateMethod() {
        return this.form.feeMethod === FEE_METHOD_RATE;
    }
    get isFeeAmountMethod() {
        return this.form.feeMethod === FEE_METHOD_AMOUNT;
    }

    // ─── 환매예정금액 (읽기전용, 실시간 계산) ─────────────────────────
    // Apex computeRedemptionAmount 와 동일한 일할 공식: 원금 + 이자(세후면 원천징수 반영).
    get redemptionAmount() {
        const amount = this.num(this.form.amount);
        const rate = this.num(this.form.rpYield);
        const days = this.daysBetween(this.form.startDate, this.form.endDate);
        if (amount === null || rate === null || days === null || days < 0) {
            return null;
        }
        const gross = (amount * (rate / 100) * days) / DAYS_IN_YEAR;
        const interest = this.form.yieldBasis === '세후' ? gross * (1 - WITHHOLDING_RATE) : gross;
        return Math.round(amount + interest);
    }

    get redemptionAmountText() {
        const v = this.redemptionAmount;
        return v === null ? '계산 대기 중' : `${new Intl.NumberFormat('ko-KR').format(v)} 원`;
    }

    daysBetween(start, end) {
        if (!start || !end) return null;
        const s = Date.parse(start);
        const e = Date.parse(end);
        if (Number.isNaN(s) || Number.isNaN(e)) return null;
        return Math.round((e - s) / (1000 * 60 * 60 * 24));
    }

    num(v) {
        if (v === null || v === undefined || v === '') return null;
        const n = Number(v);
        return Number.isFinite(n) ? n : null;
    }

    /** Apex 의 validate() 와 같은 규칙. 필드 바로 아래에 메시지를 띄우기 위해 화면단에서도 본다. */
    validate() {
        const f = this.form;
        const e = {};
        const num = (v) => this.num(v);

        if (!f.productId) e.productId = '상품을 선택하세요.';
        if (!f.dealDirection) e.dealDirection = '거래방향을 선택하세요.';
        if (!f.startDate) e.startDate = '최초 매매일을 입력하세요.';
        if (!f.endDate) e.endDate = '환매일을 입력하세요.';
        if (num(f.amount) === null) e.amount = '거래금액을 입력하세요.';
        if (num(f.rpYield) === null) e.rpYield = '약정수익률을 입력하세요.';
        if (!f.yieldStructure) e.yieldStructure = '수익률 구조를 선택하세요.';
        if (!f.yieldBasis) e.yieldBasis = '수익률 기준을 선택하세요.';
        if (!f.feeMethod) e.feeMethod = '수수료 방식을 선택하세요.';
        if (!f.feeBearer) e.feeBearer = '수수료 부담 주체를 선택하세요.';
        if (!f.earlyRedemption) e.earlyRedemption = '중도환매 여부를 선택하세요.';
        if (!f.customerFinalAgreement) e.customerFinalAgreement = '고객 최종합의 상태를 선택하세요.';

        if (f.feeMethod === FEE_METHOD_RATE && num(f.feeRate) === null) {
            e.feeRate = '정률 방식은 확정 수수료율을 입력하세요.';
        }
        if (f.feeMethod === FEE_METHOD_AMOUNT && num(f.feeAmount) === null) {
            e.feeAmount = '정액 방식은 확정 수수료 금액을 입력하세요.';
        }

        if (f.startDate && f.endDate && f.endDate < f.startDate) {
            e.endDate = '환매일은 최초 매매일보다 빠를 수 없습니다.';
        }
        if (num(f.amount) !== null && num(f.amount) <= 0) {
            e.amount = '거래금액은 0보다 커야 합니다.';
        }
        if (num(f.feeAmount) !== null && num(f.feeAmount) < 0) {
            e.feeAmount = '수수료 금액은 0보다 작을 수 없습니다.';
        }
        if (num(f.rpYield) !== null && (num(f.rpYield) < 0 || num(f.rpYield) > 100)) {
            e.rpYield = '약정수익률은 0 ~ 100 % 사이여야 합니다.';
        }
        if (num(f.feeRate) !== null && (num(f.feeRate) < 0 || num(f.feeRate) >= 10)) {
            e.feeRate = '확정 수수료율은 0 이상 10 % 미만이어야 합니다.';
        }

        this.errors = e;
        return Object.keys(e).length === 0;
    }

    async handleConfirm() {
        if (this.isSaving) return;
        this.submitError = undefined;
        if (!this.validate()) {
            this.submitError = '입력값을 확인해 주세요.';
            return;
        }

        this.isSaving = true;
        const num = (v) => this.num(v);
        const isRate = this.form.feeMethod === FEE_METHOD_RATE;
        try {
            const input = {
                productId: this.form.productId,
                dealDirection: this.form.dealDirection,
                startDate: this.form.startDate,
                endDate: this.form.endDate,
                amount: num(this.form.amount),
                rpYield: num(this.form.rpYield),
                yieldStructure: this.form.yieldStructure,
                yieldBasis: this.form.yieldBasis,
                feeMethod: this.form.feeMethod,
                // 사용하지 않는 수수료 값은 넘기지 않는다 — Apex 도 방식에 맞게 하나만 저장한다.
                feeRate: isRate ? num(this.form.feeRate) : null,
                feeAmount: isRate ? null : num(this.form.feeAmount),
                feeBearer: this.form.feeBearer,
                earlyRedemption: this.form.earlyRedemption,
                specialTerms: this.form.specialTerms,
                customerFinalAgreement: this.form.customerFinalAgreement,
                couponRate: num(this.form.couponRate),
                collateralRatio: num(this.form.collateralRatio)
            };
            // Apex 정의 타입을 객체로 직접 넘기면 역직렬화가 전 필드 null 로 오는 경우가 있어(2026-08-31 실측),
            // JSON 문자열로 넘겨 Apex 에서 JSON.deserialize 로 확실히 복원한다.
            const r = await confirmTerms({ opportunityId: this.recordId, inputJson: JSON.stringify(input) });
            getRecordNotifyChange([{ recordId: this.recordId }]);
            publish(this.messageContext, DEAL_TOAST_CHANNEL, {
                title: '조건 확정 완료',
                message: `${r.message} (${r.fileName})`,
                variant: 'success'
            });
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (e) {
            // 저장이 실패하면 같은 트랜잭션의 PDF 도 롤백된다. 오류를 감추지 않고 그대로 보여준다.
            this.submitError = this.messageOf(e) || '조건 확정에 실패했습니다.';
        } finally {
            this.isSaving = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    get confirmDisabled() {
        return this.isSaving || this.isLoading || !!this.loadError;
    }

    get hasSlackReplyLink() {
        return !!this.slackReplyLink;
    }

    messageOf(e) {
        return e?.body?.message || e?.message;
    }
}