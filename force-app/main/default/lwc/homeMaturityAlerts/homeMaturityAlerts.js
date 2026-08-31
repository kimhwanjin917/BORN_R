import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getMaturityAlertTasks from '@salesforce/apex/HomeDashboardController.getMaturityAlertTasks';

export default class HomeMaturityAlerts extends NavigationMixin(LightningElement) {
    tasks;
    tasksError;
    showTaskList = false;

    @wire(getMaturityAlertTasks)
    wiredTasks({ data, error }) {
        if (data) {
            this.tasks = data;
            this.tasksError = undefined;
            // 2026-08-27 (docs/55 §12): 만기 알림이 있으면 펼친 상태로 시작
            if (data.length > 0) {
                this.showTaskList = true;
            }
        } else if (error) {
            this.tasksError = this.reduceError(error);
            this.tasks = undefined;
        }
    }

    get hasTasks() {
        return this.tasks && this.tasks.length > 0;
    }

    get taskCount() {
        return this.tasks ? this.tasks.length : 0;
    }

    toggleTaskList() {
        this.showTaskList = !this.showTaskList;
    }

    handleOpenTask(event) {
        // 2026-08-27 (docs/55 §12): 만기 알림 클릭 → 기회 레이더에서 해당 고객 선택 상태로 이동 (기존: Task 레코드)
        const whatId = event.currentTarget.dataset.whatId || event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Opportunity_Radar' },
            state: { c__whatId: whatId }
        });
    }

    reduceError(error) {
        return error?.body?.message || 'Unknown error';
    }
}
