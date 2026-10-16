-- Фикстура для проверки pgcollect: разнообразные объекты в одной БД `shop`.

CREATE DATABASE shop;
\connect shop

CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Схемы
CREATE SCHEMA sales;
CREATE SCHEMA analytics;

-- Роли и группы
CREATE ROLE app_read NOLOGIN;
CREATE ROLE app_write NOLOGIN;
CREATE ROLE alice LOGIN PASSWORD 'x';
CREATE ROLE bob LOGIN PASSWORD 'x';
GRANT app_read TO alice;
GRANT app_read, app_write TO bob;

-- Обычная таблица с PK, FK, индексами, ограничениями
CREATE TABLE sales.customers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    name        text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT email_lower CHECK (email = lower(email))
);

CREATE TABLE sales.orders (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint NOT NULL REFERENCES sales.customers(id),
    total        numeric(12,2) NOT NULL DEFAULT 0,
    status       text NOT NULL DEFAULT 'new'
);
-- FK sales.orders.customer_id НАМЕРЕННО без индекса (проверка fk_without_index)

-- Ручной stat target на колонке (проверка custom_stats_columns)
ALTER TABLE sales.customers ALTER COLUMN email SET STATISTICS 500;

CREATE INDEX idx_customers_name ON sales.customers(name);
CREATE INDEX idx_customers_name_dup ON sales.customers(name);   -- дубликат
CREATE INDEX idx_orders_status_unused ON sales.orders(status);  -- останется unused

-- Партиционированная таблица (RANGE по дате)
CREATE TABLE analytics.events (
    id        bigint,
    ts        date NOT NULL,
    payload   text
) PARTITION BY RANGE (ts);
CREATE TABLE analytics.events_2024 PARTITION OF analytics.events
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE analytics.events_2025 PARTITION OF analytics.events
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

-- Таблица без PK (проверка tables_without_pk)
CREATE TABLE analytics.raw_log (line text);

-- Гранты на объекты
GRANT SELECT ON ALL TABLES IN SCHEMA sales TO app_read;
GRANT INSERT, UPDATE ON sales.orders TO app_write;

-- Публикации логической репликации (проверка раздела «Публикации»)
CREATE PUBLICATION pub_sales FOR TABLE sales.customers, sales.orders;
CREATE PUBLICATION pub_orders_iud FOR TABLE sales.orders
    WITH (publish = 'insert, update, delete');
-- Список колонок + фильтр строк (проверка колонок в разделе публикаций, PG15+)
CREATE PUBLICATION pub_cust_cols FOR TABLE sales.customers (id, email) WHERE (id > 0);
-- Партиционированная таблица с publish_via_partition_root = false
-- (состав раскрывается до листовых партиций events_2024/events_2025)
CREATE PUBLICATION pub_events_leaf FOR TABLE analytics.events
    WITH (publish_via_partition_root = false);

-- Наполнение и искусственный bloat
INSERT INTO sales.customers(email, name)
SELECT 'user' || g || '@example.com', 'User ' || g
FROM generate_series(1, 20000) g;

INSERT INTO sales.orders(customer_id, total, status)
SELECT (random()*19999 + 1)::bigint, (random()*1000)::numeric(12,2), 'new'
FROM generate_series(1, 40000);

INSERT INTO analytics.events(id, ts, payload)
SELECT g, DATE '2024-01-01' + (g % 700), repeat('x', 100)
FROM generate_series(1, 30000) g;

-- Создаём распухание: массовые UPDATE/DELETE без последующего VACUUM
UPDATE sales.customers SET name = name || '_v2';
UPDATE sales.customers SET name = name || '_v3';
DELETE FROM sales.orders WHERE id % 3 = 0;
UPDATE sales.orders SET total = total + 1 WHERE id % 2 = 0;

-- Свежая статистика есть не у всех: analyze только части таблиц
ANALYZE sales.customers;
ANALYZE analytics.events;
-- sales.orders и analytics.raw_log НАМЕРЕННО без ANALYZE

-- Триггеры (проверка раздела «Триггеры»): один включённый ROW BEFORE,
-- один выключенный STATEMENT AFTER.
CREATE FUNCTION sales.touch_order() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RETURN NEW; END; $$;
CREATE FUNCTION sales.audit_noop() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RETURN NULL; END; $$;

CREATE TRIGGER trg_orders_touch BEFORE UPDATE ON sales.orders
    FOR EACH ROW EXECUTE FUNCTION sales.touch_order();
CREATE TRIGGER trg_orders_audit AFTER INSERT OR DELETE ON sales.orders
    FOR EACH STATEMENT EXECUTE FUNCTION sales.audit_noop();
ALTER TABLE sales.orders DISABLE TRIGGER trg_orders_audit;

-- Прочие объекты и безопасность (проверка новых разделов) --------------------

-- Комментарии
COMMENT ON TABLE sales.customers IS 'Клиенты магазина';
COMMENT ON COLUMN sales.customers.email IS 'Уникальный email (нижний регистр)';

-- Пользовательские типы
CREATE TYPE sales.order_status AS ENUM ('new', 'paid', 'shipped', 'cancelled');
CREATE DOMAIN sales.positive_amount AS numeric(12,2) CHECK (VALUE >= 0);

-- Представления
CREATE VIEW sales.active_orders AS
    SELECT * FROM sales.orders WHERE status = 'new';
CREATE MATERIALIZED VIEW sales.customer_order_counts AS
    SELECT customer_id, count(*) AS orders FROM sales.orders GROUP BY customer_id;

-- SECURITY DEFINER функция (попадёт в «Сводку проблем»)
CREATE FUNCTION sales.current_customer_id() RETURNS bigint
    LANGUAGE sql SECURITY DEFINER AS $$ SELECT 1::bigint $$;

-- RLS-политика
ALTER TABLE sales.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY orders_owner ON sales.orders
    FOR SELECT USING (customer_id = sales.current_customer_id());

-- Привилегии по умолчанию
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT SELECT ON TABLES TO app_read;

-- Event trigger
CREATE FUNCTION public.deny_drop() RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN NULL; END; $$;
CREATE EVENT TRIGGER trg_no_drop ON sql_drop EXECUTE FUNCTION public.deny_drop();

-- Просроченная роль (попадёт в «Сводку проблем»)
CREATE ROLE legacy_svc LOGIN PASSWORD 'x' VALID UNTIL '2020-01-01';
