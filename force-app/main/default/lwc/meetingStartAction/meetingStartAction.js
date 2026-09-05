import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

// 홈 '오늘 일정'과 동일한 진입 패턴. 객체별 Flow를 만들지 않는다.
const FLOW_API_NAME = 'Meeting_Session';

/**
 * 하이라이트 패널 우측 상단 액션용 headless quick action.
 *
 * headless(actionType=Action)는 화면을 렌더하지 않으므로 모달이 아예 뜨지 않고
 * invoke() 에서 곧바로 전체 페이지로 이동한다.
 *
 * 컨텍스트(Account / Contact / Opportunity / Event) 해석은 Flow 안의
 * MeetingNoteContextService 가 담당한다 — 여기서 Apex 를 호출하지 않는다.
 */
export default class MeetingStartAction extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    @api
    invoke() {
        if (!this.recordId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: `/flow/${FLOW_API_NAME}?recordId=${encodeURIComponent(this.recordId)}`
            }
        });
    }
}