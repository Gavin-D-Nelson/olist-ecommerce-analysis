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