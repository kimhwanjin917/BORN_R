import { LightningElement } from 'lwc';

const HOME_DASHBOARD_TAB_CHANGE_EVENT = 'home-dashboard-tab-change';

export default class HomeDashboardTabs extends LightningElement {
    activeTab = 'dashboard';

    connectedCallback() {
        window.addEventListener(HOME_DASHBOARD_TAB_CHANGE_EVENT, this.handleDashboardTabChange);
    }

    disconnectedCallback() {
        window.removeEventListener(HOME_DASHBOARD_TAB_CHANGE_EVENT, this.handleDashboardTabChange);
    }

    get isDashboard() {
        return this.activeTab === 'dashboard';
    }

    get isInsight() {
        return this.activeTab === 'insight';
    }

    handleDashboardTabChange = (event) => {
        this.activeTab = event.detail?.tab === 'insight' ? 'insight' : 'dashboard';
    }
}