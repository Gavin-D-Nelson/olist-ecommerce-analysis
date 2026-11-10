# Decision Log

Data cleaning and analysis decisions, with reasoning.

## Day 1: Database load and data quality

### Load (sql/01_schema_and_load.sql)
- Loaded all 9 Olist CSVs into PostgreSQL with psql `\copy`.
- Row counts: orders 99,441 · customers 99,441 · order_items 112,650 ·
  order_payments 103,886 · order_reviews 99,224 · products 32,951 ·
  sellers 3,095 · geolocation 1,000,163 · category_translation 71.
- All counts reconcile with the source files. order_reviews shows 99,224 rows
  from 104,720 lines because review comments contain line breaks; the
  translation file has no newline after its last row.
- All 6 foreign keys created without error: no orphan records between orders,
  customers, items, products, sellers, payments, and reviews.
- Design choices: NUMERIC(10,2) for money (exact decimals); TEXT for zip codes
  (labels, leading zeros); no primary key on order_reviews or geolocation
  (not unique by nature); source typo "lenght" corrected in column names.

### Data quality (sql/02_data_quality_checks.sql): 21 checks + 6 profiles
Decisions applied in 03_analysis_queries.sql:

1. **KPI population:** revenue, order count, and AOV use delivered orders only
   (96,478 of 99,441 orders, 97.02%). Other statuses (shipped, canceled,
   unavailable, invoiced, processing, created, approved) are not completed sales.
2. **Revenue definition:** SUM(order_items.price), with freight reported
   separately. Payments differ from items + freight for 303 orders (~0.3%),
   and payment value can't be split by category or seller.
3. **Trend window:** Jan 2017 – Aug 2018 (20 months). Excluded: Sep 2016 (4 orders),
   Oct 2016 (324), Nov 2016 (0, gap in data), Dec 2016 (1), Sep 2018 (16),
   Oct 2018 (4).
4. **On-time delivery %:** delivered orders with a delivery date (96,470).
   8 delivered orders with no delivery date are excluded.
5. **Timeline anomalies:** 23 orders delivered before reaching the carrier and
   1,359 handed to the carrier before payment approval. Documented, not
   excluded: on-time % uses only purchase, delivered, and estimated dates.
6. **Reviews:** average score per order before joining to orders.
   768 orders have no review; 547 have more than one; 789 review_ids are each
   attached to more than one order (same review shared, not duplicate rows).
7. **Categories:** 610 products with no category are labeled "uncategorized".
   13 products in 2 categories missing from the translation table
   (portateis_cozinha_e_preparadores_de_alimentos: 10, pc_gamer: 3) are mapped
   to English manually in the analysis queries.
8. **Payments:** 9 zero-value payments, 2 with 0 installments, and 3 with type
   "not_defined" (shown as "Unknown"). Too few to affect results; noted.
9. **Customers:** retention metrics use customer_unique_id
   (96,096 unique customers vs 99,441 customer_ids).
10. **Orders with no items / no payment (resolved):** all 775 orders with no
    items are non-delivered (unavailable 603, canceled 164, created 5,
    invoiced 2, shipped 1), so the delivered-only rule already excludes them.
    Most unavailable orders (603 of 609) have no items: placed but never
    fulfilled. The 1 order with no payment record is delivered; it stays in
    revenue and delivery KPIs and is simply absent from payment analysis (Q11).
    All 23 delivered-before-carrier orders are delivered (0.02% of the
    96,470 on-time population); kept, and noted as a limitation in the README.

## Day 2 — Analysis queries (sql/03_analysis_queries.sql)

All 12 business questions answered, plus a KPI summary query and a CSV export script for Tableau (sql/04_dashboard_exports.sql).

### Day 2 decisions
1. **One population for everything:** delivered orders, Jan 2017 – Aug 2018 (96,211 orders). Analysis results and dashboard cards all reconcile to the same total. This excludes 267 delivered orders from 2016 and Sep–Oct 2018.
2. **Reconciliation check:** category (Q3), state (Q6) and seller (Q10) revenue each sum to exactly R$13,181,027.13, the Q1 total.
3. **Repeat purchase** = a delivered order on a *later calendar day* than the customer's first order. Counting "2+ orders" would include 784 customers who only placed extra orders on the same day (3.00% vs 2.15%).
4. **Right-censoring:** recent customers had little time to return, so retention is also measured on a fair cohort: customers whose first order was before 2018-03-05, returning within 180 days.
5. **Late delivery** = delivered on a later calendar *date* than the estimated date. The estimated date is stored at midnight, so comparing timestamps would mark same-day deliveries as late (8.13% vs 6.79%, about 1,290 orders misclassified).
6. **Minimum sample sizes:** seller delivery ranking requires ≥ 50 delivered orders (424 sellers); category review ranking requires ≥ 100 reviewed orders (52 categories).
7. **Seller fault vs. carrier fault:** late-handoff % = carrier pickup after the seller's shipping_limit_date.
8. **Payments include freight,** so payment totals (R$15,375,875) don't match item revenue. Revenue always comes from order_items.price.
9. **Decision 8 (Day 1) never triggered:** the 3 "not_defined" payments are outside delivered orders in the window, so no "Unknown" row appears.
10. **Category labels** stay as raw source names in SQL (source typos such as "costruction_tools_garden" included); clean display names in Tableau.

### KPI cards (verified)
| KPI | Value |
|---|---|
| Total revenue | R$13,181,027.13 |
| Total orders | 96,211 |
| Average order value | R$137.00 |
| On-time delivery | 93.21% (of 96,203 orders with a delivery date) |
| Average review score | 4.16 (of 95,568 reviewed orders) |

### Findings
**Revenue & growth (Q1–Q3)**
- Jan–Aug 2018 revenue was R$7,218,125 vs R$2,993,456 in Jan–Aug 2017 (+141%). Orders grew +140% (52,783 vs 21,998), so growth came from volume, not basket size.
- AOV is flat: R$136.08 (Jan–Aug 2017) vs R$136.75 (Jan–Aug 2018); monthly range R$124.38–149.06.
- Peak month: Nov 2017, R$987,765 and 7,289 orders (+52.4% MoM). Black Friday is the likely cause (hypothesis, not tested).
- Growth plateaued from Mar 2018 (R$838k–978k per month). Checked: delivered % stays 97.1–98.9% in every 2018 month, so this is not a snapshot artifact.
- Top 5 categories = 39.88% of revenue; 18 of 74 categories = 81.29%. Uncategorized products = R$170,661 (1.29%).

**Customers & retention (Q4–Q6)**
- Only 2.15% of 93,104 customers returned (2,005). Fair 180-day cohort: 1.97% (1,107 of 56,194).
- Median time to second order: 74 days (p25 23, p75 174). 55.1% of returns happen within 90 days.
- São Paulo = 38.36% of revenue. Southeast + South (7 states) = 79.8% of revenue.
- The other 20 states pay ~62% more freight per order (~R$33.32 vs ~R$20.62) and have higher AOV (R$162.21 vs R$131.82).

**Delivery (Q7–Q9)**
- 93.21% on time, 6.79% late. Median delivery 10 days. On-time orders arrive 13.4 days early on average (estimates are padded).
- Late % spiked in Nov 2017 (12.40%) and Feb–Mar 2018 (14.13%, 18.96%). The Feb–Mar spike is not explained by order volume; cause unknown.
- Late orders average 2.27 stars vs 4.29 on time (−2.02). Low scores (≤2): 62.4% vs 9.2%. Most damage happens in the first week late (1–3 days: 3.29; 4–7 days: 2.11; 8+ days: ~1.7).
- Worst states: AL 21.46%, MA 17.53%, SE 15.36%. Northeast overall ~12.8% late (~1.9× national).
- Rio de Janeiro: 12.14% late on 12,310 orders (~23% of all late orders) vs São Paulo 4.50%.
- Northern states (AM, AP, RO, AC) have the slowest deliveries (19–27 days) but the lowest late % (2.8–3.8%) because their estimates include ~20 days of buffer.
- Worst seller (54965bbe, PR): 30.1% late, 53.4% late handoff. Some poor performers hand off on time (8.0% late handoff), so the carrier is the issue there.

**Sellers, payments, reviews (Q10–Q12)**
- 2,945 sellers. Top 10 = 13.30% of revenue (largest 1.72%). Top 10% of sellers = 67.04%. 531 sellers (18.0%) reach 80%. Median seller revenue: R$849.70 over 20 months.
- None of the top 10 revenue sellers are among the 15 worst for delivery.
- Credit card: 77.01% of orders. 66.81% of card orders use installments (avg 3.50).
- Order value rises with installments: R$101.14 (paid in full) → R$411.02 (10+). 7+ installments = 15.8% of card orders but ~32% of card-order value. Correlation 0.370.
- Lowest-rated category: office_furniture 3.65 (−0.51 vs average), late only 8.0%, so a product issue. fashion_male_clothing 3.85 with 3.8% late, also a product issue.
- The worst category gap (−0.51) is about a quarter of the late-delivery gap (−2.02): delivery matters more than category for reviews.

### Caveats / limitations
- Aug 2018 delivery time (7.7 days) is biased low: slow August orders were not yet delivered at the data snapshot.
- Olist sells through larger marketplaces, so customers may not see themselves as Olist customers; part of the low repeat rate may be structural.
- Small states (e.g. RR, 39 customers) have unstable averages.
- An order with items from two sellers or two categories counts for each of them in Q9b and Q12.
- Correlations (installments vs value, category vs review) show association, not cause.

### Recommendations (draft for README)
1. **Fix short delays first:** alert or expedite at-risk orders. 1–3 days late already costs a full review point.
2. **Prioritize Rio de Janeiro logistics:** one market, ~23% of all late orders.
3. **Northeast growth test:** free or subsidized shipping above an order threshold.
4. **Retention program timed to the first 90 days,** when 55% of returns happen.
5. **Seller management:** penalties or coaching for sellers with high late-handoff %; carrier review where handoff is on time.
6. **Promote installments on high-value categories** to test raising AOV.