import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getLeadKpi from '@salesforce/apex/LeadKpiController.getLeadKpi';

const SEGMENT_STYLES = {
    won: {
        color: '#1565FF',
        icon: 'utility:success',
        displayLabel: '진행 완료',
        objectApiName: 'Account'
    },
    inProgress: {
        color: '#00B7A6',
        icon: 'utility:clock',
        objectApiName: 'Opportunity'
    },
    notConverted: {
        color: '#6B7684',
        icon: 'utility:steps',
        objectApiName: 'Lead'
    }
};

export default class LeadKpiCard extends NavigationMixin(LightningElement) {
    totalCount = 0;
    segments;
    error;

    @wire(getLeadKpi)
    wiredKpi({ data, error }) {
        if (data) {
            this.totalCount = data.totalCount;
            const total = data.totalCount || 0;
            this.segments = data.segments.map((segment) => {
                const style = SEGMENT_STYLES[segment.key] || {};
                const percent = total > 0 ? Math.round((segment.count / total) * 100) : 0;
                return {
                    key: segment.key,
                    label: style.displayLabel || segment.label,
                    count: segment.count,
                    percent,
                    icon: style.icon,
                    objectApiName: style.objectApiName,
                    iconStyle: `background:${style.color};`,
                    fillStyle: `width:${percent}%; background:${style.color};`,
                    percentStyle: `color:${style.color};`
                };
            });
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.segments = undefined;
        }
    }

    get hasData() {
        return this.totalCount > 0 && this.segments && this.segments.length > 0;
    }

    handleSegmentClick(event) {
        const objectApiName = event.currentTarget.dataset.object;
        if (!objectApiName) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName,
                actionName: 'list'
            },
            state: {
                filterName: 'Recent'
            }
        });
    }

    handleSegmentKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleSegmentClick(event);
        }
    }
}