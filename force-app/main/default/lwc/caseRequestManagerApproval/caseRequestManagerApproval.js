import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import requestManagerApproval from '@salesforce/apex/DealApprovalService.requestManagerApproval';

/**
 * Case Quick Action "매니저 승인 요청" (Scene 3 · CASE B 딸깍①).
 * 상품팀 담당자가 Case 에서 클릭 → DealApprovalService.requestManagerApproval 이
 * 상품팀 전용 Slack 채널 생성/재사용 + 확정조건서 첨부 + 승인카드 게시 + Approval Process 제출을 한 번에 처리한다.
 * 화면은 확인 → 결과 표시만 담당하고, 실제 판단·처리는 Apex 가 한다.
 */
export default class CaseRequestManagerApproval extends LightningElement {
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
            const res = await requestManagerApproval({ caseId: this.recordId });
            this.success = res.success;
            this.message = res.message;
            this.done = true;
            this.dispatchEvent(new ShowToastEvent({
                title: res.success ? '매니저 승인 요청 완료' : '매니저 승인 요청 실패',
                message: res.message,
                variant: res.success ? 'success' : 'error'
            }));
            if (res.success) {
                getRecordNotifyChange([{ recordId: this.recordId }]);
            }
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