import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

/**
 * Flow 화면용 리치 텍스트 입력. 영업 이메일 본문처럼 서식/줄바꿈이 필요한 HTML 본문을 입력받는다.
 * value 는 HTML 문자열로 Flow 에 돌려준다.
 */
export default class SlackEmailRichTextInput extends LightningElement {
    @api label = '본문';
    @api value = '';
    @api required = false;
    @api placeholder = '';

    formats = ['font', 'size', 'bold', 'italic', 'underline', 'strike', 'list', 'indent', 'align', 'link', 'clean', 'color', 'background'];

    handleChange(event) {
        this.value = event.target.value;
        this.dispatchEvent(new FlowAttributeChangeEvent('value', this.value));
    }

    @api
    validate() {
        const plain = (this.value || '').replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').trim();
        if (this.required && !plain) {
            return { isValid: false, errorMessage: '본문을 입력해 주세요.' };
        }
        return { isValid: true };
    }
}