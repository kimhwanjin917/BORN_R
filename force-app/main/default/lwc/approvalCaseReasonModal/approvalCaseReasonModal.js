import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/**
 * 약정수익률이 상한(연 7%)을 넘어 상품팀 전달이 막혔을 때 뜨는 사유 입력 모달.
 * sendToProductTeamAction 이 LightningModal.open() 으로 띄운다. [Case 생성] 을 누르면
 * 입력한 사유·계약기간(개월)을 close(payload) 로 돌려주고, 액션이 createApprovalCase 를 호출한다.
 */
export default class ApprovalCaseReasonModal extends LightningModal {
    @api rpYield;
    @api yieldCap;

    reason = '';

    get headerText() {
        return '판매 승인 요청 Case 생성';
    }

    get warningText() {
        return `약정수익률(${this.rpYield}%)이 상한 ${this.yieldCap}%를 초과하여 상품팀에 바로 전달할 수 없습니다. 아래 사유를 남기면 판매 승인 요청 Case 를 생성해 심사를 요청합니다.`;
    }

    handleReasonChange(event) {
        this.reason = event.detail.value;
    }

    handleCancel() {
        this.close(null);
    }

    handleCreate() {
        const input = this.template.querySelector('[data-id="reason"]');
        if (!this.reason || !this.reason.trim()) {
            input.setCustomValidity('Case 사유를 입력하세요.');
            input.reportValidity();
            return;
        }
        input.setCustomValidity('');
        this.close({ reason: this.reason.trim() });
    }
}