import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getPipeline from '@salesforce/apex/OpportunityKpiController.getPipeline';

// Open stages darken as the deal advances, so the shape of the pipeline is
// readable at a glance even before the numbers are.
const OPEN_SHADES = ['#8fb2fb', '#6f9bf9', '#4b7bf5', '#3b6cf6', '#2f57e0', '#2948d6'];
const WON_COLOR = '#159f5c';
const ALERT_COLOR = '#0b2a6b';

const CHIP_ICONS = {
    stalled: 'utility:warning',
    closing: 'utility:clock',
    inactive: 'utility:ban'
};

export default class OpportunityKpiCard extends NavigationMixin(LightningElement) {
    /** Stage the "접촉 끊김" chip watches. */
    @api stalledStage;
    /** Days without contact before a deal in that stage is called stalled. */
    @api stalledDays;
    /** Days without contact before any open deal counts as 미활동. */
    @api inactiveDays;
    /** Window, in days, for the "마감 임박" chip. */
    @api closingDays;

    pipeline;
    error;

    @wire(getPipeline, {
        stalledStage: '$stalledStage',
        stalledDays: '$stalledDays',
        inactiveDays: '$inactiveDays',
        closingDays: '$closingDays'
    })
    wiredPipeline({ data, error }) {
        if (data) {
            this.pipeline = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Unknown error';
            this.pipeline = undefined;
        }
    }

    get totalDisplay() {
        return `${this.pipeline.totalCount}건`;
    }

    get feeDisplay() {
        return formatKrw(this.pipeline.openFeeRevenue);
    }

    get actionDisplay() {
        return `${this.pipeline.weekActionCount}건`;
    }

    get stages() {
        const stages = this.pipeline.stages;
        const alerted = new Set(
            this.pipeline.alerts.map((alert) => alert.stageName).filter(Boolean)
        );

        // Bars are scaled against the busiest stage rather than the total, so a
        // pipeline that is thin everywhere still shows its relative shape.
        const busiest = stages.reduce((max, stage) => Math.max(max, stage.count), 0);
        let openIndex = -1;

        return stages.map((stage) => {
            if (!stage.isWon) {
                openIndex += 1;
            }
            const isAlerted = alerted.has(stage.stageName);
            const color = isAlerted
                ? ALERT_COLOR
                : stage.isWon
                  ? WON_COLOR
                  : OPEN_SHADES[Math.min(openIndex, OPEN_SHADES.length - 1)];

            return {
                stageName: stage.stageName,
                count: stage.count,
                feeDisplay: formatKrw(stage.feeRevenue),
                // 미팅 단계는 수수료 금액 대상이 아니므로 하단 금액을 표시하지 않는다.
                showFee: stage.stageName?.trim() !== '미팅',
                cardClass: isAlerted ? 'pk-col pk-col_alerted' : 'pk-col',
                railStyle: `background:${color};`,
                // Zero-count stages keep a hairline so the column still reads as a bar.
                barStyle: `height:${busiest > 0 ? Math.max((stage.count / busiest) * 100, 2) : 2}%; background:${color};`,
                barTitle: `${stage.stageName} ${stage.count}건`
            };
        });
    }

    get hasAlerts() {
        return this.pipeline.alerts.length > 0;
    }

    get alerts() {
        return this.pipeline.alerts.map((alert) => ({
            key: alert.key,
            text: alert.label.replace('{0}', alert.count),
            iconName: CHIP_ICONS[alert.key] || 'utility:info',
            chipClass: `pk-chips__item pk-chips__item_${alert.key}`
        }));
    }

    // The list view is the whole object, not a filtered drill-down: the button
    // is a way in, matching how the KPI tiles behave elsewhere on the home page.
    handleViewAll() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Opportunity', actionName: 'list' },
            state: { filterName: 'Recent' }
        });
    }
}

// Korean money reads in 억/만 units, not thousands separators. Mirrors myKpiCard.
function formatKrw(value) {
    if (!value) {
        return '0원';
    }
    if (value >= 100000000) {
        return `${trim(value / 100000000)}억원`;
    }
    if (value >= 10000) {
        return `${trim(value / 10000)}만원`;
    }
    return `${Math.round(value).toLocaleString('ko-KR')}원`;
}

function trim(value) {
    return Number(value.toFixed(1)).toLocaleString('ko-KR');
}