/**
 * @AuraEnabled entry point for the walletOpportunityRadar LWC.
 * getRadar assembles KPIs + per-account rows + today's recommendations (regenerating them when
 * missing or stale); createOpportunity turns one recommendation into an Opportunity.
 */
public with sharing class OpportunityRadarController {
    private static final String NEW_OPP_STAGE = '미팅';
    private static final Integer NEW_OPP_CLOSE_DAYS = 90;
    private static final Integer DEFAULT_RP_TENOR_DAYS = 91;

    public class RecommendationDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public Integer rank;
        @AuraEnabled public String type;
        @AuraEnabled public String productName;
        @AuraEnabled public String family;
        @AuraEnabled public Decimal score;
        @AuraEnabled public Decimal expectedAmount;
        @AuraEnabled public String reason;
        @AuraEnabled public String scoreDetail;    // JSON of RadarScoreService.Score
        @AuraEnabled public String status;
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Date closedOn;        // outcome date (수주/실패), display only
    }

    public class AccountRow {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String segment;
        @AuraEnabled public String industry;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String statementPeriod;
        @AuraEnabled public Integer lastContactDays; // null = no meeting note / event on record
        @AuraEnabled public Decimal share;          // 0..1
        @AuraEnabled public Decimal wallet;
        @AuraEnabled public Decimal ourBalance;
        @AuraEnabled public Decimal whitespace;
        @AuraEnabled public Decimal propensity;     // top recommendation score
        @AuraEnabled public String topType;
        @AuraEnabled public String topProduct;
        @AuraEnabled public Decimal priority;       // whitespace × propensity
        @AuraEnabled public List<RecommendationDTO> recommendations = new List<RecommendationDTO>();
        @AuraEnabled public List<RecommendationDTO> outcomes = new List<RecommendationDTO>();   // closed within Recent_Outcome_Days
        @AuraEnabled public List<WalletShareService.FamilyWallet> families = new List<WalletShareService.FamilyWallet>();
    }

    public class RadarDTO {
        @AuraEnabled public Decimal totalWhitespace = 0;
        @AuraEnabled public Decimal averageShare = 0;
        @AuraEnabled public Integer priorityCount = 0;
        @AuraEnabled public Decimal expectedTotal = 0;
        @AuraEnabled public Integer accountCount = 0;
        @AuraEnabled public Boolean canViewAll = false;   // custom permission Opportunity_Radar_View_All
        @AuraEnabled public String scope;                 // mine | all (effective)
        @AuraEnabled public Datetime generatedAt;
        @AuraEnabled public List<AccountRow> accounts = new List<AccountRow>();
    }

    /**
     * @param accountId when set, only that account is returned (record-page mode)
     * @param forceRefresh regenerate recommendations even if today's exist
     * @param scope 'mine' = accounts owned by the running user, 'all' = every account (requires Opportunity_Radar_View_All)
     * @return radar payload
     */
    @AuraEnabled
    public static RadarDTO getRadar(Id accountId, Boolean forceRefresh, String scope) {
        try {
            Boolean canViewAll = FeatureManagement.checkPermission('Opportunity_Radar_View_All');
            String effectiveScope = (canViewAll && scope != 'mine') ? 'all' : 'mine';
            Set<Id> accountIds = resolveAccountIds(accountId, effectiveScope);
            if (accountIds.isEmpty()) {
                RadarDTO empty = new RadarDTO();
                empty.canViewAll = canViewAll;
                empty.scope = effectiveScope;
                return empty;
            }
            RecommendationOutcomeService.syncOutcomes(accountIds);
            Map<Id, List<Recommendation__c>> recsByAccount = loadTodayRecommendations(accountIds);
            Set<Id> needsRegeneration = new Set<Id>();
            for (Id id : accountIds) {
                if (forceRefresh == true || !hasTodayProposal(recsByAccount.get(id))) {
                    needsRegeneration.add(id);
                }
            }
            if (!needsRegeneration.isEmpty()) {
                RadarRecommendationService.regenerate(needsRegeneration);
                recsByAccount = loadTodayRecommendations(accountIds);
            }
            RadarDTO dto = assemble(accountIds, recsByAccount);
            dto.canViewAll = canViewAll;
            dto.scope = effectiveScope;
            return dto;
        } catch (Exception e) {
            throw new AuraHandledException('기회 레이더를 불러오지 못했습니다: ' + e.getMessage());
        }
    }

    /**
     * Creates an Opportunity from a recommendation and links it (Status → 기회생성).
     * @param recommendationId Recommendation__c to convert
     * @return new Opportunity Id
     */
    @AuraEnabled
    public static Id createOpportunity(Id recommendationId) {
        if (recommendationId == null) {
            throw new AuraHandledException('추천을 선택해 주세요.');
        }
        try {
            Recommendation__c recommendation = [
                SELECT Id, Account__c, Account__r.Name, Product__c, Product__r.Name, Product__r.Family, Type__c, Expected_Amount__c, Status__c
                FROM Recommendation__c WHERE Id = :recommendationId WITH USER_MODE LIMIT 1
            ];
            if (recommendation.Status__c != RadarRecommendationService.STATUS_PROPOSED) {
                throw new RadarException('이미 처리된 추천입니다.');
            }
            Date closeDate = Date.today().addDays(NEW_OPP_CLOSE_DAYS);
            Opportunity opportunity = new Opportunity(
                Name = recommendation.Account__r.Name + ' - ' + recommendation.Product__r.Name + ' (' + recommendation.Type__c + ')',
                AccountId = recommendation.Account__c,
                StageName = NEW_OPP_STAGE,
                CloseDate = closeDate,
                Amount = recommendation.Expected_Amount__c,
                Primary_Product__c = recommendation.Product__c
            );
            String family = recommendation.Product__r.Family;
            if (family == WalletShareService.FAMILY_RP || family == WalletShareService.FAMILY_CASH_MGMT) {
                opportunity.RP_Maturity_Date__c = closeDate.addDays(DEFAULT_RP_TENOR_DAYS);
            }
            Database.insert(opportunity, true, AccessLevel.USER_MODE);
            Database.update(new Recommendation__c(
                Id = recommendation.Id,
                Status__c = RecommendationOutcomeService.STATUS_CREATED,
                Opportunity__c = opportunity.Id
            ), true, AccessLevel.USER_MODE);
            return opportunity.Id;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('기회 생성 실패: ' + e.getMessage());
        }
    }

    /**
     * Resolves a deep-link record (Account, Opportunity, Asset or Task) to its Account Id.
     * @param recordId any of 001 / 006 / 02i / 00T
     * @return Account Id, or null when it cannot be resolved
     */
    @AuraEnabled(cacheable=true)
    public static Id resolveAccountId(Id recordId) {
        if (recordId == null) {
            return null;
        }
        try {
            Schema.SObjectType type = recordId.getSobjectType();
            if (type == Account.SObjectType) {
                return recordId;
            }
            if (type == Opportunity.SObjectType) {
                for (Opportunity o : [SELECT AccountId FROM Opportunity WHERE Id = :recordId WITH USER_MODE LIMIT 1]) {
                    return o.AccountId;
                }
            } else if (type == Asset.SObjectType) {
                for (Asset a : [SELECT AccountId FROM Asset WHERE Id = :recordId WITH USER_MODE LIMIT 1]) {
                    return a.AccountId;
                }
            } else if (type == Task.SObjectType) {
                for (Task t : [SELECT WhatId, AccountId FROM Task WHERE Id = :recordId WITH USER_MODE LIMIT 1]) {
                    if (t.AccountId != null) {
                        return t.AccountId;
                    }
                    return t.WhatId == null ? null : resolveAccountId(t.WhatId);
                }
            }
            return null;
        } catch (Exception e) {
            throw new AuraHandledException('고객을 찾지 못했습니다: ' + e.getMessage());
        }
    }

    private static Set<Id> resolveAccountIds(Id accountId, String scope) {
        Set<Id> accountIds = new Set<Id>();
        if (accountId != null) {
            accountIds.add(accountId);
            return accountIds;
        }
        Id currentUser = UserInfo.getUserId();
        List<AggregateResult> rows = scope == 'all'
            ? [SELECT Account__c accountId FROM CorporateFinancialStatement__c
               WHERE Account__c != null WITH USER_MODE GROUP BY Account__c LIMIT 2000]
            : [SELECT Account__c accountId FROM CorporateFinancialStatement__c
               WHERE Account__c != null AND Account__r.OwnerId = :currentUser WITH USER_MODE GROUP BY Account__c LIMIT 2000];
        for (AggregateResult row : rows) {
            accountIds.add((Id) row.get('accountId'));
        }
        return accountIds;
    }

    /** Recommendations closed (수주/실패) within the recent-outcome window, newest first. */
    private static Map<Id, List<Recommendation__c>> loadRecentOutcomes(Set<Id> accountIds) {
        Map<Id, List<Recommendation__c>> byAccount = new Map<Id, List<Recommendation__c>>();
        Datetime since = Datetime.now().addDays(-RadarSettings.recentOutcomeDays());
        for (Recommendation__c rec : [
            SELECT Id, Account__c, Type__c, Product__r.Name, Product__r.Family, Score__c, Expected_Amount__c, Status__c, Opportunity__c, LastModifiedDate
            FROM Recommendation__c
            WHERE Account__c IN :accountIds AND Source__c = :RadarRecommendationService.SOURCE_RADAR
              AND Status__c IN (:RecommendationOutcomeService.STATUS_WON, :RecommendationOutcomeService.STATUS_LOST)
              AND LastModifiedDate >= :since
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 2000
        ]) {
            List<Recommendation__c> accountRecs = byAccount.get(rec.Account__c);
            if (accountRecs == null) {
                accountRecs = new List<Recommendation__c>();
                byAccount.put(rec.Account__c, accountRecs);
            }
            accountRecs.add(rec);
        }
        return byAccount;
    }

    private static Boolean hasTodayProposal(List<Recommendation__c> recs) {
        if (recs == null) {
            return false;
        }
        for (Recommendation__c rec : recs) {
            if (rec.Status__c == RadarRecommendationService.STATUS_PROPOSED) {
                return true;
            }
        }
        return false;
    }

    private static Map<Id, List<Recommendation__c>> loadTodayRecommendations(Set<Id> accountIds) {
        Map<Id, List<Recommendation__c>> recsByAccount = new Map<Id, List<Recommendation__c>>();
        for (Recommendation__c recommendation : [
            SELECT Id, Account__c, Rank__c, Type__c, Product__r.Name, Product__r.Family, Score__c, Expected_Amount__c,
                   Reason__c, Score_Detail__c, Status__c, Opportunity__c, Generated_At__c
            FROM Recommendation__c
            WHERE Account__c IN :accountIds AND Source__c = :RadarRecommendationService.SOURCE_RADAR
              AND ((Generated_At__c = TODAY AND Status__c = :RadarRecommendationService.STATUS_PROPOSED)
                   OR Status__c = :RecommendationOutcomeService.STATUS_CREATED)
            WITH USER_MODE
            ORDER BY Account__c, Status__c, Rank__c
            LIMIT 10000
        ]) {
            List<Recommendation__c> accountRecs = recsByAccount.get(recommendation.Account__c);
            if (accountRecs == null) {
                accountRecs = new List<Recommendation__c>();
                recsByAccount.put(recommendation.Account__c, accountRecs);
            }
            accountRecs.add(recommendation);
        }
        return recsByAccount;
    }

    private static RadarDTO assemble(Set<Id> accountIds, Map<Id, List<Recommendation__c>> recsByAccount) {
        Map<Id, WalletShareService.AccountWallet> wallets = WalletShareService.compute(accountIds, Date.today());
        Map<Id, Integer> lastContact = RadarScoreService.lastContactDays(accountIds);
        Map<Id, List<Recommendation__c>> outcomesByAccount = loadRecentOutcomes(accountIds);
        Map<Id, String> ownerNames = new Map<Id, String>();
        for (Account account : [SELECT Id, Owner.Name FROM Account WHERE Id IN :accountIds WITH USER_MODE LIMIT 2000]) {
            ownerNames.put(account.Id, account.Owner.Name);
        }

        RadarDTO dto = new RadarDTO();
        dto.generatedAt = System.now();
        Decimal shareSum = 0;
        Integer shareCount = 0;
        for (WalletShareService.AccountWallet wallet : wallets.values()) {
            AccountRow row = new AccountRow();
            row.accountId = wallet.accountId;
            row.name = wallet.accountName;
            row.segment = wallet.segment;
            row.industry = wallet.industry;
            row.ownerName = ownerNames.get(wallet.accountId);
            row.statementPeriod = wallet.statementPeriod;
            row.lastContactDays = lastContact.get(wallet.accountId);
            row.share = wallet.share;
            row.wallet = wallet.expectedWallet;
            row.ourBalance = wallet.ourBalance;
            row.whitespace = wallet.whitespace;
            row.families = wallet.byFamily.values();
            List<Recommendation__c> recs = recsByAccount.get(wallet.accountId) ?? new List<Recommendation__c>();
            for (Recommendation__c rec : recs) {
                RecommendationDTO recDto = new RecommendationDTO();
                recDto.id = rec.Id;
                recDto.rank = rec.Rank__c?.intValue();
                recDto.type = rec.Type__c;
                recDto.productName = rec.Product__r?.Name;
                recDto.family = rec.Product__r?.Family;
                recDto.score = rec.Score__c;
                recDto.expectedAmount = rec.Expected_Amount__c;
                recDto.reason = rec.Reason__c;
                recDto.scoreDetail = rec.Score_Detail__c;
                recDto.status = rec.Status__c;
                recDto.opportunityId = rec.Opportunity__c;
                row.recommendations.add(recDto);
                dto.expectedTotal += rec.Expected_Amount__c ?? 0;
            }
            for (Recommendation__c rec : outcomesByAccount.get(wallet.accountId) ?? new List<Recommendation__c>()) {
                RecommendationDTO outcome = new RecommendationDTO();
                outcome.id = rec.Id;
                outcome.type = rec.Type__c;
                outcome.productName = rec.Product__r?.Name;
                outcome.family = rec.Product__r?.Family;
                outcome.score = rec.Score__c;
                outcome.expectedAmount = rec.Expected_Amount__c;
                outcome.status = rec.Status__c;
                outcome.opportunityId = rec.Opportunity__c;
                outcome.closedOn = rec.LastModifiedDate.date();
                row.outcomes.add(outcome);
            }
            // display order: in-progress (기회생성) first, then today's proposals by rank; renumber 1..n
            Integer displayRank = 0;
            for (RecommendationDTO recDto : row.recommendations) {
                recDto.rank = ++displayRank;
            }
            if (!row.recommendations.isEmpty()) {
                row.propensity = row.recommendations[0].score;
                row.topType = row.recommendations[0].type;
                row.topProduct = row.recommendations[0].productName;
            }
            row.priority = (row.whitespace ?? 0) * (row.propensity ?? 0);
            if (row.propensity != null && row.propensity >= 75 && row.whitespace > 0) {
                dto.priorityCount++;
            }
            dto.totalWhitespace += row.whitespace ?? 0;
            if (row.share != null) {
                shareSum += row.share;
                shareCount++;
            }
            dto.accounts.add(row);
        }
        dto.accountCount = dto.accounts.size();
        dto.averageShare = shareCount == 0 ? 0 : shareSum / shareCount;
        return dto;
    }
}