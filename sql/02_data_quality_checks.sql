/* =====================================================================
   02_data_quality_checks.sql
   Olist E-Commerce Analysis: data quality checks
   Author: Gavin Nelson

   Purpose
     Find problems in the raw data BEFORE calculating any KPI, so every
     number in the analysis rests on a documented cleaning decision.

   How to run (from the repo root):
       psql -d olist -f sql/02_data_quality_checks.sql

   Read-only: nothing here changes the data. Decisions based on these
   results are logged in notes.md and applied in 03_analysis_queries.sql.
   ===================================================================== */

-- Stop at the first error.
\set ON_ERROR_STOP on
-- Print all results directly instead of pausing in a scroll-through pager.
\pset pager off


/* ---------------------------------------------------------------------
   SECTION 1: DATA QUALITY SCORECARD
   One row per check. "expected" is what a clean dataset would show:
     '0'    = any count above zero is a problem to investigate
     'info' = not an error by itself, but it affects how we define KPIs
   Pattern: each check counts the rows that FAIL a rule, so the whole
   scorecard can be read at a glance.
   --------------------------------------------------------------------- */

SELECT check_id, check_name, expected, issue_count
FROM (

    -- Integrity: an order with no items would have zero revenue and skew AOV.
    -- NOT EXISTS is an "anti-join": keep orders with no matching row.
    SELECT 1 AS check_id, 'Orders with no items' AS check_name, '0' AS expected,
           COUNT(*) AS issue_count
    FROM orders o
    WHERE NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.order_id)

    UNION ALL
    SELECT 2, 'Orders with no payment record', '0', COUNT(*)
    FROM orders o
    WHERE NOT EXISTS (SELECT 1 FROM order_payments p WHERE p.order_id = o.order_id)

    -- Reviews: affects Q8 and Q12 (review scores). Missing or repeated reviews
    -- change how we average scores per order.
    UNION ALL
    SELECT 3, 'Orders with no review', 'info', COUNT(*)
    FROM orders o
    WHERE NOT EXISTS (SELECT 1 FROM order_reviews r WHERE r.order_id = o.order_id)

    UNION ALL
    SELECT 4, 'Orders with more than one review', 'info', COUNT(*)
    FROM (SELECT order_id FROM order_reviews
          GROUP BY order_id HAVING COUNT(*) > 1) x

    UNION ALL
    SELECT 5, 'review_ids appearing more than once', 'info', COUNT(*)
    FROM (SELECT review_id FROM order_reviews
          GROUP BY review_id HAVING COUNT(*) > 1) x

    UNION ALL
    SELECT 6, 'review_ids linked to more than one order', 'info', COUNT(*)
    FROM (SELECT review_id FROM order_reviews
          GROUP BY review_id HAVING COUNT(DISTINCT order_id) > 1) x

    -- Delivery dates: drive Q7-Q9 (on-time %). A delivered order with no
    -- delivery date can't be classified as on time or late.
    UNION ALL
    SELECT 7, 'Delivered orders missing customer delivery date', '0', COUNT(*)
    FROM orders
    WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL

    UNION ALL
    SELECT 8, 'Non-delivered orders that have a delivery date', '0', COUNT(*)
    FROM orders
    WHERE order_status <> 'delivered' AND order_delivered_customer_date IS NOT NULL

    UNION ALL
    SELECT 9, 'Orders missing estimated delivery date', '0', COUNT(*)
    FROM orders
    WHERE order_estimated_delivery_date IS NULL

    -- Timeline logic: events should happen in order
    -- (purchase -> approval -> carrier -> customer).
    UNION ALL
    SELECT 10, 'Delivered to customer before purchase', '0', COUNT(*)
    FROM orders
    WHERE order_delivered_customer_date < order_purchase_timestamp

    UNION ALL
    SELECT 11, 'Delivered to customer before handed to carrier', '0', COUNT(*)
    FROM orders
    WHERE order_delivered_customer_date < order_delivered_carrier_date

    UNION ALL
    SELECT 12, 'Handed to carrier before payment approved', '0', COUNT(*)
    FROM orders
    WHERE order_delivered_carrier_date < order_approved_at

    -- Value ranges
    UNION ALL
    SELECT 13, 'Review scores missing or outside 1-5', '0', COUNT(*)
    FROM order_reviews
    WHERE review_score IS NULL OR review_score NOT BETWEEN 1 AND 5

    UNION ALL
    SELECT 14, 'Order items with price missing or <= 0', '0', COUNT(*)
    FROM order_items
    WHERE price IS NULL OR price <= 0

    -- Payments: affects Q11 (payment methods, installments)
    UNION ALL
    SELECT 15, 'Payment records with value = 0', 'info', COUNT(*)
    FROM order_payments
    WHERE payment_value = 0

    UNION ALL
    SELECT 16, 'Payment records with 0 installments', 'info', COUNT(*)
    FROM order_payments
    WHERE payment_installments = 0

    UNION ALL
    SELECT 17, 'Payment records with type not_defined', 'info', COUNT(*)
    FROM order_payments
    WHERE payment_type = 'not_defined'

    -- Categories: affects Q3 and Q12 (revenue and reviews by category)
    UNION ALL
    SELECT 18, 'Products with no category', 'info', COUNT(*)
    FROM products
    WHERE product_category_name IS NULL

    UNION ALL
    SELECT 19, 'Products whose category has no English name', '0', COUNT(*)
    FROM products p
    WHERE p.product_category_name IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM category_translation t
                      WHERE t.product_category_name = p.product_category_name)

    -- Revenue definition: do payments match item price + freight per order?
    -- Each side is aggregated to one row per order BEFORE joining. Joining
    -- the raw tables would multiply rows (an order with 3 items and 2
    -- payments would produce 6 rows) and inflate both totals.
    UNION ALL
    SELECT 20, 'Orders where payments differ from items + freight', 'info', COUNT(*)
    FROM (
        SELECT i.order_id
        FROM (SELECT order_id, SUM(price + freight_value) AS items_total
              FROM order_items GROUP BY order_id) i
        JOIN (SELECT order_id, SUM(payment_value) AS paid_total
              FROM order_payments GROUP BY order_id) p
          ON p.order_id = i.order_id
        WHERE ABS(i.items_total - p.paid_total) > 0.01
    ) x

    -- Geography: Brazilian zip prefixes are 5 digits. Shorter values mean
    -- leading zeros were lost somewhere, which would break geolocation joins.
    UNION ALL
    SELECT 21, 'Customer zip prefixes not 5 characters', '0', COUNT(*)
    FROM customers
    WHERE LENGTH(customer_zip_code_prefix) <> 5

) checks
ORDER BY check_id;


/* ---------------------------------------------------------------------
   SECTION 2: ORDER STATUS BREAKDOWN
   Which statuses exist, how common each is, and which have a delivery date.
   This decides which orders count toward revenue and delivery KPIs.
   SUM(COUNT(*)) OVER () is a window function over the grouped result:
   it adds up all group counts to get the grand total for the percentage.
   --------------------------------------------------------------------- */

SELECT
    order_status,
    COUNT(*)                                            AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_orders,
    COUNT(order_delivered_customer_date)                AS with_delivery_date  -- COUNT(col) skips NULLs
FROM orders
GROUP BY order_status
ORDER BY orders DESC;


/* ---------------------------------------------------------------------
   SECTION 3: ORDERS PER MONTH
   Identifies partial or sparse months to exclude from trend analysis
   (Q1, Q2). first_order and last_order show how much of each month the
   data actually covers.
   --------------------------------------------------------------------- */

SELECT
    DATE_TRUNC('month', order_purchase_timestamp)::date  AS month,
    COUNT(*)                                              AS orders,
    MIN(order_purchase_timestamp)                         AS first_order,
    MAX(order_purchase_timestamp)                         AS last_order
FROM orders
GROUP BY 1
ORDER BY 1;


/* ---------------------------------------------------------------------
   SECTION 4: CUSTOMER IDENTITY
   Confirms customer_id is per order and customer_unique_id is the real
   person. The gap between the two counts is why retention (Q4, Q5) must
   use customer_unique_id.
   --------------------------------------------------------------------- */

SELECT
    COUNT(DISTINCT c.customer_id)         AS customer_ids,
    COUNT(DISTINCT c.customer_unique_id)  AS unique_customers,
    COUNT(o.order_id)                     AS orders
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id;


/* ---------------------------------------------------------------------
   SECTION 5: CATEGORIES WITH NO ENGLISH TRANSLATION
   Lists any Portuguese category names missing from the translation table,
   so they can be handled explicitly instead of silently dropping out of
   category reports. (LEFT JOIN ... IS NULL is a second anti-join pattern,
   equivalent to NOT EXISTS above.)
   --------------------------------------------------------------------- */

SELECT
    p.product_category_name,
    COUNT(*) AS products
FROM products p
LEFT JOIN category_translation t
       ON t.product_category_name = p.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name IS NULL
GROUP BY p.product_category_name
ORDER BY products DESC;


/* ---------------------------------------------------------------------
   SECTION 6: WHICH STATUSES DO THE PROBLEM ORDERS HAVE?
   Breaks scorecard checks 1, 2, and 11 down by order status, to see
   whether they touch the delivered orders used for every KPI.
   Item and payment counts are aggregated per order BEFORE joining
   (avoids fan-out). SUM(CASE WHEN ... THEN 1 ELSE 0 END) counts only
   the rows that meet a condition, giving several counts in one pass.
   --------------------------------------------------------------------- */

WITH item_counts AS (
    SELECT order_id, COUNT(*) AS n_items
    FROM order_items
    GROUP BY order_id
),
payment_counts AS (
    SELECT order_id, COUNT(*) AS n_payments
    FROM order_payments
    GROUP BY order_id
)
SELECT
    o.order_status,
    COUNT(*)                                                    AS orders,
    SUM(CASE WHEN ic.order_id IS NULL THEN 1 ELSE 0 END)        AS no_items,
    SUM(CASE WHEN pc.order_id IS NULL THEN 1 ELSE 0 END)        AS no_payment,
    SUM(CASE WHEN o.order_delivered_customer_date
                  < o.order_delivered_carrier_date
             THEN 1 ELSE 0 END)                                 AS delivered_before_carrier
FROM orders o
LEFT JOIN item_counts    ic ON ic.order_id = o.order_id
LEFT JOIN payment_counts pc ON pc.order_id = o.order_id
GROUP BY o.order_status
ORDER BY orders DESC;
