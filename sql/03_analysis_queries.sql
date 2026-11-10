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