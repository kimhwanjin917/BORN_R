import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getMaturityAlertTaskRows from '@salesforce/apex/HomeDashboardController.getMaturityAlertTaskRows';

// Task.Subject 앞부분은 홈 카드가 Task를 찾는 검색 키라 레코드에서는 뗄 수 없다.
// 화면에 그릴 때만 잘라낸다 (Asset 이름을 못 읽은 행의 폴백 경로).
const SUBJECT_PREFIX = /^만기 30일 전 후속 영업\s*-\s*/;

export default class HomeMaturityAlerts extends NavigationMixin(LightningElement) {
    rows;
    tasksError;
    showTaskList = false;

    // 2026-09-03: getMaturityAlertTasks -> getMaturityAlertTaskRows.
    // Task.Subject는 생성 시점 이름 스냅샷이라 Asset 이름이 바뀌면 어긋난다.
    // 이 메서드는 Asset에서 이름·만기일을 실시간으로 읽어온다.
    @wire(getMaturityAlertTaskRows)
    wiredRows({ data, error }) {
        if (data) {
            this.rows = data.map((row) => this.toDisplayRow(row));
            this.tasksError = undefined;
            // 2026-08-27 (docs/55 §12): 만기 알림이 있으면 펼친 상태로 시작
            if (data.length > 0) {
                this.showTaskList = true;
            }
        } else if (error) {
            this.tasksError = this.reduceError(error);
            this.rows = undefined;
        }
    }

    toDisplayRow(row) {
        const maturity = row.maturityDate || row.activityDate;
        return {
            id: row.id,
            whatId: row.whatId,
            // Asset을 못 읽는 경우(삭제·권한)에만 Task 제목으로 폴백한다.
            name: row.assetName || (row.subject || '').replace(SUBJECT_PREFIX, ''),
            maturityLabel: maturity ? `만기일: ${maturity}` : '만기일 미정',
            ddayLabel: this.toDdayLabel(maturity)
        };
    }

    /** 남은 일수 그대로 표기한다. 당일은 D-DAY, 지난 건은 D+n. */
    toDdayLabel(maturity) {
        if (!maturity) {
            return '';
        }
        const [year, month, day] = maturity.split('-').map(Number);
        const target = Date.UTC(year, month - 1, day);
        const now = new Date();
        const today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
        const days = Math.round((target - today) / 86400000);
        if (days === 0) {
            return 'D-DAY';
        }
        return days > 0 ? `D-${days}` : `D+${Math.abs(days)}`;
    }

    get hasTasks() {
        return this.rows && this.rows.length > 0;
    }

    get taskCount() {
        return this.rows ? this.rows.length : 0;
    }

    toggleTaskList() {
        this.showTaskList = !this.showTaskList;
    }

    handleOpenTask(event) {
        // 2026-08-27 (docs/55 §12): 만기 알림 클릭 → 기회 레이더에서 해당 고객 선택 상태로 이동 (기존: Task 레코드)
        const whatId = event.currentTarget.dataset.whatId || event.currentTarget.dataset.id;
        if (!whatId) {
            return;
        }
        // 2026-09-03: standard__navItemPage + state 로는 c__whatId 가 플랫폼에서 유실되어, 레이더가
        // 딥링크를 못 받고 항상 1순위 고객을 골랐다. 같은 파라미터를 URL 로 직접 넘기면 정상 동작한다.
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: `/lightning/n/Opportunity_Radar?c__whatId=${encodeURIComponent(whatId)}` }
        });
    }

    reduceError(error) {
        return error?.body?.message || 'Unknown error';
    }
}