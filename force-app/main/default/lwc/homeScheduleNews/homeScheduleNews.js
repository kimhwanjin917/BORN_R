import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTodayEvents from '@salesforce/apex/HomeDashboardController.getTodayEvents';
import getMaturityAlertTasks from '@salesforce/apex/HomeDashboardController.getMaturityAlertTasks';
import getDailySummary from '@salesforce/apex/HomeDashboardController.getDailySummary';
import getPriorityNews from '@salesforce/apex/HomeDashboardController.getPriorityNews';

export default class HomeScheduleNews extends NavigationMixin(LightningElement) {
    // Meeting Screen Flow API name, injected via App Builder property.
    @api flowApiName;

    events;
    eventsError;

    tasks;
    tasksError;
    showTaskList = false;

    summary;
    news;
    newsError;

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
        } else if (error) {
            this.eventsError = this.reduceError(error);
            this.events = undefined;
        }
    }

    @wire(getMaturityAlertTasks)
    wiredTasks({ data, error }) {
        if (data) {
            this.tasks = data;
            this.tasksError = undefined;
        } else if (error) {
            this.tasksError = this.reduceError(error);
            this.tasks = undefined;
        }
    }

    @wire(getDailySummary)
    wiredSummary({ data, error }) {
        if (data !== undefined) {
            this.summary = data;
        } else if (error) {
            this.summary = undefined;
        }
    }

    @wire(getPriorityNews)
    wiredNews({ data, error }) {
        if (data) {
            this.news = data.map((signal) => ({
                ...signal,
                partyName: signal.Account__r
                    ? signal.Account__r.Name
                    : signal.Lead__r
                    ? signal.Lead__r.Company
                    : signal.Industry__c
            }));
            this.newsError = undefined;
        } else if (error) {
            this.newsError = this.reduceError(error);
            this.news = undefined;
        }
    }

    // ─── Derived getters ─────────────────────────────────────────────
    get hasEvents() {
        return this.events && this.events.length > 0;
    }

    get hasTasks() {
        return this.tasks && this.tasks.length > 0;
    }

    get taskCount() {
        return this.tasks ? this.tasks.length : 0;
    }

    get hasNews() {
        return this.news && this.news.length > 0;
    }

    get hasSummary() {
        return !!this.summary;
    }

    get flowNotConfigured() {
        return !this.flowApiName;
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

    toggleTaskList() {
        this.showTaskList = !this.showTaskList;
    }

    handleOpenTask(event) {
        this.navigateToRecord(event.currentTarget.dataset.id, 'Task');
    }

    navigateToRecord(recordId, objectApiName) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName, actionName: 'view' }
        });
    }

    reduceError(error) {
        return error?.body?.message || 'Unknown error';
    }
}