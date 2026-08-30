import { LightningElement, wire, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTopLeads from '@salesforce/apex/LeadPriorityController.getTopLeads';
import getTopAccounts from '@salesforce/apex/AccountPriorityController.getTopAccounts';

const HOME_DASHBOARD_TAB_CHANGE_EVENT = 'home-dashboard-tab-change';

export default class PriorityList extends NavigationMixin(LightningElement) {
    @api maxRows = 10;
    @api initialTab = 'dashboard';

    activeTab = 'dashboard';
    leads;
    leadError;
    accounts;
    accountError;

    connectedCallback() {
        this.activeTab = this.initialTab === 'insight' ? 'insight' : 'dashboard';
        window.addEventListener(HOME_DASHBOARD_TAB_CHANGE_EVENT, this.handleDashboardTabChange);
    }

    disconnectedCallback() {
        window.removeEventListener(HOME_DASHBOARD_TAB_CHANGE_EVENT, this.handleDashboardTabChange);
    }

    handleDashboardTabChange = (event) => {
        this.activeTab = event.detail?.tab === 'insight' ? 'insight' : 'dashboard';
    };

    get isInsightTab() {
        return this.activeTab === 'insight';
    }

    @wire(getTopLeads, { maxRows: '$maxRows' })
    wiredLeads({ data, error }) {
        if (data) {
            this.leads = data.map((lead, index) => ({
                Id: lead.Id,
                name: lead.Company,
                score: lead.Priority_Score__c,
                reason: lead.Priority_Rationale_Summary__c,
                rank: index + 1,
                rankClass:
                    index === 0 ? 'rank-badge rank-badge_top' : 'rank-badge'
            }));
            this.leadError = undefined;
        } else if (error) {
            this.leadError = error?.body?.message || 'Unknown error';
            this.leads = undefined;
        }
    }

    @wire(getTopAccounts, { maxRows: '$maxRows' })
    wiredAccounts({ data, error }) {
        if (data) {
            this.accounts = data.map((acct, index) => ({
                Id: acct.Id,
                name: acct.Name,
                score: acct.Priority_Score__c,
                reason: acct.Priority_Rationale_Summary__c,
                rank: index + 1,
                rankClass:
                    index === 0 ? 'rank-badge rank-badge_top' : 'rank-badge'
            }));
            this.accountError = undefined;
        } else if (error) {
            this.accountError = error?.body?.message || 'Unknown error';
            this.accounts = undefined;
        }
    }

    get hasLeads() {
        return this.leads && this.leads.length > 0;
    }

    get leadCount() {
        return this.leads ? this.leads.length : 0;
    }

    get hasAccounts() {
        return this.accounts && this.accounts.length > 0;
    }

    get accountCount() {
        return this.accounts ? this.accounts.length : 0;
    }

    handleOpenLead(event) {
        this.navigate(event.currentTarget.dataset.id, 'Lead');
    }

    handleOpenAccount(event) {
        this.navigate(event.currentTarget.dataset.id, 'Account');
    }

    navigate(recordId, objectApiName) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName,
                actionName: 'view'
            }
        });
    }
}