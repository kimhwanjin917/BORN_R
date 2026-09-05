import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTodayEvents from '@salesforce/apex/HomeDashboardController.getTodayEvents';

export default class HomeTodaySchedule extends NavigationMixin(LightningElement) {
    // Meeting Screen Flow API name, injected via App Builder property.
    @api flowApiName;

    events;
    eventsError;
    showEvents = false;

    // Flow modal state
    showFlowModal = false;
    flowInputVariables = [];

    @wire(getTodayEvents)
    wiredEvents({ data, error }) {
        if (data) {
            this.events = data.map((evt) => {
                const opportunityId =
                    evt.WhatId && evt.WhatId.startsWith('006') ? evt.WhatId : null;
                const relatedName = evt.What?.Name || evt.Who?.Name || '';
                return {
                    ...evt,
                    opportunityId,
                    relatedName,
                    startDisabled: !this.flowApiName || !opportunityId
                };
            });
            this.eventsError = undefined;
            // 만기 알림과 동일: 오늘 일정이 있으면 펼친 상태로 시작
            if (this.events.length > 0) {
                this.showEvents = true;
            }
        } else if (error) {
            this.eventsError = this.reduceError(error);
            this.events = undefined;
        }
    }

    get hasEvents() {
        return this.events && this.events.length > 0;
    }

    toggleEvents() {
        this.showEvents = !this.showEvents;
    }

    // ─── Handlers ────────────────────────────────────────────────────
    handleStartMeeting(event) {
        const opportunityId = event.currentTarget.dataset.whatId;
        if (!opportunityId || !this.flowApiName) {
            return;
        }

        const flowUrl =
            `/flow/${this.flowApiName}?recordId=${encodeURIComponent(opportunityId)}&retURL=/lightning/page/home`;

        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: flowUrl }
        });
    }

    handleFlowStatusChange(event) {
        if (event.detail.status === 'FINISHED' || event.detail.status === 'FINISHED_SCREEN') {
            this.closeFlowModal();
        }
    }

    closeFlowModal() {
        this.showFlowModal = false;
        this.flowInputVariables = [];
    }

    reduceError(error) {
        return error?.body?.message || 'Unknown error';
    }
}