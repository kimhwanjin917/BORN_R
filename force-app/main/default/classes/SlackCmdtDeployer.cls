/**
 * Upserts a record into the existing Slack__mdt Custom Metadata Type using the
 * Apex Metadata API. The Slack__mdt type and its fields must already exist in
 * the org; this class only deploys a record, not the schema.
 *
 * Note: enqueueDeployment is asynchronous. The record is not queryable until the
 * enqueued deployment completes (handleResult fires in that async context).
 */
public class SlackCmdtDeployer implements Metadata.DeployCallback {

    public static void createRecord(
        String recordDevName,
        String label,
        String orgUuid,
        String orgName,
        String orgUrl,
        String orgDomain,
        String enterpriseId,
        String ownerEmail
    ) {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        // fullName = <TypeApiName>.<RecordDeveloperName> (no __mdt suffix on the type)
        cmd.fullName = 'Slack.' + recordDevName;
        cmd.label = label;

        cmd.values.add(buildValue('Org_UUID__c', orgUuid));
        cmd.values.add(buildValue('Org_Name__c', orgName));
        cmd.values.add(buildValue('Org_Url__c', orgUrl));
        cmd.values.add(buildValue('Org__c', orgDomain));
        cmd.values.add(buildValue('Enterprise_ID__c', enterpriseId));
        cmd.values.add(buildValue('Owner_Email__c', ownerEmail));

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmd);

        Metadata.Operations.enqueueDeployment(container, new SlackCmdtDeployer());
    }

    private static Metadata.CustomMetadataValue buildValue(String field, Object val) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = val;
        return v;
    }

    public void handleResult(
        Metadata.DeployResult result,
        Metadata.DeployCallbackContext context
    ) {
        if (result.status == Metadata.DeployStatus.Succeeded) {
            System.debug(LoggingLevel.INFO, '✅ Slack__mdt record deploy succeeded');
        } else {
            System.debug(LoggingLevel.ERROR, '❌ Slack__mdt record deploy failed: ' + result.errorMessage);
        }
    }
}