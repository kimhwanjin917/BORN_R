import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const STAGES = ['탐색', '제안', '내부심사', '조건협상', '내부승인', '거래체결', 'Closed'];

export default class OpptyPipelineDashboard extends LightningElement {
    @api accountName = 'ABC테크';
    @api opportunityTitle = 'AI 상담 솔루션 도입';
    @api ownerName = '김영업';
    @api closeDate = '2026.09.30';
    @api amount = '₩120,000,000';
    @api probability = '70%';
    @api currentStage = '조건협상';

    selectedStage;

    get activeStage() {
        return this.selectedStage || this.currentStage || STAGES[0];
    }

    get activeStageIndex() {
        const index = STAGES.indexOf(this.activeStage);
        return index < 0 ? 0 : index;
    }

    get stageItems() {
        return STAGES.map((stage, index) => ({
            stage,
            isComplete: index < this.activeStageIndex,
            isCurrent: index === this.activeStageIndex,
            itemClass: `stage ${index < this.activeStageIndex ? 'complete' : index === this.activeStageIndex ? 'current' : 'future'}`,
            ariaCurrent: index === this.activeStageIndex ? 'step' : 'false'
        }));
    }

    get isClosed() {
        return this.activeStageIndex === STAGES.length - 1;
    }

    get nextStage() {
        return STAGES[Math.min(this.activeStageIndex + 1, STAGES.length - 1)];
    }

    get nextStageCopy() {
        const copyByStage = {
            제안: '상담 결과를 정리하고 맞춤 제안서를 공유합니다.',
            내부심사: '제안 내용을 내부 검토에 상정합니다.',
            조건협상: '가격 조건과 도입 범위를 함께 조율합니다.',
            내부승인: '최종 조건을 확정하고 내부 승인을 요청합니다.',
            거래체결: '계약서 초안을 전달하고 서명을 준비합니다.',
            Closed: '거래가 최종 완료되었습니다.'
        };
        return this.isClosed ? copyByStage.Closed : (copyByStage[this.nextStage] || '다음 영업 활동을 등록합니다.');
    }

    get completionLabel() {
        return this.isClosed ? '거래 완료' : '단계 완료';
    }

    handleStageClick(event) {
        this.changeStage(event.currentTarget.dataset.stage);
    }

    handleComplete() {
        if (!this.isClosed) {
            this.changeStage(this.nextStage);
        }
    }

    changeStage(stage) {
        if (!STAGES.includes(stage) || stage === this.activeStage) {
            return;
        }

        const previousStage = this.activeStage;
        this.selectedStage = stage;
        this.dispatchEvent(new CustomEvent('stagechange', {
            bubbles: true,
            composed: true,
            detail: { previousStage, stage }
        }));

        this.dispatchEvent(new ShowToastEvent({
            title: '영업 단계가 변경되었습니다.',
            message: `${previousStage} → ${stage}`,
            variant: 'success'
        }));
    }
}