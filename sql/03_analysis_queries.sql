\set ON_ERROR_STOP on
\pset pager off

-- =====================================================================
-- Q1. What is monthly revenue and order volume, and what is the
--     month-over-month (MoM) revenue growth rate?
-- Q2. What is the average order value (AOV), and how has it changed
--     over time?
--
-- Population: delivered orders only (Day 1 decision 1)
-- Revenue:    SUM(order_items.price); freight excluded (decision 2)
-- Window:     Jan 2017 - Aug 2018 by purchase month, 20 months (decision 3)
-- =====================================================================
WITH order_revenue AS (
    -- Collapse order_items to one row per order BEFORE joining,
    -- so multi-item orders are not counted more than once
    SELECT
        order_id,
        SUM(price)::numeric AS order_revenue
    FROM order_items
    GROUP BY order_id
),
monthly AS (
    SELECT
        DATE_TRUNC('month', o.order_purchase_timestamp)::date AS order_month,
        SUM(r.order_revenue)                                  AS revenue,
        COUNT(*)                                              AS order_count
    FROM orders AS o
    JOIN order_revenue AS r
        ON r.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
    GROUP BY 1
)
SELECT
    order_month,
    ROUND(revenue, 2)                                   AS revenue,
    order_count,
    ROUND(revenue / order_count, 2)                     AS aov,
    ROUND(
        100.0 * (revenue - LAG(revenue) OVER w)
        / NULLIF(LAG(revenue) OVER w, 0)
    , 1)                                                AS mom_growth_pct,
    ROUND(SUM(revenue) OVER w, 2)                       AS cumulative_revenue
FROM monthly
WINDOW w AS (ORDER BY order_month)
ORDER BY order_month;

-- Q1 follow-up check: is the 2018 plateau real, or are recent months
-- undercounted because orders still in transit were excluded?
SELECT
    DATE_TRUNC('month', order_purchase_timestamp)::date          AS order_month,
    COUNT(*)                                                     AS all_orders,
    COUNT(*) FILTER (WHERE order_status = 'delivered')           AS delivered,
    COUNT(*) FILTER (WHERE order_status = 'shipped')             AS shipped,
    COUNT(*) FILTER (WHERE order_status NOT IN ('delivered', 'shipped')) AS other_status,
    ROUND(100.0 * COUNT(*) FILTER (WHERE order_status = 'delivered')
          / COUNT(*), 1)                                         AS delivered_pct
FROM orders
WHERE order_purchase_timestamp >= '2018-01-01'
  AND order_purchase_timestamp <  '2018-09-01'
GROUP BY 1
ORDER BY 1;

-- =====================================================================
-- Q3. Which product categories drive the most revenue?
--
-- Population: delivered orders, Jan 2017 - Aug 2018 (same as Q1/Q2,
--             so category revenue reconciles to the monthly total)
-- Grain:      item level. Category belongs to the product, and one
--             order can contain items from several categories.
-- Labels:     English name -> 2 manual translations -> 'uncategorized'
--             (Day 1 decision 7)
-- =====================================================================
WITH delivered_orders AS (
    SELECT order_id
    FROM orders
    WHERE order_status = 'delivered'
      AND order_purchase_timestamp >= '2017-01-01'
      AND order_purchase_timestamp <  '2018-09-01'
),
category_sales AS (
    SELECT
        COALESCE(
            t.product_category_name_english,
            CASE p.product_category_name
                WHEN 'portateis_cozinha_e_preparadores_de_alimentos'
                    THEN 'portable_kitchen_food_preparers'
                WHEN 'pc_gamer'
                    THEN 'pc_gamer'
            END,
            'uncategorized'
        )                               AS category,
        SUM(oi.price)::numeric          AS revenue,
        COUNT(*)                        AS items_sold,
        COUNT(DISTINCT oi.order_id)     AS order_count
    FROM order_items AS oi
    JOIN delivered_orders AS d
        ON d.order_id = oi.order_id
    JOIN products AS p
        ON p.product_id = oi.product_id
    LEFT JOIN category_translation AS t
        ON t.product_category_name = p.product_category_name
    GROUP BY 1
)
SELECT
    RANK() OVER (ORDER BY revenue DESC)                  AS revenue_rank,
    category,
    ROUND(revenue, 2)                                    AS revenue,
    items_sold,
    order_count,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)     AS pct_of_revenue,
    ROUND(100.0 * SUM(revenue) OVER (
              ORDER BY revenue DESC, category
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(revenue) OVER (), 2)                     AS cumulative_pct
FROM category_sales
ORDER BY revenue_rank, category;

-- =====================================================================
-- Shared base for Q4 and Q5: one row per real customer.
--
-- Uses customer_unique_id (Day 1 decision 9). customer_id is new on
-- every order, so with it every customer would look like a one-time
-- buyer.
-- Population: delivered orders, Jan 2017 - Aug 2018.
-- A "return" = an order on a LATER calendar day than the first order.
-- Extra orders placed the same day as the first are part of the
-- first visit, not a return.
--
-- TEMP VIEW: saves this logic once so the next three queries can reuse
-- it. It disappears when psql finishes, so nothing is added to the
-- database.
-- =====================================================================
CREATE OR REPLACE TEMP VIEW customer_summary AS
WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_purchase_timestamp,
        MIN(o.order_purchase_timestamp)
            OVER (PARTITION BY c.customer_unique_id)   AS first_order_at
    FROM orders AS o
    JOIN customers AS c
        ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
),
per_customer AS (
    SELECT
        customer_unique_id,
        first_order_at,
        COUNT(*)                                        AS order_count,
        MIN(order_purchase_timestamp) FILTER (
            WHERE order_purchase_timestamp::date > first_order_at::date
        )                                               AS return_order_at
    FROM customer_orders
    GROUP BY customer_unique_id, first_order_at
)
SELECT
    customer_unique_id,
    first_order_at,
    order_count,
    return_order_at,
    return_order_at::date - first_order_at::date        AS return_gap_days
FROM per_customer;

-- =====================================================================
-- Q4. What percentage of customers make a repeat purchase?
--
-- Two rates:
--   repeat_rate_pct: all customers. Understates repeat buying, because
--     customers who first bought in mid-2018 had little time to return.
--   repeat_rate_180d_pct: only customers who first bought at least
--     180 days before the data ends (before 2018-03-05). Each had a
--     full 180 days to come back, so the comparison is fair.
-- =====================================================================
WITH flags AS (
    SELECT
        order_count >= 2                                AS multi_order,
        return_order_at IS NOT NULL                     AS returned,
        first_order_at < DATE '2018-09-01' - 180        AS full_180d_followup,
        return_order_at < first_order_at + INTERVAL '180 days'
                                                        AS returned_within_180d
    FROM customer_summary
)
SELECT
    COUNT(*)                                            AS customers,
    COUNT(*) FILTER (WHERE multi_order)                 AS multi_order_customers,
    COUNT(*) FILTER (WHERE returned)                    AS returning_customers,
    ROUND(100.0 * COUNT(*) FILTER (WHERE returned)
          / COUNT(*), 2)                                AS repeat_rate_pct,
    COUNT(*) FILTER (WHERE full_180d_followup)          AS cohort_180d_customers,
    COUNT(*) FILTER (WHERE full_180d_followup
                       AND returned_within_180d)        AS cohort_returned_180d,
    ROUND(100.0 * COUNT(*) FILTER (WHERE full_180d_followup
                                     AND returned_within_180d)
          / NULLIF(COUNT(*) FILTER (WHERE full_180d_followup), 0), 2)
                                                        AS repeat_rate_180d_pct
FROM flags;

-- =====================================================================
-- Q5a. How long is the typical gap between first and second orders?
-- Summary statistics for customers who returned. The median is the
-- headline number because a few very long gaps pull the average up.
-- =====================================================================
SELECT
    COUNT(*)                                            AS returning_customers,
    ROUND(AVG(return_gap_days), 1)                      AS avg_gap_days,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY return_gap_days)::numeric, 1)
                                                        AS p25_gap_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY return_gap_days)::numeric, 1)
                                                        AS median_gap_days,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY return_gap_days)::numeric, 1)
                                                        AS p75_gap_days,
    MAX(return_gap_days)                                AS max_gap_days
FROM customer_summary
WHERE return_order_at IS NOT NULL;

-- =====================================================================
-- Q5b. Distribution of the first-to-second-order gap, in buckets.
-- =====================================================================
WITH bucketed AS (
    SELECT
        CASE
            WHEN return_gap_days <= 7   THEN 1
            WHEN return_gap_days <= 30  THEN 2
            WHEN return_gap_days <= 90  THEN 3
            WHEN return_gap_days <= 180 THEN 4
            ELSE 5
        END                                             AS bucket_order,
        CASE
            WHEN return_gap_days <= 7   THEN '1-7 days'
            WHEN return_gap_days <= 30  THEN '8-30 days'
            WHEN return_gap_days <= 90  THEN '31-90 days'
            WHEN return_gap_days <= 180 THEN '91-180 days'
            ELSE '181+ days'
        END                                             AS gap_bucket
    FROM customer_summary
    WHERE return_order_at IS NOT NULL
)
SELECT
    gap_bucket,
    COUNT(*)                                            AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct,
    ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY bucket_order)
          / SUM(COUNT(*)) OVER (), 1)                   AS cumulative_pct
FROM bucketed
GROUP BY bucket_order, gap_bucket
ORDER BY bucket_order;

-- =====================================================================
-- Q6. Which states have the most customers and the highest revenue?
--
-- Population: delivered orders, Jan 2017 - Aug 2018 (same as Q1-Q5)
-- State:      the customer's state (customers.customer_state)
-- Revenue:    SUM(price). Freight is shown in its own columns
--             (Day 1 decision 2): shipping cost varies a lot by region.
-- =====================================================================
WITH order_totals AS (
    -- One row per order: collapse items first to avoid join fan-out
    SELECT
        order_id,
        SUM(price)::numeric          AS order_revenue,
        SUM(freight_value)::numeric  AS order_freight
    FROM order_items
    GROUP BY order_id
),
state_stats AS (
    SELECT
        c.customer_state                         AS state,
        COUNT(DISTINCT c.customer_unique_id)     AS customers,
        COUNT(*)                                 AS orders,
        SUM(t.order_revenue)                     AS revenue,
        SUM(t.order_freight)                     AS freight
    FROM orders AS o
    JOIN order_totals AS t
        ON t.order_id = o.order_id
    JOIN customers AS c
        ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
    GROUP BY c.customer_state
)
SELECT
    RANK() OVER (ORDER BY revenue DESC)                     AS revenue_rank,
    state,
    customers,
    ROUND(100.0 * customers / SUM(customers) OVER (), 2)    AS pct_of_customers,
    orders,
    ROUND(revenue, 2)                                       AS revenue,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)        AS pct_of_revenue,
    ROUND(revenue / orders, 2)                              AS aov,
    ROUND(revenue / customers, 2)                           AS revenue_per_customer,
    ROUND(freight / orders, 2)                              AS avg_freight_per_order,
    ROUND(100.0 * freight / revenue, 1)                     AS freight_pct_of_revenue
FROM state_stats
ORDER BY revenue_rank, state;

-- =====================================================================
-- Shared base for Q7-Q9: one row per delivered order with a delivery
-- date (Day 1 decision 4), Jan 2017 - Aug 2018.
--
-- Late = delivered on a LATER CALENDAR DAY than the estimated date.
-- The estimated date is stored at midnight (00:00), so comparing full
-- timestamps would mark an order delivered at 3pm on its promised day
-- as late. Casting both sides to ::date compares days, not times.
--
-- Reviews are averaged to one score per order BEFORE joining (Day 1
-- decision 6). LEFT JOIN keeps orders that have no review.
-- Timeline anomalies (decision 5) are kept, as documented on Day 1.
-- =====================================================================
CREATE OR REPLACE TEMP VIEW delivery_orders AS
WITH order_review AS (
    SELECT
        order_id,
        AVG(review_score)::numeric                      AS review_score
    FROM order_reviews
    GROUP BY order_id
)
SELECT
    o.order_id,
    c.customer_state,
    o.order_purchase_timestamp,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    o.order_delivered_customer_date::date
        - o.order_estimated_delivery_date::date         AS days_vs_estimate,
    o.order_delivered_customer_date::date
        > o.order_estimated_delivery_date::date         AS is_late,
    o.order_delivered_customer_date::date
        - o.order_purchase_timestamp::date              AS delivery_days,
    r.review_score
FROM orders AS o
JOIN customers AS c
    ON c.customer_id = o.customer_id
LEFT JOIN order_review AS r
    ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01';

-- =====================================================================
-- Q7a. What percentage of orders arrive on time vs. late compared to
--      the estimated delivery date?
-- late_pct_timestamp_method shows how much the timestamp trap would
-- overstate lateness. It is here for comparison only.
-- =====================================================================
SELECT
    COUNT(*)                                            AS orders,
    COUNT(*) FILTER (WHERE NOT is_late)                 AS on_time_orders,
    COUNT(*) FILTER (WHERE is_late)                     AS late_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE NOT is_late)
          / COUNT(*), 2)                                AS on_time_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
          / COUNT(*), 2)                                AS late_pct,
    ROUND(100.0 * COUNT(*) FILTER (
              WHERE order_delivered_customer_date > order_estimated_delivery_date)
          / COUNT(*), 2)                                AS late_pct_timestamp_method,
    ROUND(AVG(delivery_days), 1)                        AS avg_delivery_days,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_days)::numeric, 1)
                                                        AS median_delivery_days,
    ROUND(AVG(-days_vs_estimate) FILTER (WHERE NOT is_late), 1)
                                                        AS avg_days_early_if_on_time,
    ROUND(AVG(days_vs_estimate) FILTER (WHERE is_late), 1)
                                                        AS avg_days_late_if_late
FROM delivery_orders;

-- =====================================================================
-- Q7b. Late % and delivery time by purchase month.
-- Shows whether delivery got worse in busy months (e.g. Nov 2017).
-- =====================================================================
SELECT
    DATE_TRUNC('month', order_purchase_timestamp)::date AS order_month,
    COUNT(*)                                            AS orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
          / COUNT(*), 2)                                AS late_pct,
    ROUND(AVG(delivery_days), 1)                        AS avg_delivery_days
FROM delivery_orders
GROUP BY 1
ORDER BY 1;

-- =====================================================================
-- Q8a. Does late delivery lower review scores, and by how much?
-- low_score_pct = share of reviewed orders scoring 2 or below.
-- =====================================================================
SELECT
    CASE WHEN is_late THEN 'Late' ELSE 'On time' END    AS delivery_status,
    COUNT(*)                                            AS orders,
    COUNT(review_score)                                 AS reviewed_orders,
    ROUND(AVG(review_score), 2)                         AS avg_review_score,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2)
          / COUNT(review_score), 1)                     AS low_score_pct
FROM delivery_orders
GROUP BY is_late
ORDER BY is_late;

-- =====================================================================
-- Q8b. Review score by how late the order was.
-- diff_vs_on_time = this bucket's average minus the on-time average.
-- =====================================================================
WITH bucketed AS (
    SELECT
        review_score,
        CASE
            WHEN days_vs_estimate <= 0  THEN 1
            WHEN days_vs_estimate <= 3  THEN 2
            WHEN days_vs_estimate <= 7  THEN 3
            WHEN days_vs_estimate <= 14 THEN 4
            ELSE 5
        END                                             AS bucket_order,
        CASE
            WHEN days_vs_estimate <= 0  THEN 'On time or early'
            WHEN days_vs_estimate <= 3  THEN '1-3 days late'
            WHEN days_vs_estimate <= 7  THEN '4-7 days late'
            WHEN days_vs_estimate <= 14 THEN '8-14 days late'
            ELSE '15+ days late'
        END                                             AS delay_bucket
    FROM delivery_orders
)
SELECT
    delay_bucket,
    COUNT(*)                                            AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_orders,
    COUNT(review_score)                                 AS reviewed_orders,
    ROUND(AVG(review_score), 2)                         AS avg_review_score,
    ROUND(AVG(review_score)
          - FIRST_VALUE(AVG(review_score)) OVER (ORDER BY bucket_order), 2)
                                                        AS diff_vs_on_time,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2)
          / NULLIF(COUNT(review_score), 0), 1)          AS low_score_pct
FROM bucketed
GROUP BY bucket_order, delay_bucket
ORDER BY bucket_order;

-- =====================================================================
-- Q9a. Which states have the worst delivery performance?
-- State = customer's state (where the package was delivered).
-- avg_days_vs_estimate: negative = arrived that many days early.
-- =====================================================================
WITH state_delivery AS (
    SELECT
        customer_state                                  AS state,
        COUNT(*)                                        AS orders,
        ROUND(100.0 * COUNT(*) FILTER (WHERE is_late)
              / COUNT(*), 2)                            AS late_pct,
        ROUND(AVG(delivery_days), 1)                    AS avg_delivery_days,
        ROUND(AVG(days_vs_estimate), 1)                 AS avg_days_vs_estimate,
        ROUND(AVG(review_score), 2)                     AS avg_review_score
    FROM delivery_orders
    GROUP BY customer_state
)
SELECT
    RANK() OVER (ORDER BY late_pct DESC)                AS late_rank,
    state,
    orders,
    late_pct,
    avg_delivery_days,
    avg_days_vs_estimate,
    avg_review_score
FROM state_delivery
ORDER BY late_rank, state;

-- =====================================================================
-- Q9b. Which sellers have the worst delivery performance?
-- Sellers with at least 50 delivered orders only, so tiny samples
-- (e.g. 1 late out of 2) don't top the list. Top 15 by late %.
--
-- late_pct:         customer got the order after the estimated date.
--                   An order with 2 sellers counts for both.
-- late_handoff_pct: the seller gave the order to the carrier after its
--                   shipping_limit_date. This is the part of lateness
--                   that is clearly the seller's fault.
-- =====================================================================
WITH seller_orders AS (
    -- One row per (seller, order): one order can include several sellers
    SELECT
        seller_id,
        order_id,
        MAX(shipping_limit_date)                        AS shipping_limit_date
    FROM order_items
    GROUP BY seller_id, order_id
),
seller_delivery AS (
    SELECT
        so.seller_id,
        s.seller_state,
        COUNT(*)                                        AS orders,
        COUNT(*) FILTER (WHERE d.is_late)               AS late_orders,
        ROUND(100.0 * COUNT(*) FILTER (WHERE d.is_late)
              / COUNT(*), 1)                            AS late_pct,
        ROUND(100.0 * COUNT(*) FILTER (
                  WHERE d.order_delivered_carrier_date > so.shipping_limit_date)
              / COUNT(*), 1)                            AS late_handoff_pct,
        ROUND(AVG(d.delivery_days), 1)                  AS avg_delivery_days,
        ROUND(AVG(d.review_score), 2)                   AS avg_review_score
    FROM seller_orders AS so
    JOIN delivery_orders AS d
        ON d.order_id = so.order_id
    JOIN sellers AS s
        ON s.seller_id = so.seller_id
    GROUP BY so.seller_id, s.seller_state
    HAVING COUNT(*) >= 50
)
SELECT
    RANK() OVER (ORDER BY late_pct DESC)                AS late_rank,
    COUNT(*) OVER ()                                    AS qualifying_sellers,
    seller_id,
    seller_state,
    orders,
    late_orders,
    late_pct,
    late_handoff_pct,
    avg_delivery_days,
    avg_review_score
FROM seller_delivery
ORDER BY late_rank, seller_id
LIMIT 15;

-- =====================================================================
-- Shared base for Q10: revenue per seller, ranked.
-- Population: delivered orders, Jan 2017 - Aug 2018.
-- Revenue: SUM(price) of the seller's items (freight excluded).
-- =====================================================================
CREATE OR REPLACE TEMP VIEW seller_revenue AS
WITH per_seller AS (
    SELECT
        oi.seller_id,
        SUM(oi.price)::numeric                          AS revenue,
        COUNT(DISTINCT oi.order_id)                     AS orders,
        COUNT(*)                                        AS items_sold
    FROM order_items AS oi
    JOIN orders AS o
        ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
    GROUP BY oi.seller_id
)
SELECT
    p.seller_id,
    s.seller_state,
    p.revenue,
    p.orders,
    p.items_sold,
    RANK() OVER (ORDER BY p.revenue DESC)               AS revenue_rank,
    NTILE(10) OVER (ORDER BY p.revenue DESC)            AS revenue_decile,
    100.0 * p.revenue / SUM(p.revenue) OVER ()          AS pct_of_revenue,
    100.0 * SUM(p.revenue) OVER (
                ORDER BY p.revenue DESC, p.seller_id
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(p.revenue) OVER ()                      AS cumulative_pct
FROM per_seller AS p
JOIN sellers AS s
    ON s.seller_id = p.seller_id;

-- =====================================================================
-- Q10a. Who are the top 10 sellers by revenue?
-- =====================================================================
SELECT
    revenue_rank,
    seller_id,
    seller_state,
    ROUND(revenue, 2)                                   AS revenue,
    orders,
    ROUND(revenue / orders, 2)                          AS revenue_per_order,
    ROUND(pct_of_revenue, 2)                            AS pct_of_revenue,
    ROUND(cumulative_pct, 2)                            AS cumulative_pct
FROM seller_revenue
WHERE revenue_rank <= 10
ORDER BY revenue_rank;

-- =====================================================================
-- Q10b. How concentrated is revenue among sellers?
-- top_10pct_sellers: NTILE(10) splits sellers into 10 equal-sized
-- groups by revenue; decile 1 is the top 10% of sellers.
-- sellers_for_80pct: how many sellers it takes to reach 80% of revenue.
-- =====================================================================
SELECT
    COUNT(*)                                            AS sellers,
    ROUND(SUM(revenue), 2)                              AS total_revenue,
    ROUND(SUM(pct_of_revenue) FILTER (WHERE revenue_rank <= 10), 2)
                                                        AS top_10_sellers_pct,
    ROUND(SUM(pct_of_revenue) FILTER (WHERE revenue_decile = 1), 2)
                                                        AS top_10pct_sellers_pct,
    COUNT(*) FILTER (WHERE cumulative_pct - pct_of_revenue < 80)
                                                        AS sellers_for_80pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE cumulative_pct - pct_of_revenue < 80)
          / COUNT(*), 1)                                AS sellers_for_80pct_share,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY revenue)::numeric, 2)
                                                        AS median_seller_revenue
FROM seller_revenue;

-- =====================================================================
-- Q11a. What payment methods do customers use?
-- Population: delivered orders, Jan 2017 - Aug 2018. The 1 delivered
-- order with no payment record is simply absent (Day 1 decision 10).
-- One order can use more than one method (e.g. voucher + card), so
-- pct_of_orders adds up to more than 100%.
-- Payment values include freight, so they don't match item revenue.
-- "not_defined" is shown as "Unknown" (Day 1 decision 8).
-- =====================================================================
WITH payments AS (
    SELECT
        p.order_id,
        CASE p.payment_type
            WHEN 'not_defined' THEN 'Unknown'
            ELSE p.payment_type
        END                                             AS payment_type,
        p.payment_value
    FROM order_payments AS p
    JOIN orders AS o
        ON o.order_id = p.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
)
SELECT
    payment_type,
    COUNT(DISTINCT order_id)                            AS orders_using,
    ROUND(100.0 * COUNT(DISTINCT order_id)
          / (SELECT COUNT(DISTINCT order_id) FROM payments), 2)
                                                        AS pct_of_orders,
    ROUND(SUM(payment_value)::numeric, 2)               AS payment_value,
    ROUND(100.0 * SUM(payment_value)::numeric
          / SUM(SUM(payment_value)::numeric) OVER (), 2)
                                                        AS pct_of_value,
    ROUND(AVG(payment_value)::numeric, 2)               AS avg_payment
FROM payments
GROUP BY payment_type
ORDER BY orders_using DESC;

-- =====================================================================
-- Shared base for Q11b/Q11c: one row per order paid by credit card.
-- Installments only exist for credit cards.
-- order_value = total paid for the order across all methods.
-- =====================================================================
CREATE OR REPLACE TEMP VIEW card_orders AS
SELECT
    p.order_id,
    MAX(p.payment_installments) FILTER (WHERE p.payment_type = 'credit_card')
                                                        AS installments,
    SUM(p.payment_value)::numeric                       AS order_value
FROM order_payments AS p
JOIN orders AS o
    ON o.order_id = p.order_id
WHERE o.order_status = 'delivered'
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01'
GROUP BY p.order_id
HAVING COUNT(*) FILTER (WHERE p.payment_type = 'credit_card') > 0;

-- =====================================================================
-- Q11b. How do installments relate to order value?
-- =====================================================================
WITH bucketed AS (
    SELECT
        order_value,
        CASE
            WHEN installments <= 1  THEN 1
            WHEN installments <= 3  THEN 2
            WHEN installments <= 6  THEN 3
            WHEN installments <= 9  THEN 4
            ELSE 5
        END                                             AS bucket_order,
        CASE
            WHEN installments <= 1  THEN '1 (paid in full)'
            WHEN installments <= 3  THEN '2-3'
            WHEN installments <= 6  THEN '4-6'
            WHEN installments <= 9  THEN '7-9'
            ELSE '10+'
        END                                             AS installment_bucket
    FROM card_orders
)
SELECT
    installment_bucket,
    COUNT(*)                                            AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_card_orders,
    ROUND(AVG(order_value), 2)                          AS avg_order_value,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY order_value)::numeric, 2)
                                                        AS median_order_value
FROM bucketed
GROUP BY bucket_order, installment_bucket
ORDER BY bucket_order;

-- =====================================================================
-- Q11c. Summary: average installments and the correlation between
-- installments and order value (1 = perfect positive, 0 = none).
-- =====================================================================
SELECT
    COUNT(*)                                            AS card_orders,
    ROUND(AVG(installments), 2)                         AS avg_installments,
    ROUND(100.0 * COUNT(*) FILTER (WHERE installments > 1)
          / COUNT(*), 2)                                AS pct_using_installments,
    ROUND(CORR(installments, order_value)::numeric, 3)  AS corr_installments_value
FROM card_orders;

-- =====================================================================
-- Q12. Which categories have the lowest average review scores?
-- Uses the delivery_orders view (one review score per order, already
-- averaged; 8 orders without a delivery date are not in it).
-- An order with items in 2 categories counts once for each category.
-- Only categories with at least 100 reviewed orders, so small ones
-- don't dominate. late_pct shows whether delivery explains the score.
-- =====================================================================
WITH order_categories AS (
    -- One row per (order, category)
    SELECT DISTINCT
        oi.order_id,
        COALESCE(
            t.product_category_name_english,
            CASE p.product_category_name
                WHEN 'portateis_cozinha_e_preparadores_de_alimentos'
                    THEN 'portable_kitchen_food_preparers'
                WHEN 'pc_gamer'
                    THEN 'pc_gamer'
            END,
            'uncategorized'
        )                                               AS category
    FROM order_items AS oi
    JOIN products AS p
        ON p.product_id = oi.product_id
    LEFT JOIN category_translation AS t
        ON t.product_category_name = p.product_category_name
),
category_reviews AS (
    SELECT
        oc.category,
        COUNT(*)                                        AS reviewed_orders,
        AVG(d.review_score)                             AS avg_review,
        100.0 * COUNT(*) FILTER (WHERE d.review_score <= 2)
              / COUNT(*)                                AS low_score_pct,
        100.0 * COUNT(*) FILTER (WHERE d.is_late)
              / COUNT(*)                                AS late_pct
    FROM order_categories AS oc
    JOIN delivery_orders AS d
        ON d.order_id = oc.order_id
    WHERE d.review_score IS NOT NULL
    GROUP BY oc.category
    HAVING COUNT(*) >= 100
)
SELECT
    RANK() OVER (ORDER BY avg_review)                   AS lowest_rank,
    COUNT(*) OVER ()                                    AS qualifying_categories,
    category,
    reviewed_orders,
    ROUND(avg_review, 2)                                AS avg_review_score,
    ROUND(avg_review - (SELECT AVG(review_score) FROM delivery_orders), 2)
                                                        AS diff_vs_overall,
    ROUND(low_score_pct, 1)                             AS low_score_pct,
    ROUND(late_pct, 1)                                  AS late_pct
FROM category_reviews
ORDER BY lowest_rank, category
LIMIT 15;

-- =====================================================================
-- KPI SUMMARY for the dashboard cards (one row, five KPIs).
--
-- Population: delivered orders, Jan 2017 - Aug 2018, the same as
-- Q1-Q12, so every card reconciles to the analysis results.
--   total_revenue     SUM(order_items.price), freight excluded
--   total_orders      delivered orders in the window
--   aov               total_revenue / total_orders
--   on_time_pct       delivered on or before the estimated DATE, out of
--                     orders that have a delivery date
--   avg_review_score  average of per-order scores (each order's reviews
--                     averaged first), out of orders with a review
-- Self-contained (no temp views) so it can be reused in the export
-- script on its own.
-- =====================================================================
WITH window_orders AS (
    SELECT
        order_id,
        order_delivered_customer_date,
        order_estimated_delivery_date
    FROM orders
    WHERE order_status = 'delivered'
      AND order_purchase_timestamp >= '2017-01-01'
      AND order_purchase_timestamp <  '2018-09-01'
),
order_revenue AS (
    -- One row per order
    SELECT
        order_id,
        SUM(price)::numeric                             AS revenue
    FROM order_items
    GROUP BY order_id
),
order_review AS (
    -- One row per order
    SELECT
        order_id,
        AVG(review_score)::numeric                      AS review_score
    FROM order_reviews
    GROUP BY order_id
)
SELECT
    ROUND(SUM(rv.revenue), 2)                           AS total_revenue,
    COUNT(*)                                            AS total_orders,
    ROUND(SUM(rv.revenue) / COUNT(*), 2)                AS aov,
    ROUND(100.0 * COUNT(*) FILTER (
              WHERE w.order_delivered_customer_date::date
                 <= w.order_estimated_delivery_date::date)
          / COUNT(w.order_delivered_customer_date), 2)  AS on_time_pct,
    ROUND(AVG(rw.review_score), 2)                      AS avg_review_score,
    COUNT(w.order_delivered_customer_date)              AS orders_with_delivery_date,
    COUNT(rw.review_score)                              AS reviewed_orders
FROM window_orders AS w
LEFT JOIN order_revenue AS rv
    ON rv.order_id = w.order_id
LEFT JOIN order_review AS rw
    ON rw.order_id = w.order_id;