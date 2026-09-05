import { LightningElement, api } from 'lwc';
import { FlowNavigationFinishEvent } from 'lightning/flowSupport';
import BONI from '@salesforce/resourceUrl/BoniImages';

/**
 * docs/60 별건 — 완료 화면용 보니(깃발 포즈) 배너. Flow 화면·레코드 페이지 공용.
 * modal=true 면 팝업으로 뜨고, [확인] 은 Flow 를 Finish 한다.
 * Flow 실행 화면(/flow/...)은 LEX 안의 iframe 이라 LWC 가 직접 페이지 이동을 못 한다.
 * 이동은 Flow 를 여는 쪽이 retURL(영업기회 등)로 지정하고, Finish 시 런타임이 그리로 보낸다.
 */
export default class BoniDoneBanner extends LightningElement {
    @api title = '완료되었습니다.';
    @api subtitle;
    @api pose = 'flag'; // flag | main | chart | tablet
    @api size = 96;     // px
    @api modal = false;
    @api position = 'center';
    @api buttonLabel = '확인';
    @api availableActions = [];
    // 미사용 — Flow v13~15 참조 유지용. 구버전 삭제 후 제거 가능
    @api navigateToRecordId;
    @api recordId;

    get imageUrl() {
        return `${BONI}/${this.pose}.png`;
    }
    get imageStyle() {
        const px = Number(this.size) > 0 ? Number(this.size) : 96;
        return `width:${px}px;height:${px}px;flex:0 0 ${px}px;`;
    }
    get modalClass() {
    const base = 'slds-modal slds-fade-in-open slds-modal_small';
    return this.position === 'top' ? `${base} modal-align-top` : base;
    }   

    handleConfirm() {
        this.dispatchEvent(new FlowNavigationFinishEvent());
    }
}