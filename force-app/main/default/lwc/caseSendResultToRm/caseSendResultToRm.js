import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import sendResultToRM from '@salesforce/apex/DealApprovalService.sendResultToRM';

/**
 * Case Quick Action "RM에게 승인 결과 보내기" (Scene 3 · CASE B 딸깍②).
 * 매니저 승인 후 상품팀 담당자가 Case 에서 클릭 → DealApprovalService.sendResultToRM 이
 * RM(연결 Opportunity 소유자)에게 Slack DM 통보 + 확정조건서 전달을 처리한다.
 * 승인('승인') 상태가 아니면 Apex 가 실패를 돌려주고 화면이 사유를 보여준다.
 */
export default class CaseSendResultToRm extends LightningElement {
    @api recordId;

    isWorking = false;
    done = false;
    success = false;
    message = '';

    get resultClass() {
        return this.success ? 'slds-text-color_success' : 'slds-text-color_error';
    }
    get resultIcon() {
        return this.success ? 'utility:success' : 'utility:error';
    }

    async handleConfirm() {
        this.isWorking = true;
        try {
            const res = await sendResultToRM({ caseId: this.recordId });
            this.success = res.success;
            this.message = res.message;
            this.done = true;
            this.dispatchEvent(new ShowToastEvent({
                title: res.success ? 'RM 전달 완료' : 'RM 전달 실패',
                message: res.message,
                variant: res.success ? 'success' : 'error'
            }));
        } catch (e) {
            this.success = false;
            this.message = e && e.body && e.body.message ? e.body.message : '알 수 없는 오류가 발생했습니다.';
            this.done = true;
            this.dispatchEvent(new ShowToastEvent({ title: '오류', message: this.message, variant: 'error' }));
        } finally {
            this.isWorking = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}