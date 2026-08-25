/**
 * Invocable action returning product recommendation candidates for an Opportunity.
 *
 * The action gathers active products (with their eligibility, fee, and term fields)
 * and the Opportunity Amount/Account context, then returns them as raw material
 * for an agent to interpret. Eligibility matching is intentionally NOT performed
 * server-side - the agent reasons over the returned Eligibility_Rule__c text and the
 * Opportunity context to decide fit.
 *
 * Backlog 21 (D-segment cross-sell): the response also carries the held products
 * (Asset) of the Opportunity account, with principal, interest rate and maturity
 * date, so the agent can ground a cross-sell recommendation on what the customer
 * already holds and when it matures. Nothing is ranked or filtered for fit
 * server-side; hasMaturingAsset only flags that a maturity falls inside the window.
 *
 * The Opportunity is read in the running user context (user mode). If the running
 * user cannot access the supplied Opportunity Id, the query returns nothing and the
 * response carries an empty candidate list - no exception is thrown.
 *
 * Callable from Flows, Process Builder, and Agentforce.
 */
public with sharing class ProductRecommendationAction {
    @TestVisible
    private static final Integer MAX_PRODUCTS = 2000;

    @TestVisible
    private static final Integer MAX_ASSETS = 200;

    // A held product maturing within this many days puts the account in cross-sell context.
    @TestVisible
    private static final Integer MATURITY_WINDOW_DAYS = 90;

    /**
     * Returns product recommendation candidates for each requested Opportunity.
     *
     * @param requests List of Request inputs (opportunityId plus sanitizedNote)
     * @return List of Response outputs, one per request, each holding candidate products
     */
    @InvocableMethod(
        label='Recommend Products for Opportunity'
        description='Returns active product candidates with eligibility, fee, and term data, plus the Opportunity context and the account held products with maturity dates, for an agent to match.'
        category='Sales'
    )
    public static List<Response> recommend(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        // Collect Opportunity Ids for a single bulkified, user-mode query.
        Set<Id> opportunityIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.opportunityId != null) {
                opportunityIds.add(req.opportunityId);
            }
        }

        // User-mode query: Opportunities the running user cannot access simply do not
        // appear in the map, which yields an empty candidate list downstream.
        Map<Id, Opportunity> opportunitiesById = opportunityIds.isEmpty()
            ? new Map<Id, Opportunity>()
            : new Map<Id, Opportunity>([
                SELECT Id, Amount, AccountId, Account.Name, Account.Industry
                FROM Opportunity
                WHERE Id IN :opportunityIds
                WITH USER_MODE
            ]);

        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opportunitiesById.values()) {
            if (opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        // Held products of those accounts, keyed by Account Id (user mode).
        Map<Id, List<HeldAsset>> heldAssetsByAccountId = queryHeldAssets(accountIds);

        // Active products are the same for every request; query them once.
        List<Product2> activeProducts = queryActiveProducts();

        for (Request req : requests) {
            responses.add(buildResponse(req, opportunitiesById, heldAssetsByAccountId, activeProducts));
        }
        return responses;
    }

    /**
     * Loads active products with the fields the agent needs to reason about eligibility.
     *
     * @return Active Product2 records (user mode enforced)
     */
    private static List<Product2> queryActiveProducts() {
        return [
            SELECT Id, Name, Eligibility_Rule__c, Default_Fee_Rate__c,
                   Min_Term_Days__c, Max_Term_Days__c
            FROM Product2
            WHERE IsActive = true
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAX_PRODUCTS
        ];
    }

    /**
     * Loads the held products (Asset) of the given accounts in user mode.
     * Accounts the running user cannot access simply produce no entries.
     *
     * @param accountIds Accounts to load held products for
     * @return Held products keyed by Account Id
     */
    private static Map<Id, List<HeldAsset>> queryHeldAssets(Set<Id> accountIds) {
        Map<Id, List<HeldAsset>> byAccountId = new Map<Id, List<HeldAsset>>();
        if (accountIds == null || accountIds.isEmpty()) {
            return byAccountId;
        }

        Date todayDate = Date.today();
        for (Asset record : [
            SELECT Id, Name, Status, InstallDate, UsageEndDate, Price,
                   Principal_Amount__c, Interest_Rate__c,
                   AccountId, Product2Id, Product2.Name
            FROM Asset
            WHERE AccountId IN :accountIds
            WITH USER_MODE
            ORDER BY UsageEndDate NULLS LAST
            LIMIT :MAX_ASSETS
        ]) {
            HeldAsset item = new HeldAsset();
            item.assetName = record.Name;
            item.productName = record.Product2Id == null ? null : record.Product2.Name;
            item.status = record.Status;
            item.principalAmount = record.Principal_Amount__c != null
                ? record.Principal_Amount__c
                : record.Price;
            item.interestRate = record.Interest_Rate__c;
            item.startDate = record.InstallDate;
            item.maturityDate = record.UsageEndDate;
            item.daysToMaturity = record.UsageEndDate == null
                ? null
                : todayDate.daysBetween(record.UsageEndDate);

            if (!byAccountId.containsKey(record.AccountId)) {
                byAccountId.put(record.AccountId, new List<HeldAsset>());
            }
            byAccountId.get(record.AccountId).add(item);
        }
        return byAccountId;
    }

    /**
     * Builds a single response: candidate products, the Opportunity context, and the
     * held products of the related account.
     * An inaccessible or missing Opportunity yields an empty candidate list, not an error.
     */
    private static Response buildResponse(
        Request req,
        Map<Id, Opportunity> opportunitiesById,
        Map<Id, List<HeldAsset>> heldAssetsByAccountId,
        List<Product2> activeProducts
    ) {
        Response res = new Response();
        res.recommendations = new List<Recommendation>();
        res.heldAssets = new List<HeldAsset>();
        res.hasMaturingAsset = false;

        Opportunity opp = (req == null || req.opportunityId == null)
            ? null
            : opportunitiesById.get(req.opportunityId);

        // No accessible Opportunity -> return empty candidates (per requirement, not an error).
        if (opp == null) {
            res.heldAssetText = buildHeldAssetText(res.heldAssets);
            return res;
        }

        res.opportunityAmount = opp.Amount;
        res.accountName = opp.Account == null ? null : opp.Account.Name;
        res.accountIndustry = opp.Account == null ? null : opp.Account.Industry;

        List<HeldAsset> held = opp.AccountId == null
            ? null
            : heldAssetsByAccountId.get(opp.AccountId);
        if (held != null) {
            res.heldAssets = held;
            for (HeldAsset item : held) {
                if (item.daysToMaturity != null && item.daysToMaturity <= MATURITY_WINDOW_DAYS) {
                    res.hasMaturingAsset = true;
                }
            }
        }
        res.heldAssetText = buildHeldAssetText(res.heldAssets);

        for (Product2 product : activeProducts) {
            Recommendation candidate = new Recommendation();
            candidate.productName = product.Name;
            candidate.eligibilityBasis = product.Eligibility_Rule__c;
            candidate.feeRate = product.Default_Fee_Rate__c;
            candidate.minTermDays = product.Min_Term_Days__c;
            candidate.maxTermDays = product.Max_Term_Days__c;
            res.recommendations.add(candidate);
        }
        res.recommendationText = buildRecommendationText(res.recommendations);
        return res;
    }

    /**
     * Flattens candidate products into Flow-readable display text.
     * This is a candidate list, not an AI-ranked recommendation.
     */
    @TestVisible
    private static String buildRecommendationText(List<Recommendation> recommendations) {
        if (recommendations == null || recommendations.isEmpty()) {
            return '추천 가능한 활성 상품이 없습니다.';
        }

        List<String> lines = new List<String>{ '활성 상품 후보' };
        for (Recommendation item : recommendations) {
            List<String> details = new List<String>();
            if (item.feeRate != null) {
                details.add('수수료율 ' + String.valueOf(item.feeRate));
            }
            if (item.minTermDays != null || item.maxTermDays != null) {
                String minTerm = item.minTermDays == null ? '-' : String.valueOf(item.minTermDays);
                String maxTerm = item.maxTermDays == null ? '-' : String.valueOf(item.maxTermDays);
                details.add('기간 ' + minTerm + '~' + maxTerm + '일');
            }
            if (String.isNotBlank(item.eligibilityBasis)) {
                details.add('조건 ' + item.eligibilityBasis);
            }
            lines.add('- ' + item.productName + (details.isEmpty() ? '' : ' | ' + String.join(details, ' | ')));
        }
        return String.join(lines, '\n');
    }

    /**
     * Flattens the held products into Flow-readable display text, including maturity.
     * This is source material for the agent, not a recommendation.
     */
    @TestVisible
    private static String buildHeldAssetText(List<HeldAsset> heldAssets) {
        if (heldAssets == null || heldAssets.isEmpty()) {
            return '조회된 보유상품이 없습니다.';
        }

        List<String> lines = new List<String>{ '보유상품(만기 포함)' };
        for (HeldAsset item : heldAssets) {
            List<String> details = new List<String>();
            if (String.isNotBlank(item.productName)) {
                details.add('상품 ' + item.productName);
            }
            if (item.principalAmount != null) {
                details.add('원금 ' + String.valueOf(item.principalAmount));
            }
            if (item.interestRate != null) {
                details.add('금리 ' + String.valueOf(item.interestRate));
            }
            if (item.maturityDate != null) {
                details.add('만기 ' + formatDate(item.maturityDate));
            }
            if (item.daysToMaturity != null) {
                details.add('만기까지 ' + String.valueOf(item.daysToMaturity) + '일');
            }
            if (String.isNotBlank(item.status)) {
                details.add('상태 ' + item.status);
            }
            lines.add('- ' + item.assetName + (details.isEmpty() ? '' : ' | ' + String.join(details, ' | ')));
        }
        return String.join(lines, '\n');
    }

    @TestVisible
    private static String formatDate(Date value) {
        if (value == null) {
            return '';
        }
        return DateTime.newInstance(value, Time.newInstance(0, 0, 0, 0)).format('yyyy-MM-dd');
    }

    /**
     * Input parameters from the calling Flow/agent.
     */
    public class Request {
        @InvocableVariable(label='Opportunity Id' description='The Opportunity to recommend products for' required=true)
        public Id opportunityId;

        @InvocableVariable(label='Sanitized Note' description='Masked note text for the agent to reason over' required=false)
        public String sanitizedNote;
    }

    /**
     * Output returned to the calling Flow/agent: the Opportunity context plus candidates.
     */
    public class Response {
        @InvocableVariable(label='Opportunity Amount' description='Amount of the Opportunity, if accessible')
        public Decimal opportunityAmount;

        @InvocableVariable(label='Account Name' description='Related Account name, if accessible')
        public String accountName;

        @InvocableVariable(label='Account Industry' description='Related Account industry, if accessible')
        public String accountIndustry;

        @InvocableVariable(label='Recommendations' description='Candidate products for the agent to match; empty when the Opportunity is inaccessible')
        public List<Recommendation> recommendations;

        @InvocableVariable(label='Recommendation Candidate Text' description='Flow-readable active product candidate list; not AI-ranked')
        public String recommendationText;

        @InvocableVariable(label='Held Assets' description='Products the related account already holds, with principal, rate and maturity date; empty when none or inaccessible')
        public List<HeldAsset> heldAssets;

        @InvocableVariable(label='Held Asset Text' description='Flow-readable held product list including maturity dates')
        public String heldAssetText;

        @InvocableVariable(label='Has Maturing Asset' description='True when the account holds a product maturing within 90 days or already matured; cross-sell context')
        public Boolean hasMaturingAsset;
    }

    /**
     * A single product candidate: raw material for the agent to interpret.
     */
    public class Recommendation {
        @InvocableVariable(label='Product Name' description='Product name')
        public String productName;

        @InvocableVariable(label='Eligibility Basis' description='Eligibility rule text from the product')
        public String eligibilityBasis;

        @InvocableVariable(label='Fee Rate' description='Default fee rate for the product')
        public Decimal feeRate;

        @InvocableVariable(label='Min Term Days' description='Minimum term in days')
        public Decimal minTermDays;

        @InvocableVariable(label='Max Term Days' description='Maximum term in days')
        public Decimal maxTermDays;
    }

    /**
     * A single held product of the account: raw material for cross-sell grounding.
     */
    public class HeldAsset {
        @InvocableVariable(label='Asset Name' description='Name of the held product record')
        public String assetName;

        @InvocableVariable(label='Product Name' description='Catalog product behind the held product')
        public String productName;

        @InvocableVariable(label='Status' description='Held product status')
        public String status;

        @InvocableVariable(label='Principal Amount' description='Principal amount, falling back to price when principal is blank')
        public Decimal principalAmount;

        @InvocableVariable(label='Interest Rate' description='Interest rate of the held product')
        public Decimal interestRate;

        @InvocableVariable(label='Start Date' description='Install date of the held product')
        public Date startDate;

        @InvocableVariable(label='Maturity Date' description='Maturity date of the held product, from Usage End Date')
        public Date maturityDate;

        @InvocableVariable(label='Days To Maturity' description='Days from today to maturity; negative when already matured')
        public Integer daysToMaturity;
    }
}