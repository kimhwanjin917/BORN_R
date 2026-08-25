import { LightningElement, wire } from 'lwc';
import getOpenKpi from '@salesforce/apex/OpportunityKpiController.getOpenKpi';

const SEGMENT_COLORS = [
    'var(--slds-g-color-palette-blue-50, #0176d3)',
    'var(--slds-g-color-palette-teal-50, #0b827c)',
    'var(--slds-g-color-palette-indigo-50, #5867e8)',
    'var(--slds-g-color-palette-purple-50, #9050e9)',
    'var(--slds-g-color-palette-violet-50, #ba01ff)',
    'var(--slds-g-color-palette-cloud-blue-50, #107cad)'
];

export default class OpportunityKpiCard extends LightningElement {
    openCount = 0;
    stages;
    error;

    @wire(getOpenKpi)
    wiredKpi({ data, error }) {
        if (data) {
            this.openCount = data.openCount;
            const total = data.stages.reduce((sum, s) => sum + s.count, 0);
            this.stages = data.stages.map((stage, index) => {
                const percent = total > 0 ? Math.round((stage.count / total) * 100) : 0;
                const color = SEGMENT_COLORS[index % SEGMENT_COLORS.length];
                return {
                    stageName: stage.stageName,
                    count: stage.count,
                    percent,
                    color,
                    segmentStyle: `flex-grow:${stage.count}; background:${color};`,
                    dotStyle: `background:${color};`
                };
            });
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.stages = undefined;
        }
    }

    get hasStages() {
        return this.stages && this.stages.length > 0;
    }
}