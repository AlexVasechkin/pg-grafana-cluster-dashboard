# Мониторинг таблиц PostgreSQL: Grafana + postgres_exporter + VictoriaMetrics

## Цель

Чистый Grafana-дашборд для мониторинга таблиц и других сущностей БД. Источник
метрик — postgres_exporter с кастомными запросами; хранилище/скрейпинг —
VictoriaMetrics (single-node). Каждая метрика привязана к
**`{pg_cluster, db_name, table}`** (для БД-уровня — `{pg_cluster, db_name}`,
для индексов дополнительно `index`, есть также `schema`).

## Архитектура (docker compose)

```
pgmon (postgres:16, фикстура ./fixture.sql)
   ▲ SQL (read-only DSN)
postgres_exporter  ── /metrics :9187 (только кастомные метрики pgcol_*)
   ▲ scrape :9187, добавляет label pg_cluster
victoriametrics (vmsingle :8428, -promscrape.config=scrape.yml)
   ▲ Prometheus-совместимый datasource
grafana :3000 (provisioning: datasource + дашборд)
```

- `pg_cluster` — добавляется как **target-label** в scrape-конфиге VictoriaMetrics
  (не в SQL), чтобы один и тот же экспортёр можно было переиспользовать и метки
  кластера жили в конфиге сбора.
- `db_name` / `schema` / `table` / `index` — метки из SQL кастомных запросов
  (`current_database()`, `schemaname`, `relname`, `indexrelname`).
- Легаси дефолтные метрики отключены (`--disable-default-metrics`); дашборд
  использует только `pgcol_*`. Встроенные collector-метрики (`pg_*`) экспортёр
  может отдавать помимо этого — на дашборд они не влияют.

## Метрики (postgres_exporter/queries.yaml)

`pgcol_table_*` (labels: pg_cluster, db_name, schema, table, is_partition —
`is_partition="true"` у листовых партиций; переменная `$table` фильтрует по
`is_partition="false"`, чтобы в фильтр не попадали имена партиций):
- `n_live_tup`, `n_dead_tup`, `dead_ratio`
- `seq_scan`, `idx_scan` (counter) — кандидаты на индекс
- `n_tup_ins/upd/del/hot_upd` (counter) — профиль записи, HOT-ratio
- `vacuum_count/autovacuum_count/analyze_count/autoanalyze_count`
- `last_autovacuum_ts`, `last_vacuum_ts`, `last_autoanalyze_ts`, `last_analyze_ts`
  (epoch последнего обслуживания; 0 = никогда)
- `total_bytes`, `heap_bytes`, `index_bytes`, `toast_bytes`

`pgcol_table_bloat_*` (cache 300s): `ratio`, `bytes` — оценочный bloat (метод ioguix).

`pgcol_index_*` (labels: + index): `idx_scan`, `size_bytes`.

`pgcol_partition_*` (labels: db_name, schema, parent, partition, bounds):
`size_bytes`, `row_estimate` — список партиций и размер каждой.

`pgcol_statement_*` (pg_stat_statements; labels: queryid, db_name, user, query):
`total_time_ms`, `mean_time_ms`, `calls`, `rows`, `mem_bytes` (shared-буферы),
`cpu_time_ms` (=exec−IO, нужен `track_io_timing=on`), `temp_bytes`. Раздел
«Запросы»: топ по времени / ОЗУ / CPU / temp (по 10 строк).

`pgcol_db_*` (labels: pg_cluster, db_name): `size_bytes`, `numbackends`,
`xact_commit/rollback`, `blks_hit/read`, `cache_hit_ratio`, `deadlocks`,
`temp_files`, `temp_bytes`.

## Дашборд (grafana/dashboards/pg-tables.json)

Переменные: `$pg_cluster`, `$db_name`, `$table` (label_values, каскадно).
Секции:
1. **Обзор БД** — размер, соединения, cache hit, deadlocks; **таблица «Топ самых
   больших таблиц: вакуум/анализ»** (table + last autovacuum/vacuum/autoanalyze/analyze,
   сортировка по размеру, 0 → «никогда»); **таблица «Партиции и их размер»**
   (схема/родитель/партиция/границы/размер, сортировка по размеру); затем
   commits/rollbacks и temp.
2. **Таблицы (обзор)** — топ по размеру, топ по dead-ratio, топ по bloat.
3. **Таблица `$table`** — размеры (total/heap/index/toast), live/dead, «время с
   последнего (auto)vacuum/(auto)analyze», rate tuple-операций, HOT-ratio,
   seq vs idx scan.
4. **Индексы** — размеры индексов, rate сканов по `$table`.

## Запуск

```bash
cd monitoring
docker compose up -d
# Grafana:        http://localhost:3000  (anonymous, роль Admin)
# VictoriaMetrics http://localhost:8428
# дашборд: «PostgreSQL — таблицы и сущности» (провижнится автоматически)
```

## Продакшн-заметки (вне тестового окружения)

- Несколько БД: `--auto-discover-databases` (+ `--exclude-databases`) — кастомные
  запросы выполняются в каждой БД, `db_name` через `current_database()`.
- Несколько кластеров: свой scrape-таргет с `labels: { pg_cluster: <имя> }` на каждый.
- Тяжёлые запросы (bloat) — держать `cache_seconds` высоким; не гонять `--deep`.
- Экспортёру — read-only роль (`pg_monitor`), не суперпользователь.
