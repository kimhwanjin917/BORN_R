/**
 * 계약 [계약서 PDF 생성] 퀵액션 (헤드리스).
 *
 * ContractPdfService.generate 를 불러 계약서 PDF 를 만들고 그 계약에 첨부한다.
 * 성공하면 파일 목록이 바로 보이도록 페이지를 새로고침한다.
 */
/**
 * 계약 [계약서 PDF 생성] 퀵액션 (헤드리스).
 *
 * ContractPdfService.generate 를 불러 계약서 PDF 를 만들고 그 계약에 첨부한다.
 * 성공하면 파일 목록이 바로 보이도록 페이지를 새로고침한다.
 */
import { LightningElement, api, wire } from 'lwc';
import { publish, MessageContext } from 'lightning/messageService';
import { NavigationMixin } from 'lightning/navigation';
import DEAL_TOAST_CHANNEL from '@salesforce/messageChannel/DealToast__c';
import generate from '@salesforce/apex/ContractPdfService.generate';

export default class GenerateContractPdfAction extends NavigationMixin(LightningElement) {
    @api recordId;

    @wire(MessageContext)
    messageContext;

    @api async invoke() {
        try {
            const result = await generate({ contractId: this.recordId });

            if (!result.success) {
                this.toast('계약서 PDF 생성 실패', result.message, 'error');
                return;
            }

            this.toast('계약서 PDF 생성 완료', result.message, 'success');

            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.recordId,
                    objectApiName: 'Contract',
                    actionName: 'view'
                }
            });
        } catch (error) {
            this.toast('계약서 PDF 생성 실패', this.messageOf(error), 'error');
        }
    }

    messageOf(error) {
        return error?.body?.message || error?.message || '알 수 없는 오류가 발생했습니다.';
    }

    toast(title, message, variant) {
        publish(this.messageContext, DEAL_TOAST_CHANNEL, { title, message, variant });
    }
}