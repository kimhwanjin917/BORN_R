import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

// 홈 '오늘 일정'과 동일한 진입 패턴. 객체별 Flow를 만들지 않는다.
const FLOW_API_NAME = 'Meeting_Session';

/**
 * Record Page에 직접 배치하는 '미팅 시작' 버튼.
 *
 * Quick Action(lightning__RecordAction)은 Salesforce가 컴포넌트를 모달에
 * 호스팅하므로 전체 페이지 진입이 불가능하다. 이 컴포넌트는 홈의
 * homeTodaySchedule 과 똑같이 페이지에 인라인으로 렌더되므로 모달이 없다.
 *
 * 컨텍스트(Account / Contact / Opportunity / Event) 해석은 Flow 안의
 * MeetingNoteContextService 가 담당한다 — 여기서 Apex 를 호출하지 않는다.
 */
export default class MeetingStartButton extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;
    @api label = '미팅 시작';

    get isDisabled() {
        return !this.recordId;
    }

    handleStartMeeting() {
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