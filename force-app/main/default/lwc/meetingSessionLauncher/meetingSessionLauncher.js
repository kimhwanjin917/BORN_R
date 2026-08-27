import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';

export default class MeetingSessionLauncher extends NavigationMixin(LightningElement) {
    @api recordId;
    navigated = false;
    showFallback = false;

    renderedCallback() {
        if (this.recordId && !this.navigated) this.openMeetingSession();
    }

    openMeetingSession() {
        if (!this.recordId) {
            this.showFallback = true;
            return;
        }
        this.navigated = true;
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: `/flow/Meeting_Session?recordId=${encodeURIComponent(this.recordId)}` }
        });
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}