@isTest
private class LeadKpiControllerTest {

    private static List<Lead> buildLeads(Integer count, String status, Integer startSeq) {
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < count; i++) {
            String seq = String.valueOf(startSeq + i).leftPad(6, '0');
            leads.add(new Lead(
                LastName = 'KPI Lead ' + status + ' ' + seq,
                Company = 'KPI Co ' + seq,
                Status = status,
                Email = 'kpi.lead.' + seq + '@example.com',
                Business_Registration_Number__c = 'B' + seq,
                name_new__c = 'KPI ' + seq
            ));
        }
        return leads;
    }

    @TestSetup
    static void setupTestData() {
        List<Lead> leads = new List<Lead>();
        // Not-converted (New) leads
        leads.addAll(buildLeads(3, '신규', 0));
        // In-progress (open, non-New) leads
        leads.addAll(buildLeads(2, '연결', 100));
        // Leads to convert into Won
        List<Lead> toConvert = buildLeads(4, '신규', 200);
        leads.addAll(toConvert);
        insert leads;

        String convertedStatus = [
            SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1
        ].MasterLabel;
        List<Database.LeadConvert> requests = new List<Database.LeadConvert>();
        for (Lead lead : toConvert) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(lead.Id);
            lc.setConvertedStatus(convertedStatus);
            requests.add(lc);
        }
        Database.convertLead(requests);
    }

    @isTest
    static void shouldReturnBucketCounts_WhenLeadsExist() {
        Test.startTest();
        LeadKpiController.LeadKpi kpi = LeadKpiController.getLeadKpi();
        Test.stopTest();

        Assert.areEqual(4, kpi.wonCount, 'Converted leads should be counted as Won');
        Assert.areEqual(2, kpi.inProgressCount, 'Open non-New leads should be In-progress');
        Assert.areEqual(3, kpi.notConvertedCount, 'Open New leads should be Not-converted');
        Assert.areEqual(9, kpi.totalCount, 'Total should equal the sum of all buckets');
    }

    @isTest
    static void shouldReturnThreeSegments_WhenCalled() {
        Test.startTest();
        LeadKpiController.LeadKpi kpi = LeadKpiController.getLeadKpi();
        Test.stopTest();

        Assert.areEqual(3, kpi.segments.size(), 'KPI must expose exactly three segments');
        Assert.areEqual('won', kpi.segments[0].key, 'First segment should be Won');
        Assert.areEqual('inProgress', kpi.segments[1].key, 'Second segment should be In-progress');
        Assert.areEqual('notConverted', kpi.segments[2].key, 'Third segment should be Not-converted');
    }
}