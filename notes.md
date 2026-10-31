# Decision Log

Data cleaning and analysis decisions, with reasoning.

## 2026-10-31 — Day 1: Database load and data quality

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