-- =====================================================================
-- 04_dashboard_exports.sql
-- Exports the 5 CSV files the Tableau Public dashboard is built from.
-- Tableau Public can't connect to PostgreSQL, so each dashboard element
-- gets one small, pre-aggregated CSV. The numbers come straight from
-- SQL and match the results in 03_analysis_queries.sql.
--
-- Run from the repo root:  psql -d olist -f sql/04_dashboard_exports.sql
-- Output folder: data/exports/ (inside data/, so it is git-ignored)
--
-- Population everywhere: delivered orders, Jan 2017 - Aug 2018.
--
-- psql rules used here:
--   * \copy must be on ONE line, with no comment on that line.
--   * Each export query is saved as a TEMP VIEW first, so the \copy
--     line stays short: \copy (SELECT * FROM view) TO 'file' ...
--   * \! runs a shell command; mkdir -p creates the folder if needed.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
\! mkdir -p data/exports

-- ---------------------------------------------------------------------
-- Shared base: one row per in-scope order, with revenue, freight,
-- delivery result and review score. Every export below builds on it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW export_orders AS
WITH order_totals AS (
    SELECT
        order_id,
        SUM(price)::numeric                             AS revenue,
        SUM(freight_value)::numeric                     AS freight
    FROM order_items
    GROUP BY order_id
),
order_review AS (
    SELECT
        order_id,
        AVG(review_score)::numeric                      AS review_score
    FROM order_reviews
    GROUP BY order_id
)
SELECT
    o.order_id,
    c.customer_unique_id,
    c.customer_state,
    DATE_TRUNC('month', o.order_purchase_timestamp)::date AS order_month,
    t.revenue,
    t.freight,
    o.order_delivered_customer_date IS NOT NULL         AS has_delivery_date,
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
LEFT JOIN order_totals AS t
    ON t.order_id = o.order_id
LEFT JOIN order_review AS r
    ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01';

-- ---------------------------------------------------------------------
-- Export 1: kpi_summary.csv (1 row) -> the 5 KPI cards
-- on_time_pct uses only orders with a delivery date (Day 1 decision 4);
-- avg_review_score uses only orders with a review.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW export_kpi_summary AS
SELECT
    ROUND(SUM(revenue), 2)                              AS total_revenue,
    COUNT(*)                                            AS total_orders,
    ROUND(SUM(revenue) / COUNT(*), 2)                   AS aov,
    ROUND(100.0 * COUNT(*) FILTER (WHERE has_delivery_date AND NOT is_late)
          / NULLIF(COUNT(*) FILTER (WHERE has_delivery_date), 0), 2)
                                                        AS on_time_pct,
    ROUND(AVG(review_score), 2)                         AS avg_review_score
FROM export_orders;

\copy (SELECT * FROM export_kpi_summary) TO 'data/exports/kpi_summary.csv' WITH (FORMAT csv, HEADER)

-- ---------------------------------------------------------------------
-- Export 2: monthly_trend.csv (20 rows) -> monthly revenue trend
-- Q1/Q2 columns plus the monthly late % from Q7b, so the trend chart
-- can show sales and delivery problems on the same timeline.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW export_monthly_trend AS
WITH monthly AS (
    SELECT
        order_month,
        SUM(revenue)                                    AS revenue,
        COUNT(*)                                        AS orders,
        COUNT(*) FILTER (WHERE has_delivery_date AND is_late) AS late_orders,
        COUNT(*) FILTER (WHERE has_delivery_date)       AS orders_with_delivery_date
    FROM export_orders
    GROUP BY order_month
)
SELECT
    order_month,
    ROUND(revenue, 2)                                   AS revenue,
    orders,
    ROUND(revenue / orders, 2)                          AS aov,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY order_month))
          / NULLIF(LAG(revenue) OVER (ORDER BY order_month), 0), 1)
                                                        AS mom_growth_pct,
    ROUND(100.0 * late_orders / NULLIF(orders_with_delivery_date, 0), 2)
                                                        AS late_pct
FROM monthly;

\copy (SELECT * FROM export_monthly_trend ORDER BY order_month) TO 'data/exports/monthly_trend.csv' WITH (FORMAT csv, HEADER)

-- ---------------------------------------------------------------------
-- Export 3: revenue_by_category.csv (74 rows) -> revenue by category
-- Same logic as Q3, plus display_category: the top 10 keep their name
-- and the rest become 'All other', so Tableau can show 11 bars.
-- Category labels stay as raw source names; tidy them in Tableau.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW export_revenue_by_category AS
WITH category_sales AS (
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
        )                                               AS category,
        SUM(oi.price)::numeric                          AS revenue,
        COUNT(*)                                        AS items_sold,
        COUNT(DISTINCT oi.order_id)                     AS orders
    FROM order_items AS oi
    JOIN export_orders AS e
        ON e.order_id = oi.order_id
    JOIN products AS p
        ON p.product_id = oi.product_id
    LEFT JOIN category_translation AS t
        ON t.product_category_name = p.product_category_name
    GROUP BY 1
),
ranked AS (
    SELECT
        category,
        revenue,
        items_sold,
        orders,
        RANK() OVER (ORDER BY revenue DESC)             AS revenue_rank
    FROM category_sales
)
SELECT
    revenue_rank,
    category,
    CASE WHEN revenue_rank <= 10 THEN category ELSE 'All other' END
                                                        AS display_category,
    ROUND(revenue, 2)                                   AS revenue,
    items_sold,
    orders,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)    AS pct_of_revenue
FROM ranked;

\copy (SELECT * FROM export_revenue_by_category ORDER BY revenue_rank, category) TO 'data/exports/revenue_by_category.csv' WITH (FORMAT csv, HEADER)

-- ---------------------------------------------------------------------
-- Export 4: delivery_vs_review.csv (5 rows) -> late delivery vs. review
-- Same buckets as Q8b. bucket_order keeps the bars in order in Tableau.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW export_delivery_vs_review AS
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
    FROM export_orders
    WHERE has_delivery_date
)
SELECT
    bucket_order,
    delay_bucket,
    COUNT(*)                                            AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_orders,
    COUNT(review_score)                                 AS reviewed_orders,
    ROUND(AVG(review_score), 2)                         AS avg_review_score,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2)
          / NULLIF(COUNT(review_score), 0), 1)          AS low_score_pct
FROM bucketed
GROUP BY bucket_order, delay_bucket;

\copy (SELECT * FROM export_delivery_vs_review ORDER BY bucket_order) TO 'data/exports/delivery_vs_review.csv' WITH (FORMAT csv, HEADER)

-- ---------------------------------------------------------------------
-- Export 5: state_performance.csv (27 rows) -> performance by state
-- Q6 (customers, revenue, AOV, freight) and Q9a (late %, delivery days,
-- review) in one table, plus the full state name (for Tableau's map)
-- and Brazil's 5 official regions (IBGE) for grouping.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW export_state_performance AS
WITH state_info (state, state_name, region) AS (
    VALUES
        ('AC', 'Acre',                'North'),
        ('AP', 'Amapá',               'North'),
        ('AM', 'Amazonas',            'North'),
        ('PA', 'Pará',                'North'),
        ('RO', 'Rondônia',            'North'),
        ('RR', 'Roraima',             'North'),
        ('TO', 'Tocantins',           'North'),
        ('AL', 'Alagoas',             'Northeast'),
        ('BA', 'Bahia',               'Northeast'),
        ('CE', 'Ceará',               'Northeast'),
        ('MA', 'Maranhão',            'Northeast'),
        ('PB', 'Paraíba',             'Northeast'),
        ('PE', 'Pernambuco',          'Northeast'),
        ('PI', 'Piauí',               'Northeast'),
        ('RN', 'Rio Grande do Norte', 'Northeast'),
        ('SE', 'Sergipe',             'Northeast'),
        ('DF', 'Distrito Federal',    'Center-West'),
        ('GO', 'Goiás',               'Center-West'),
        ('MT', 'Mato Grosso',         'Center-West'),
        ('MS', 'Mato Grosso do Sul',  'Center-West'),
        ('ES', 'Espírito Santo',      'Southeast'),
        ('MG', 'Minas Gerais',        'Southeast'),
        ('RJ', 'Rio de Janeiro',      'Southeast'),
        ('SP', 'São Paulo',           'Southeast'),
        ('PR', 'Paraná',              'South'),
        ('RS', 'Rio Grande do Sul',   'South'),
        ('SC', 'Santa Catarina',      'South')
),
state_stats AS (
    SELECT
        customer_state                                  AS state,
        COUNT(DISTINCT customer_unique_id)              AS customers,
        COUNT(*)                                        AS orders,
        SUM(revenue)                                    AS revenue,
        SUM(freight)                                    AS freight,
        COUNT(*) FILTER (WHERE has_delivery_date AND is_late) AS late_orders,
        COUNT(*) FILTER (WHERE has_delivery_date)       AS orders_with_delivery_date,
        AVG(delivery_days)                              AS avg_delivery_days,
        AVG(review_score)                               AS avg_review_score
    FROM export_orders
    GROUP BY customer_state
)
SELECT
    s.state,
    i.state_name,
    i.region,
    s.customers,
    s.orders,
    ROUND(s.revenue, 2)                                 AS revenue,
    ROUND(100.0 * s.revenue / SUM(s.revenue) OVER (), 2) AS pct_of_revenue,
    ROUND(s.revenue / s.orders, 2)                      AS aov,
    ROUND(100.0 * s.freight / s.revenue, 1)             AS freight_pct_of_revenue,
    ROUND(100.0 * s.late_orders / NULLIF(s.orders_with_delivery_date, 0), 2)
                                                        AS late_pct,
    ROUND(s.avg_delivery_days, 1)                       AS avg_delivery_days,
    ROUND(s.avg_review_score, 2)                        AS avg_review_score
FROM state_stats AS s
LEFT JOIN state_info AS i
    ON i.state = s.state;

\copy (SELECT * FROM export_state_performance ORDER BY revenue DESC) TO 'data/exports/state_performance.csv' WITH (FORMAT csv, HEADER)
