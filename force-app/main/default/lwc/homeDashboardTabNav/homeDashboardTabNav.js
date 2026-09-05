import { LightningElement } from 'lwc';

const HOME_DASHBOARD_TAB_CHANGE_EVENT = 'home-dashboard-tab-change';

export default class HomeDashboardTabNav extends LightningElement {
    activeTab = 'dashboard';

    connectedCallback() {
        this.publishActiveTab();
    }

    get isDashboard() {
        return this.activeTab === 'dashboard';
    }

    get isInsight() {
        return this.activeTab === 'insight';
    }

    get dashboardTabClass() {
        return `home-tab-nav__tab${this.isDashboard ? ' home-tab-nav__tab_active' : ''}`;
    }

    get insightTabClass() {
        return `home-tab-nav__tab${this.isInsight ? ' home-tab-nav__tab_active' : ''}`;
    }

    handleTabSelect(event) {
        this.activeTab = event.currentTarget.dataset.tab;
        this.publishActiveTab();
    }

    handleKeydown(event) {
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
            return;
        }

        event.preventDefault();
        this.activeTab = event.key === 'ArrowLeft' ? 'dashboard' : 'insight';
        this.publishActiveTab();
        this.template.querySelector(`[data-tab="${this.activeTab}"]`)?.focus();
    }

    publishActiveTab() {
        window.dispatchEvent(
            new CustomEvent(HOME_DASHBOARD_TAB_CHANGE_EVENT, {
                detail: { tab: this.activeTab }
            })
        );
    }
}