/* =====================================================================
   01_schema_and_load.sql
   Olist E-Commerce Analysis: schema creation and raw data load
   Author: Gavin Nelson

   Purpose
     Create one table per Olist CSV with deliberate data types, load the
     raw files, then add keys, relationships, and indexes.

   How to run (from the REPO ROOT in Terminal, not from DBeaver):
       psql -d olist -f sql/01_schema_and_load.sql

   Why psql and \copy:
     \copy is a psql client command. It reads the CSV on this machine and
     streams it to the server, so it needs no superuser rights or server
     file access (unlike server-side COPY). Relative paths like data/...
     resolve from the folder you run psql in, so run it from the repo root.

   Re-runnable: the script drops and recreates every table, so running it
   twice gives the same result.
   ===================================================================== */

   -- Stop at the first error instead of continuing with half-loaded data.
\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';  -- city and category names contain Portuguese accents

BEGIN;  -- all-or-nothing: if any step fails, nothing is committed

DROP TABLE IF EXISTS order_reviews, order_payments, order_items, orders,
                     customers, products, sellers, geolocation,
                     category_translation CASCADE;


/* ---------------------------------------------------------------------
   1. CREATE TABLES
   Column order matches the CSV column order exactly, because \copy maps
   CSV columns to table columns by position.
   --------------------------------------------------------------------- */

-- customers: one row per customer_id.
-- customer_id is generated per ORDER; customer_unique_id is the real person.
-- Any repeat-purchase or retention metric must use customer_unique_id.
CREATE TABLE customers (
    customer_id               TEXT PRIMARY KEY,
    customer_unique_id        TEXT NOT NULL,
    customer_zip_code_prefix  TEXT,      -- TEXT, not INTEGER: zip codes are labels, never summed, and leading zeros matter
    customer_city             TEXT,
    customer_state            CHAR(2)    -- two-letter Brazilian state code (SP, RJ, ...)
);

-- orders: one row per order. Delivery dates are nullable on purpose:
-- canceled, unavailable, or in-transit orders never get those timestamps.
CREATE TABLE orders (
    order_id                       TEXT PRIMARY KEY,
    customer_id                    TEXT NOT NULL,
    order_status                   TEXT NOT NULL,
    order_purchase_timestamp       TIMESTAMP NOT NULL,
    order_approved_at              TIMESTAMP,
    order_delivered_carrier_date   TIMESTAMP,
    order_delivered_customer_date  TIMESTAMP,
    order_estimated_delivery_date  TIMESTAMP
);

-- order_items: GRAIN = one row per unit sold, not per product line.
-- An order with 2 units of the same product has 2 rows (order_item_id 1 and 2).
-- So item revenue is SUM(price), never price * quantity.
CREATE TABLE order_items (
    order_id             TEXT NOT NULL,
    order_item_id        SMALLINT NOT NULL,  -- position of the unit within the order: 1, 2, 3...
    product_id           TEXT NOT NULL,
    seller_id            TEXT NOT NULL,
    shipping_limit_date  TIMESTAMP,
    price                NUMERIC(10,2),      -- NUMERIC, not FLOAT: exact decimal math for money
    freight_value        NUMERIC(10,2),
    PRIMARY KEY (order_id, order_item_id)    -- composite key: neither column is unique on its own
);

-- order_payments: one row per payment record. An order can be split across
-- several payments (e.g., a voucher plus a credit card).
CREATE TABLE order_payments (
    order_id              TEXT NOT NULL,
    payment_sequential    SMALLINT NOT NULL,
    payment_type          TEXT,
    payment_installments  SMALLINT,
    payment_value         NUMERIC(10,2),
    PRIMARY KEY (order_id, payment_sequential)
);

-- order_reviews: deliberately NO primary key.
-- The dataset is known to contain repeated review_ids and orders with more
-- than one review. A PK here would reject rows during load and hide the
-- problem; instead we load everything and measure it in 02_data_quality_checks.sql.
CREATE TABLE order_reviews (
    review_id                TEXT NOT NULL,
    order_id                 TEXT NOT NULL,
    review_score             SMALLINT,
    review_comment_title     TEXT,
    review_comment_message   TEXT,      -- free text; can contain line breaks inside quotes
    review_creation_date     TIMESTAMP,
    review_answer_timestamp  TIMESTAMP
);

-- products: the source header misspells "length" as "lenght".
-- Because \copy loads by position, we can fix the names here without editing the CSV.
CREATE TABLE products (
    product_id                  TEXT PRIMARY KEY,
    product_category_name       TEXT,       -- Portuguese; join category_translation for English
    product_name_length         INTEGER,
    product_description_length  INTEGER,
    product_photos_qty          INTEGER,
    product_weight_g            INTEGER,
    product_length_cm           INTEGER,
    product_height_cm           INTEGER,
    product_width_cm            INTEGER
);

CREATE TABLE sellers (
    seller_id               TEXT PRIMARY KEY,
    seller_zip_code_prefix  TEXT,
    seller_city             TEXT,
    seller_state            CHAR(2)
);

-- geolocation: deliberately NO primary key.
-- Many rows share the same zip prefix (several coordinates per prefix),
-- so zip prefix is not a unique identifier.
CREATE TABLE geolocation (
    geolocation_zip_code_prefix  TEXT,
    geolocation_lat              DOUBLE PRECISION,  -- coordinates are measurements, so floating point is fine
    geolocation_lng              DOUBLE PRECISION,
    geolocation_city             TEXT,
    geolocation_state            CHAR(2)
);

CREATE TABLE category_translation (
    product_category_name          TEXT PRIMARY KEY,
    product_category_name_english  TEXT NOT NULL
);


/* ---------------------------------------------------------------------
   2. LOAD RAW CSVs
   FORMAT csv handles quoted fields (including commas and line breaks
   inside review comments). Empty unquoted fields load as NULL.
   Each \copy must stay on a single line.
   --------------------------------------------------------------------- */

\copy customers            FROM 'data/olist_customers_dataset.csv'         WITH (FORMAT csv, HEADER true)
\copy sellers              FROM 'data/olist_sellers_dataset.csv'           WITH (FORMAT csv, HEADER true)
\copy products             FROM 'data/olist_products_dataset.csv'          WITH (FORMAT csv, HEADER true)
\copy category_translation FROM 'data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true)
\copy geolocation          FROM 'data/olist_geolocation_dataset.csv'       WITH (FORMAT csv, HEADER true)
\copy orders               FROM 'data/olist_orders_dataset.csv'            WITH (FORMAT csv, HEADER true)
\copy order_items          FROM 'data/olist_order_items_dataset.csv'       WITH (FORMAT csv, HEADER true)
\copy order_payments       FROM 'data/olist_order_payments_dataset.csv'    WITH (FORMAT csv, HEADER true)
\copy order_reviews        FROM 'data/olist_order_reviews_dataset.csv'     WITH (FORMAT csv, HEADER true)


/* ---------------------------------------------------------------------
   3. RELATIONSHIPS (foreign keys)
   Added AFTER the load: bulk loading is faster without them, and if one
   fails, the error names the exact broken relationship.

   Intentionally NOT enforced:
     - products -> category_translation: some categories may have no
       English translation; we check this in 02, not block the load.
     - anything -> geolocation: zip prefix is not unique there.
   --------------------------------------------------------------------- */

ALTER TABLE orders         ADD CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id);
ALTER TABLE order_items    ADD CONSTRAINT fk_items_order     FOREIGN KEY (order_id)    REFERENCES orders (order_id);
ALTER TABLE order_items    ADD CONSTRAINT fk_items_product   FOREIGN KEY (product_id)  REFERENCES products (product_id);
ALTER TABLE order_items    ADD CONSTRAINT fk_items_seller    FOREIGN KEY (seller_id)   REFERENCES sellers (seller_id);
ALTER TABLE order_payments ADD CONSTRAINT fk_payments_order  FOREIGN KEY (order_id)    REFERENCES orders (order_id);
ALTER TABLE order_reviews  ADD CONSTRAINT fk_reviews_order   FOREIGN KEY (order_id)    REFERENCES orders (order_id);


/* ---------------------------------------------------------------------
   4. INDEXES on common join/filter columns
   Primary keys are indexed automatically; foreign key columns are not.
   (order_items.order_id and order_payments.order_id are already covered
   because they are the first column of their composite primary keys.)
   --------------------------------------------------------------------- */

CREATE INDEX idx_orders_customer    ON orders (customer_id);
CREATE INDEX idx_orders_purchase_ts ON orders (order_purchase_timestamp);
CREATE INDEX idx_items_product      ON order_items (product_id);
CREATE INDEX idx_items_seller       ON order_items (seller_id);
CREATE INDEX idx_reviews_order      ON order_reviews (order_id);
CREATE INDEX idx_customers_unique   ON customers (customer_unique_id);

COMMIT;

ANALYZE;  -- refresh table statistics so the query planner makes good choices


/* ---------------------------------------------------------------------
   5. LOAD VERIFICATION: row counts per table
   Compare against the source files before moving on.
   --------------------------------------------------------------------- */

SELECT 'category_translation' AS table_name, COUNT(*) AS row_count FROM category_translation
UNION ALL SELECT 'customers',      COUNT(*) FROM customers
UNION ALL SELECT 'geolocation',    COUNT(*) FROM geolocation
UNION ALL SELECT 'order_items',    COUNT(*) FROM order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM order_payments
UNION ALL SELECT 'order_reviews',  COUNT(*) FROM order_reviews
UNION ALL SELECT 'orders',         COUNT(*) FROM orders
UNION ALL SELECT 'products',       COUNT(*) FROM products
UNION ALL SELECT 'sellers',        COUNT(*) FROM sellers
ORDER BY table_name;
