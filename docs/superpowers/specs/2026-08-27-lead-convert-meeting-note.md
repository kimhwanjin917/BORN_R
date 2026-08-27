# Lead Convert → Meeting Note (declarative)

**Date:** 2026-08-27
**Status:** Implemented

## Problem

When a Lead is converted, the team wants a 미팅 기록 (Meeting Note) captured at the
same time, with the meeting date flowing onto related records. The standard
"Convert 리드" modal (`runtime_sales_lead:leadConvert`) cannot be extended — no
metadata hook adds a section or field to it.

## Approach (chosen over a custom convert LWC)

Capture the meeting fields **on the Lead record** before conversion, then let a
record-triggered Flow do the rest when the Lead flips to converted. The standard
Convert modal is untouched.

## What was built

### 3 new Lead fields (shown in a "미팅 기록" section on `Lead-Lead Layout`)

| Field | Type | Maps to |
|---|---|---|
| `Lead.Meeting_Date__c` | Date | `Meeting_Note__c.Meeting_Date__c`, `Opportunity.CloseDate`, `Task.ActivityDate` |
| `Lead.Meeting_Content__c` | LongTextArea(32768) | `Meeting_Note__c.Raw_Content__c` (trigger masks → `Sanitized_Content__c`) |
| `Lead.Meeting_Attendees__c` | Text(255) | `Meeting_Note__c.Attendees__c` |

FLS: `Admin.profile` and `DART_OpenAPI_Access` (mirrors `Lead.Department__c`). The
org's RM-facing profile/permission set is not tracked in this repo and must also
grant edit on these three — same manual follow-up as the `Meeting_Note__c` fields.

### `Meeting_Note__c` fields (added earlier, commit 51159bb)

`Meeting_Date__c` (Date), `Attendees__c` (Text 255). Content reuses the existing
`Raw_Content__c`. Both new fields are on the Meeting Note layout.

### Flow `Lead_Convert_Create_Meeting_Note`

Record-triggered, `Lead`, **after save**, `recordTriggerType: Update`, entry
`IsConverted = true` with `doesRequireRecordChangedToMeetCriteria` (fires once, on
the transition into converted).

1. **Decision** — proceed only if `Meeting_Content__c` is not blank AND
   `ConvertedOpportunityId` is not null (opportunity creation was not skipped).
   Otherwise the flow does nothing.
2. **Create** `Meeting_Note__c`: `Opportunity__c` = `ConvertedOpportunityId`,
   `Raw_Content__c` = `Meeting_Content__c`, `Meeting_Date__c`, `Attendees__c`.
   `MeetingNoteTriggerHandler` masks it on insert.
3. **Decision** — if `Meeting_Date__c` is set: **Update** the converted
   `Opportunity.CloseDate` to it.
4. **Create** `Task`: `Subject` = `미팅 후속 조치`, `WhatId` =
   `ConvertedOpportunityId`, `OwnerId` = Lead `OwnerId`, `ActivityDate` =
   `Meeting_Date__c`.

## Not done / notes

- **No Apex.** `LeadConvertService` is untouched. The Lead-convert cluster was
  synced from the org (commit 126a8c3) while a custom-LWC approach was being
  considered; that sync is kept because it makes the repo accurate, but this
  declarative approach does not depend on it.
- The org's `LeadConvertService` rewrite (이상윤, 2026-08-27) dropped
  `transferDepartmentToContacts` — `Lead.Department__c` → `Contact.Department` at
  conversion is no longer wired. Flagged for the team; unrelated to this change.
- Meeting fields live on the Lead record page, not inside the convert modal.
  Accepted trade-off for a ~5-file declarative build instead of rebuilding the
  standard convert UI.
- No automated test (declarative only). Manual check: fill the three Lead fields,
  click the standard **Convert**, confirm on the new Opportunity: a masked Meeting
  Note, `CloseDate` = the meeting date, and an open "미팅 후속 조치" Task due that
  date.
