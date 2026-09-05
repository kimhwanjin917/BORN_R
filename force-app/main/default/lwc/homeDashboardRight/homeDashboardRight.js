import { LightningElement, api } from 'lwc';

const HOME_DASHBOARD_TAB_CHANGE_EVENT = 'home-dashboard-tab-change';

export default class HomeDashboardRight extends LightningElement {
    @api flowApiName;
    @api maxRows = 3;

    activeTab = 'dashboard';

    connectedCallback() {
        window.addEventListener(HOME_DASHBOARD_TAB_CHANGE_EVENT, this.handleDashboardTabChange);
    }

    disconnectedCallback() {
        window.removeEventListener(HOME_DASHBOARD_TAB_CHANGE_EVENT, this.handleDashboardTabChange);
    }

    handleDashboardTabChange = (event) => {
        this.activeTab = event.detail?.tab === 'insight' ? 'insight' : 'dashboard';
    };

    get isDashboard() {
        return this.activeTab === 'dashboard';
    }
}