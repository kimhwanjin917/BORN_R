import { LightningElement, api } from 'lwc';

/** docs/60 별건(보니) — 사이드바 카드 윗선을 왼쪽 탭 줄 아래 카드와 맞추는 투명 스페이서. */
export default class HomeAlignSpacer extends LightningElement {
    @api height = 52;
    get style() {
        const px = Number(this.height) >= 0 ? Number(this.height) : 0;
        return `height:${px}px;`;
    }
}