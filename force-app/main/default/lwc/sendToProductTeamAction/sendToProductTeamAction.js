import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import sendToProductTeam from '@salesforce/apex/DealTermCollabController.sendToProductTeam';
import createApprovalCase from '@salesforce/apex/DealTermCollabController.createApprovalCase';
import ApprovalCaseReasonModal from 'c/approvalCaseReasonModal';

/**
 * docs/58 Scene 3 — Opportunity 헤드리스 Quick Action "상품팀 전달".
 * 버튼을 눌렀을 때(invoke) 에만 실행한다. recordId 세팅 시점에 실행하면 페이지 로드만으로 돌아버린다(2026-08-28 실측).
 * 실행: 딜 Slack 채널 생성 + RM·상품팀 담당자 초대 + 미팅 요약·조건 카드 게시.
 * 약정수익률이 상한(연 7%)을 넘으면(state.yieldExceeded) 전달 대신 사유 입력 모달을 띄우고
 * 판매 승인 요청 Case 를 생성한다(2026-09-01 요구).
 */
export default class SendToProductTeamAction extends LightningElement {
    @api recordId;
    running = false;

    @api async invoke() {
        if (this.running) return;
        this.running = true;
        try {
            const state = await sendToProductTeam({ opportunityId: this.recordId });
            if (state.yieldExceeded) {
                await this.handleYieldExceeded(state);
                return;
            }
            getRecordNotifyChange([{ recordId: this.recordId }]);
            // 전달은 정상 완료됐지만 [조건 확정하기] 로 만든 확정 조건서가 없어 PDF 를 첨부하지 못한 경우엔
            // 경고로 알린다. 전달 자체를 막지는 않는다(수수료 미정 상태로도 채널을 여는 기존 동작 유지).
            this.dispatchEvent(state.termPdfMissing
                ? new ShowToastEvent({
                    title: '상품팀 전달 완료',
                    message: '확정 조건서가 없어 PDF 첨부 없이 상품팀에 전달했습니다.',
                    variant: 'warning'
                })
                : new ShowToastEvent({
                    title: '상품팀 전달 완료',
                    message: state.message || '상품팀 채널이 열렸습니다.',
                    variant: 'success'
                }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: '상품팀 전달 실패',
                message: e?.body?.message || e?.message,
                variant: 'error'
            }));
        } finally {
            this.running = false;
            this.dispatchEvent(new CloseActionScreenEvent());
        }
    }

    /** 약정수익률 상한 초과 — 사유 입력 모달을 띄우고, 확인하면 판매 승인 요청 Case 를 만든다. */
    async handleYieldExceeded(state) {
        const result = await ApprovalCaseReasonModal.open({
            size: 'small',
            rpYield: state.rpYield,
            yieldCap: state.yieldCap
        });
        if (!result) {
            // 사용자가 취소 — 전달도 Case 생성도 하지 않는다.
            return;
        }
        const caseState = await createApprovalCase({
            opportunityId: this.recordId,
            reason: result.reason,
            termMonths: null
        });
        getRecordNotifyChange([{ recordId: this.recordId }]);
        this.dispatchEvent(new ShowToastEvent({
            title: '판매 승인 요청 Case 생성',
            message: caseState.message || '판매 승인 요청 Case 를 생성했습니다.',
            variant: 'success'
        }));
    }
}