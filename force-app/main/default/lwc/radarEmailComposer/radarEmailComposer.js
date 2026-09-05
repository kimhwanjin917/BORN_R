import { LightningElement, api, track, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getOpportunityRadarEmailDraft from '@salesforce/apex/MeetingPrepEmailComposerController.getOpportunityRadarEmailDraft';
import getRecordName from '@salesforce/apex/MeetingPrepEmailComposerController.getRecordName';
import getDefaultAttachments from '@salesforce/apex/MeetingPrepEmailComposerController.getDefaultAttachments';
import getFileInfo from '@salesforce/apex/MeetingPrepEmailComposerController.getFileInfo';
import sendEmail from '@salesforce/apex/MeetingPrepEmailComposerController.sendEmail';

export default class RadarEmailComposer extends LightningElement {
    _recordId;
    _recommendationId;
    isLoading = true;
    errorMessage;
    _started = false;

    @api embedded = false;

    @track fromOptions = [];
    @track fromAddress = '';
    @track subject = '';
    @track htmlBody = '';
    @track recipients = [];
    @track attachments = [];
    @track relatedToId;
    hasDraft = false;
    bodyLoading = false;
    sending = false;

    @wire(CurrentPageReference)
    handlePageReference(pageRef) {
        const recommendationId = pageRef?.state?.c__recommendationId;
        if (recommendationId && recommendationId !== this.recommendationId) {
            this.recommendationId = recommendationId;
            this.maybeGenerate();
        }
    }

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.maybeGenerate();
    }

    @api
    get recommendationId() {
        return this._recommendationId;
    }
    set recommendationId(value) {
        this._recommendationId = value;
        this.maybeGenerate();
    }

    maybeGenerate() {
        if (this._recordId && this._recommendationId && !this._started) {
            this._started = true;
            this.hasDraft = true;
            this.bodyLoading = true;
            this.generate();
        }
    }

    async generate() {
        try {
            const draft = await getOpportunityRadarEmailDraft({
                accountId: this.recordId,
                recommendationId: this._recommendationId
            });
            this.fromOptions = (draft.fromOptions || []).map((address) => ({ label: address, value: address }));
            this.fromAddress = draft.fromAddress || '';
            this.relatedToId = draft.relatedToId;
            if (draft.recipientId) {
                this.recipients = [{ id: draft.recipientId, name: draft.recipientName || draft.recipientId }];
            }
            this.subject = draft.subject || '';
            this.htmlBody = draft.htmlBody || '';
            this.hasDraft = true;
            try {
                const defaults = await getDefaultAttachments();
                this.attachments = (defaults || []).map((file) => ({ id: file.contentDocumentId, name: file.fileName }));
            } catch (attachmentError) {
                this.attachments = [];
            }
        } catch (error) {
            this.hasDraft = false;
            this.errorMessage = error?.body?.message || error?.message || '메일 창을 여는 중 오류가 발생했습니다.';
        } finally {
            this.isLoading = false;
            this.bodyLoading = !this.htmlBody;
        }
    }

    get hasRecipients() {
        return this.recipients.length > 0;
    }

    get accountObjectApiName() {
        return 'Account';
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
        const recipientId = event.detail.recordId;
        const picker = this.template.querySelector('[data-id="to-picker"]');
        if (!recipientId) return;
        if (this.recipients.some((recipient) => recipient.id === recipientId)) {
            if (picker) picker.clearSelection();
            return;
        }
        try {
            const name = await getRecordName({ recordId: recipientId });
            this.recipients = [...this.recipients, { id: recipientId, name: name || recipientId }];
        } catch (error) {
            this.recipients = [...this.recipients, { id: recipientId, name: recipientId }];
        }
        if (picker) picker.clearSelection();
    }

    handleRemoveRecipient(event) {
        const next = [...this.recipients];
        const index = event.currentTarget?.dataset?.index ?? event.detail?.index;
        if (index == null) return;
        next.splice(Number(index), 1);
        this.recipients = next;
    }

    handleRelatedChange(event) {
        this.relatedToId = event.detail.recordId;
    }

    get hasAttachments() {
        return this.attachments.length > 0;
    }

    async handleAddAttachment(event) {
        const documentId = event.detail.recordId;
        const picker = this.template.querySelector('[data-id="file-picker"]');
        if (!documentId) return;
        if (this.attachments.some((attachment) => attachment.id === documentId)) {
            if (picker) picker.clearSelection();
            return;
        }
        try {
            const info = await getFileInfo({ contentDocumentIds: [documentId] });
            const name = info && info.length ? info[0].fileName : documentId;
            this.attachments = [...this.attachments, { id: documentId, name }];
        } catch (error) {
            this.attachments = [...this.attachments, { id: documentId, name: documentId }];
        }
        if (picker) picker.clearSelection();
    }

    handleRemoveAttachment(event) {
        const documentId = event.currentTarget?.dataset?.id;
        if (!documentId) return;
        this.attachments = this.attachments.filter((attachment) => attachment.id !== documentId);
    }

    get isBodyEmpty() {
        return !this.htmlBody || this.htmlBody.replace(/<[^>]*>/g, '').trim() === '';
    }

    get sendDisabled() {
        return this.sending;
    }

    async handleSend() {
        if (!this.hasRecipients) {
            this.showError('받는 사람 필요', '받는 사람을 최소 1명 이상 지정해 주세요.');
            return;
        }
        if (!this.subject.trim() || this.isBodyEmpty) {
            this.showError('내용 필요', '제목과 본문을 입력해 주세요.');
            return;
        }
        if (!this.relatedToId) {
            this.showError('Related To 필요', 'Related To(고객사)를 지정해 주세요.');
            return;
        }

        this.sending = true;
        try {
            await sendEmail({
                subject: this.subject,
                htmlBody: this.htmlBody,
                relatedToId: this.relatedToId,
                recipientIds: this.recipients.map((recipient) => recipient.id),
                contentDocumentIds: this.attachments.map((attachment) => attachment.id)
            });
            this.dispatchEvent(new ShowToastEvent({ title: '발송 완료', message: '메일이 발송되었습니다.', variant: 'success' }));
            this.handleClose();
        } catch (error) {
            this.showError('발송 실패', error?.body?.message || error?.message || '메일 발송 중 오류가 발생했습니다.');
        } finally {
            this.sending = false;
        }
    }

    showError(title, message) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant: 'error' }));
    }

    handleClose() {
        if (this.embedded) {
            this.dispatchEvent(new CustomEvent('close', { bubbles: true, composed: true }));
            return;
        }
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}