import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';

// 모든 진입점이 같은 Screen Flow를 전체 페이지로 연다. 객체별 Flow를 만들지 않는다.
const FLOW_API_NAME = 'Meeting_Session';

export default class MeetingSessionLauncher extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    /**
     * 첫 렌더 이전(connectedCallback)에 이동을 시작한다.
     * renderedCallback에서 이동하면 모달이 그려진 뒤에야 navigate가 걸려
     * 사용자에게 모달이 눈에 띄게 머문다.
     *
     * 컨텍스트(Account/Contact/Opportunity/Event) 해석은 Flow 안의
     * MeetingNoteContextService가 담당한다 — 여기서 Apex를 호출하지 않는다.
     */
    connectedCallback() {
        if (!this.recordId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: `/flow/${FLOW_API_NAME}?recordId=${encodeURIComponent(this.recordId)}`
            }
        });
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}