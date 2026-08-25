import { LightningElement, wire, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTopLeads from '@salesforce/apex/LeadPriorityController.getTopLeads';

export default class LeadPriorityList extends NavigationMixin(LightningElement) {
    @api maxRows = 10;

    leads;
    error;

    @wire(getTopLeads, { maxRows: '$maxRows' })
    wiredLeads({ data, error }) {
        if (data) {
            this.leads = data.map((lead, index) => ({
                ...lead,
                rank: index + 1,
                rankClass:
                    index === 0
                        ? 'rank-badge rank-badge_top'
                        : 'rank-badge'
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.leads = undefined;
        }
    }

    get hasLeads() {
        return this.leads && this.leads.length > 0;
    }

    get leadCount() {
        return this.leads ? this.leads.length : 0;
    }

    handleOpen(event) {
        const recordId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName: 'Lead',
                actionName: 'view'
            }
        });
    }
}