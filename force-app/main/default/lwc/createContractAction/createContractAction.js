/**
 * 영업기회 [계약서 작성] 퀵액션 (헤드리스).
 *
 * ContractPrefillController.getPrefill 로 조건 값을 받아 표준 계약 생성 폼을
 * 값이 채워진 상태로 연다. 레코드는 만들지 않는다 — 저장은 RM 이 폼에서 직접 한다.
 */
import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPrefill from '@salesforce/apex/ContractPrefillController.getPrefill';

export default class CreateContractAction extends NavigationMixin(LightningElement) {
    @api recordId;

    @api async invoke() {
        try {
            const result = await getPrefill({ opportunityId: this.recordId });

            if (!result.ready) {
                this.toast('계약서를 만들 수 없습니다', result.message, 'warning');
                return;
            }

            if (result.existingContractNumber) {
                this.toast(
                    '이미 생성된 계약이 있습니다',
                    `계약 ${result.existingContractNumber} 가 이 영업기회로 이미 만들어져 있습니다. 중복 여부를 확인하세요.`,
                    'warning'
                );
            }

            this[NavigationMixin.Navigate]({
                type: 'standard__objectPage',
                attributes: {
                    objectApiName: 'Contract',
                    actionName: 'new'
                },
                state: {
                    defaultFieldValues: encodeDefaultFieldValues(result.defaults),
                    nooverride: '1'
                }
            });
        } catch (error) {
            this.toast('계약서 작성 실패', this.messageOf(error), 'error');
        }
    }

    messageOf(error) {
        return error?.body?.message || error?.message || '알 수 없는 오류가 발생했습니다.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode: 'sticky' }));
    }
}