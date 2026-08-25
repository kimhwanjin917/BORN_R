import { LightningElement, wire, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTopAccounts from '@salesforce/apex/AccountPriorityController.getTopAccounts';

export default class AccountPriorityList extends NavigationMixin(LightningElement) {
    @api maxRows = 10;

    accounts;
    error;

    @wire(getTopAccounts, { maxRows: '$maxRows' })
    wiredAccounts({ data, error }) {
        if (data) {
            this.accounts = data.map((acct, index) => ({
                ...acct,
                rank: index + 1,
                rankClass:
                    index === 0
                        ? 'rank-badge rank-badge_top'
                        : 'rank-badge'
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.accounts = undefined;
        }
    }

    get hasAccounts() {
        return this.accounts && this.accounts.length > 0;
    }

    get accountCount() {
        return this.accounts ? this.accounts.length : 0;
    }

    handleOpen(event) {
        const recordId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName: 'Account',
                actionName: 'view'
            }
        });
    }
}