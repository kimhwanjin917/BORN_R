import { LightningElement, api, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getEmailContext from '@salesforce/apex/MeetingPrepEmailComposerController.getEmailContext';
import getEmailDraft from '@salesforce/apex/MeetingPrepEmailComposerController.getEmailDraft';
import getRecordName from '@salesforce/apex/MeetingPrepEmailComposerController.getRecordName';
import sendEmail from '@salesforce/apex/MeetingPrepEmailComposerController.sendEmail';

export default class MeetingPrepEmailComposer extends LightningElement {
    _recordId;
    isLoading = true;
    errorMessage;
    _started = false;

    @track fromOptions = [];
    @track fromAddress = '';
    @track subject = '';
    @track htmlBody = '';
    @track recipients = []; // [{ id, name }]
    @track relatedToId;
    hasDraft = false;
    bodyLoading = false;
    sending = false;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        // Quick Action 진입 시 recordId 가 늦게 채워지는 race condition 대응
        if (value && !this._started) {
            this._started = true;
            this.generate();
        }
    }

    async generate() {
        // 1단계: 빠른 컨텍스트로 창을 즉시 렌더 (LLM 대기 없이)
        try {
            const ctx = await getEmailContext({ leadId: this.recordId });
            this.fromOptions = (ctx.fromOptions || []).map((a) => ({ label: a, value: a }));
            this.fromAddress = ctx.fromAddress || '';
            this.relatedToId = ctx.relatedToId;
            if (ctx.relatedToId && ctx.leadName) {
                this.recipients = [{ id: ctx.relatedToId, name: ctx.leadName }];
            }
            this.hasDraft = true;
            this.isLoading = false;
        } catch (error) {
            this.isLoading = false;
            this.errorMessage =
                error?.body?.message || error?.message || '메일 창을 여는 중 오류가 발생했습니다.';
            return;
        }

        // 2단계: AI 초안(제목/본문)은 뒤이어 채움
        this.bodyLoading = true;
        try {
            const draft = await getEmailDraft({ leadId: this.recordId });
            this.subject = draft.subject || '';
            this.htmlBody = draft.htmlBody || '';
        } catch (error) {
            this.subject = this.subject || '';
            this.htmlBody =
                '<p>' +
                (error?.body?.message || error?.message || 'AI 초안 생성에 실패했습니다. 직접 작성해 주세요.') +
                '</p>';
        } finally {
            this.bodyLoading = false;
        }
    }

    get hasRecipients() {
        return this.recipients.length > 0;
    }

    get recipientItems() {
        return this.recipients.map((r) => ({
            label: r.name,
            name: r.id,
            iconName: 'standard:lead'
        }));
    }

    get leadObjectApiName() {
        return 'Lead';
    }

    handleFromChange(event) {
        this.fromAddress = event.detail.value;
    }

    handleSubjectChange(event) {
        this.subject = event.target.value;
    }

    handleBodyChange(event) {
        this.htmlBody = event.target.value;
    }

    async handleAddRecipient(event) {
        const recId = event.detail.recordId;
        const picker = this.template.querySelector('[data-id="to-picker"]');
        if (!recId) {
            return;
        }
        if (this.recipients.some((r) => r.id === recId)) {
            if (picker) picker.clearSelection();
            return;
        }
        try {
            const name = await getRecordName({ recordId: recId });
            this.recipients = [...this.recipients, { id: recId, name: name || recId }];
        } catch (e) {
            this.recipients = [...this.recipients, { id: recId, name: recId }];
        }
        if (picker) picker.clearSelection();
    }

    handleRemoveRecipient(event) {
        const index = event.detail.index;
        const next = [...this.recipients];
        next.splice(index, 1);
        this.recipients = next;
    }

    handleRelatedChange(event) {
        this.relatedToId = event.detail.recordId;
    }

    get isBodyEmpty() {
        return !this.htmlBody || this.htmlBody.replace(/<[^>]*>/g, '').trim() === '';
    }

    get sendDisabled() {
        return this.sending;
    }

    async handleSend() {
        if (!this.hasRecipients) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '받는 사람 필요',
                    message: '받는 사람을 최소 1명 이상 지정해 주세요.',
                    variant: 'error'
                })
            );
            return;
        }
        if (!this.subject || !this.subject.trim() || this.isBodyEmpty) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '내용 필요',
                    message: '제목과 본문을 입력해 주세요.',
                    variant: 'error'
                })
            );
            return;
        }
        if (!this.relatedToId) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Related To 필요',
                    message: 'Related To(Lead)를 지정해 주세요.',
                    variant: 'error'
                })
            );
            return;
        }

        this.sending = true;
        try {
            await sendEmail({
                subject: this.subject,
                htmlBody: this.htmlBody,
                relatedToId: this.relatedToId,
                recipientIds: this.recipients.map((r) => r.id)
            });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '발송 완료',
                    message: '메일이 발송되었습니다.',
                    variant: 'success'
                })
            );
            this.handleClose();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '발송 실패',
                    message: error?.body?.message || error?.message || '메일 발송 중 오류가 발생했습니다.',
                    variant: 'error'
                })
            );
        } finally {
            this.sending = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}