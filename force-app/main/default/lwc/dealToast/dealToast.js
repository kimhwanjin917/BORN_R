import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import DEAL_TOAST_CHANNEL from '@salesforce/messageChannel/DealToast__c';

/**
 * 레코드 페이지에 상주하는 커스텀 토스트.
 * ShowToastEvent(플랫폼 토스트)는 앱 최상단 다른 shadow DOM 에 그려져 CSS 로 스타일을 못 바꾼다.
 * 그래서 딜 Quick Action 들은 DealToast LMS 채널로 메시지만 발행하고, 이 컴포넌트가 직접 카드를 그린다.
 * 홈 대시보드의 민트 토스트와 같은 룩앤필. 자동 닫힘 + 수동 닫기 + role/aria 포함.
 */
const AUTO_DISMISS_MS = 5000;

export default class DealToast extends LightningElement {
    visible = false;
    title = '';
    message = '';
    variant = 'success';

    _subscription;
    _timer;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        if (this._subscription) return;
        this._subscription = subscribe(this.messageContext, DEAL_TOAST_CHANNEL, (payload) =>
            this.show(payload)
        );
    }

    disconnectedCallback() {
        if (this._subscription) {
            unsubscribe(this._subscription);
            this._subscription = undefined;
        }
        this.clearTimer();
    }

    show(payload) {
        this.title = payload?.title || '';
        this.message = payload?.message || '';
        this.variant = payload?.variant || 'success';
        this.visible = true;
        this.clearTimer();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setTimeout(() => this.close(), AUTO_DISMISS_MS);
    }

    close() {
        this.visible = false;
        this.clearTimer();
    }

    handleClose() {
        this.close();
    }

    clearTimer() {
        if (this._timer) {
            clearTimeout(this._timer);
            this._timer = undefined;
        }
    }

    get isError() {
        return this.variant === 'error';
    }
    get isWarning() {
        return this.variant === 'warning';
    }

    get toastClass() {
        const base = 'deal-toast';
        if (this.isError) return `${base} deal-toast_error`;
        if (this.isWarning) return `${base} deal-toast_warning`;
        return `${base} deal-toast_success`;
    }

    get iconName() {
        if (this.isError) return 'utility:error';
        if (this.isWarning) return 'utility:warning';
        return 'utility:success';
    }

    get ariaRole() {
        return this.isError ? 'alert' : 'status';
    }
}