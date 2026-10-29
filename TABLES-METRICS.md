# Метрики обслуживания PostgreSQL из postgres_exporter

Справочник для дашборда **«Обслуживание»** (`grafana/dashboards/pg-tables.json`,
namespace `pgcol_*`).

Дашборд отвечает на вопрос **«что внутри БД требует работы DBA»**: какие таблицы
распухли, какие индексы не используются, где не ходил `ANALYZE`, какие запросы съедают
время. Состояние самого кластера (роль узла, репликация, слоты, wraparound, архивация)
— это отдельный namespace `pgcls_*` и отдельный дашборд, здесь его метрик нет.

Всё читается **одним read-only подключением** ролью `pg_monitor` и, в отличие от
кластерных метрик, **только из той БД, к которой подключён экспортёр** (см. §1).
Проверено на PostgreSQL 16.14 с фикстурой `fixture.sql` (БД `shop`).

> **Требования.** Метрики, закрывающие пункты из **таблицы метрик**,
> помечены маркером, идентификатором `Mnn` и именем требования:
> 🎯 — core, ☆ — nice-to-have, ◻ — приоритет не указан. `Mnn` — единый ключ трассировки:
> он же стоит в начале заголовка каждой панели дашборда (`[M33] Топ индексов по размеру`),
> `[доп]` — вспомогательная панель без требования.

---

## 1. Главное: привязка и область видимости

Уровней привязки здесь три, и важнее не они, а **область видимости запроса**.

| Код | Уровень | Набор меток | Что это значит на практике |
|:---:|---|---|---|
| **О** | **Объект** | `{pg_cluster, node, db_name, schema, table[, index]}` | таблица, индекс, партиция. Основной уровень дашборда |
| **Б~** | **БД, локально узлу** | `{pg_cluster, node, db_name}` | `pgcol_db_*` из `pg_stat_database`: на реплике свои цифры (почти нули) |
| **З** | **Запрос** | `{pg_cluster, node, db_name, queryid, user, query}` | `pg_stat_statements`, нормализованный запрос |

### Три ограничения, которые надо знать до чтения панелей

1. **Одна БД на экспортёр.** `pg_stat_user_tables`, `pg_stat_user_indexes`,
   `pg_stat_statements` и каталог — **per-database**. Экспортёр подключён к одной БД
   (`DATA_SOURCE_NAME`), и `db_name` берётся из `current_database()`. Чтобы видеть все
   БД, нужен `--auto-discover-databases` (+ `--exclude-databases`) — тогда экспортёр
   выполнит те же запросы в каждой БД, а кардинальность умножится на число БД.
2. **Статистика локальна узлу и обнуляется.** `pg_stat_user_*` — это счётчики
   конкретного инстанса: на реплике почти нули (пишет лидер), и всё сбрасывается при
   `pg_stat_reset()` и при пересоздании реплики. Поэтому метрики этого дашборда
   собираются **с лидера**.
3. **Размеры и каталог реплицируются, счётчики — нет.** `pg_total_relation_size()`,
   `reltuples`, `pg_stats` читаются из каталога и файлов, поэтому физически одинаковы
   на всех узлах, а `seq_scan`/`n_tup_*`/`idx_scan` — нет. Если однажды
   начнёте собирать `pgcol_*` со всех узлов, размеры придётся агрегировать
   `max by (pg_cluster, db_name, table)`, а счётчики — фильтровать лидером.

---

## 2. Модель меток

| Метка | Откуда | Уровень | Примечание |
|---|---|:--:|---|
| `pg_cluster` | scrape-конфиг | К | имя кластера или сервера; у фикстуры `shop-cluster` |
| `node` | scrape-конфиг | У | у сервера без Patroni равен `pg_cluster` — так одиночные серверы и HA-кластеры живут в одной схеме меток |
| `db_name` | SQL, `current_database()` | Б | только та БД, к которой подключён экспортёр |
| `schema` | SQL, `schemaname` | О | |
| `table` | SQL, `relname` | О | |
| `index` | SQL, `indexrelname` | О | только в `pgcol_index*` |
| `is_partition` | SQL, `relispartition::text` | О | `true` у листовой партиции — см. §8 |
| `parent`, `partition`, `bounds` | SQL, `pg_inherits` + `pg_get_expr` | О | только в `pgcol_partition` |
| `queryid`, `user`, `query` | SQL, `pg_stat_statements` | З | `query` обрезан до 120 символов |
| `job` | scrape-конфиг | — | **`postgres-tables`**, а не `postgres`: якорь фильтров кластерного дашборда `up{job="postgres"}` не должен видеть эту цель |
| `server`, `instance`, `ha` | экспортёр / скрейпер | — | в панелях не используются, в таблицах выброшены трансформацией |

> ⚠️ `schema`, `table`, `index`, `user`, `partition` — **зарезервированные слова SQL**,
> поэтому в `queries.yaml` алиасы берутся в двойные кавычки (`AS "table"`). Без кавычек
> запрос не разберётся.

---

## 3. Группы метрик

Легенда: **Тип** — `G` gauge, `C` counter (на дашборде через `rate()`/`increase()`).
Маркеры требований — см. вступление.

### A. Таблицы — `pgcol_table` (21 метрика)

Источник: `pg_stat_user_tables` + `pg_class`. Привязка **О**, метки
`{pg_cluster, node, db_name, schema, table, is_partition}`. `cache_seconds: 30`.

| Метрика | Тип | О чём говорит | Порог |
|---|:--:|---|---|
| `n_live_tup` | G | оценка живых строк | |
| `n_dead_tup` | G | оценка мёртвых строк — работа для вакуума | |
| `dead_ratio` | G | `100 * dead / live`, % | warn 20 % / crit 50 % |
| `seq_scan` | C | число seq scan: кандидат на индекс, если таблица большая | |
| `idx_scan` | C | число index scan по таблице | |
| `n_tup_ins`, `n_tup_upd`, `n_tup_del` | C | профиль записи | |
| `n_tup_hot_upd` | C | HOT-обновления; `hot/upd` низок → UPDATE задевает индексируемые колонки | warn HOT < 50 % при активных UPDATE |
| `vacuum_count`, `autovacuum_count` | C | сколько раз вакуум уже отработал | |
| `analyze_count`, `autoanalyze_count` | C | то же для анализа | |
| 🎯 **`last_autoanalyze_ts`**, **`last_analyze_ts`**<br>→ **M36** `pg.health.stale_stats` | G | epoch последнего (авто)анализа, **0 = никогда**. На панелях считается `time() - ts` | warn сутки на активной таблице |
| `last_autovacuum_ts`, `last_vacuum_ts` | G | epoch последнего (авто)вакуума, 0 = никогда | |
| 🎯 **`total_bytes`**<br>→ **M40** `pg.io.growth` | G | полный размер = heap + index + toast | |
| `heap_bytes`, `index_bytes`, `toast_bytes` | G | из чего состоит размер: индексы больше heap → кандидат на ревизию индексов | |

> Проверено на фикстуре: 11 серий, из них `is_partition="true"` — 2
> (`events_2024`, `events_2025`). Партиции попадают в `pgcol_table` наравне с обычными
> таблицами, поэтому «топ по размеру» без фильтра покажет и их.

### B. Распухание таблиц — `pgcol_table_bloat` (2 метрики)

Источник: оценочный запрос по `pg_stats` (метод ioguix), **не** `pgstattuple`.
Привязка **О** (без `is_partition`). `cache_seconds: 300`.

| Метрика | Тип | О чём говорит | Порог |
|---|:--:|---|---|
| `ratio` | G | оценка распухания, % от размера | warn 20 % / crit 40 % |
| `bytes` | G | оценка «лишних» байт — сколько вернёт `VACUUM FULL`/`pg_repack` | |

> Это **оценка по статистике планировщика**, а не измерение: точность зависит от
> свежести `ANALYZE` (связка с M36 — на устаревшей статистике bloat врёт).
> Запрос считает только `relkind IN ('r','m')` — обычные и материализованные
> представления. Проверено: родительская партиционированная таблица `events`
> (`relkind='p'`) в метрике **отсутствует**, 10 серий против 11 в `pgcol_table`.
> Табличного bloat в таблице метрик нет (M34 — только про индексы), поэтому
> метрики без маркера.

### C. Индексы — `pgcol_index` (2 метрики)

Источник: `pg_stat_user_indexes`. Привязка **О** + `index`. `cache_seconds: 30`.

| Метрика | Тип | О чём говорит | Порог |
|---|:--:|---|---|
| 🎯 **`idx_scan`**<br>→ **M33** `pg.health.unused_indexes` | C | сканирований индекса. **0 на работающей системе = мёртвый вес**: занимает место, замедляет запись, раздувает WAL | `== 0` при ненулевом `n_tup_ins` родителя |
| 🎯 **`size_bytes`**<br>→ **M33** | G | размер индекса — во что обходится этот мёртвый вес | |

> Оценивать `idx_scan == 0` можно только с учётом времени жизни счётчика: после
> `pg_stat_reset()` или пересоздания реплики ноль ничего не значит. На дашборде панель
> показывает `rate()`, а абсолютный ноль надёжнее смотреть вместе с
> `pg_postmaster_start_time` (`pgcls_node_start_ts` на кластерном дашборде).

### D. Фрагментация индексов — `pgcol_index_frag` (2 метрики)

Источник: **`pgstatindex()` из расширения `pgstattuple`**. Привязка **О** + `index`.
`cache_seconds: 600`.

| Метрика | Тип | О чём говорит | Порог |
|---|:--:|---|---|
| ☆ **`bloat_ratio`**<br>→ **M34** `pg.health.index_bloat` | G | `100 - avg_leaf_density`, % | warn 30 % / crit 50 % → `REINDEX CONCURRENTLY` |
| ☆ **`fragmentation`**<br>→ **M34** | G | `leaf_fragmentation`, % — разрывы в порядке листьев | |

> Это **единственная метрика дашборда, которая читает данные, а не каталог**:
> `pgstatindex` сканирует индекс целиком. Поэтому: нужен `CREATE EXTENSION pgstattuple`,
> фильтры `amname='btree'`, `relpages > 1`, размер `< 512 МБ`, и `cache_seconds: 600`.
> На больших индексах запрос дорогой — на проде либо оставить лимит размера, либо
> гонять отдельным расписанием, а не из экспортёра.
> Проверено на фикстуре: 9 серий по 5 таблицам.

### E. Партиции — `pgcol_partition` (2 метрики)

Источник: `pg_inherits` + `pg_class`. Привязка **О**, метки
`{pg_cluster, node, db_name, schema, parent, partition, bounds}`. `cache_seconds: 60`.

| Метрика | Тип | О чём говорит |
|---|:--:|---|
| 🎯 **`size_bytes`**<br>→ **M40** `pg.io.growth` | G | полный размер партиции: видно перекос (одна партиция вчетверо больше соседних) и забытую «толстую» историю |
| `row_estimate` | G | `reltuples` — оценка, обновляется `ANALYZE`; у новой партиции `-1`/`0`, пока анализ не прошёл |

> Метка `bounds` — это текст `FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')`:
> по ней сразу видно пропуски в расписании партиций и то, что `DEFAULT`-партиция
> начала наполняться. Кардинальность: одна серия на партицию, `bounds` уникален,
> поэтому серия не схлопывается при пересоздании партиции с другими границами.

### F. База данных — `pgcol_db` (10 метрик)

Источник: `pg_stat_database` + `pg_database_size()`, **только текущая БД**
(`WHERE d.datname = current_database()`). Привязка **Б~**. `cache_seconds: 30`.

| Метрика | Тип | О чём говорит | Порог |
|---|:--:|---|---|
| 🎯 **`size_bytes`**<br>→ **M40** `pg.io.growth` | G | размер БД; на дашборде — тренд и прогноз | |
| `numbackends` | G | соединения к этой БД | |
| 🎯 **`xact_commit`**, **`xact_rollback`**<br>→ **M28** `pg.qry.rollback_ratio` | C | TPS и доля откатов: всплеск rollback = ошибки приложения | warn 5 % откатов |
| `blks_hit`, `blks_read` | C | попадания и чтения с диска | |
| `cache_hit_ratio` | G | `hit / (hit + read)`, % | warn < 95 % |
| `deadlocks` | C | взаимоблокировки — любой рост к разбору | > 0 |
| 🎯 **`temp_files`**, **`temp_bytes`**<br>→ **M21** `pg.vac.temp_bytes` | C | спиллы на диск: не хватает `work_mem`, планы деградируют | рост при стабильной нагрузке |

> Та же БД видна и на кластерном дашборде как `pgcls_db_*` — там метрика собирается со
> **всех** узлов и по **всем** БД (`pg_stat_database` целиком), а здесь только по текущей.
> Дубль осознанный: `pgcol_db_*` нужен, чтобы дашборд «Обслуживание» работал
> самостоятельно, без кластерного контура.

### G. Запросы — `pgcol_statement` (7 метрик)

Источник: `pg_stat_statements`. Привязка **З**, метки
`{pg_cluster, node, db_name, queryid, user, query}`. `cache_seconds: 60`.
`ORDER BY total_exec_time DESC LIMIT 50`.

| Метрика | Тип | О чём говорит |
|---|:--:|---|
| ◻ **`calls`**<br>→ **M27** `pg.stat_statements` | G* | число вызовов, накопительно |
| 🎯 **`total_time_ms`**<br>→ **M32** `pg.qry.top_movers`<br>◻ → **M27** | G* | суммарное время; `topk(10, increase(...))` и есть «топ-муверы» |
| ☆ **`mean_time_ms`**<br>→ **M31** `pg.qry.stmt_mean_drift` | G | среднее время на вызов; дрейф = сравнение с `offset 1d` |
| `rows` | G* | обработано строк, накопительно |
| `mem_bytes` | G | `(shared_blks_hit + shared_blks_read) * block_size` — обращения к shared-буферам |
| `cpu_time_ms` | G* | `total_exec_time − blk_read_time − blk_write_time`; требует `track_io_timing=on`, иначе равен `total_time_ms` |
| `temp_bytes` | G | `(temp_blks_read + temp_blks_written) * block_size` — спилл конкретного запроса (разрез M21 до запроса) |

> `G*` — в `queries.yaml` накопительные счётчики объявлены как `GAUGE`. Для
> `rate()`/`increase()` это не мешает (тип в Prometheus-модели не влияет на расчёт), но
> помните про два разрыва: `pg_stat_statements_reset()` и **вытеснение** записи при
> переполнении `pg_stat_statements.max` — `increase()` увидит это как сброс.
> `queryid` стабилен между рестартами, сама запись — нет.
>
> Фильтры запроса: исключены служебные команды
> (`begin|commit|end|set|show|deallocate|reset|vacuum|analyze`), текст нормализован
> (`regexp_replace(query, '\s+', ' ')`) и **обрезан до 120 символов** — метка `query`
> в метрике не полный текст, а префикс для опознания. Полный текст смотреть в
> `pg_stat_statements` по `queryid`.

---

## 4. Сводная карта: источник → namespace → цена

| Источник в PG | Namespace | Привязка | `cache_seconds` | Серий на фикстуре |
|---|---|:--:|:--:|:--:|
| `pg_stat_user_tables` + `pg_class` | `pgcol_table` (21) | О | 30 | 11 на метрику |
| `pg_stats` (оценка ioguix) | `pgcol_table_bloat` (2) | О | 300 | 10 |
| `pg_stat_user_indexes` | `pgcol_index` (2) | О + `index` | 30 | 9 |
| `pgstatindex()` (`pgstattuple`) | `pgcol_index_frag` (2) | О + `index` | 600 | 9 |
| `pg_inherits` + `pg_class` | `pgcol_partition` (2) | О + `parent/partition/bounds` | 60 | 2 |
| `pg_stat_database` + `pg_database_size()` | `pgcol_db` (10) | Б~ | 30 | 1 |
| `pg_stat_statements` | `pgcol_statement` (7) | З | 60 | 50 |

**Итого 46 метрик.** Оценка кардинальности для прода: `pgcol_table` ≈ 21 × число
таблиц, `pgcol_index` ≈ 2 × число индексов, `pgcol_statement` = 7 × 50 (жёсткий
`LIMIT 50`). На базе из 2000 таблиц и 5000 индексов это ≈ 42 000 + 10 000 серий на одну
БД — основной риск кардинальности этого дашборда. Лечится `LIMIT`/`topk` в запросах
или сбором только по схемам приложения.

---

## 5. Особенности сбора

**5.1. Кавычки в алиасах.** `schema`, `table`, `index`, `user`, `partition` —
зарезервированные слова; в `queries.yaml` они в двойных кавычках.

**5.2. `0 = никогда`.** У `last_*_ts` вместо NULL стоит 0 (`COALESCE(extract(epoch …), 0)`):
postgres_exporter на NULL ругается и пропускает значение. На панелях `0` надо
подменять маппингом, иначе «время с последнего вакуума» будет 56 лет.

**5.3. Дорогие запросы изолированы кэшем.** `pgcol_index_frag` (600 с) и
`pgcol_table_bloat` (300 с) — единственные тяжёлые. При отладке помните: правка SQL
проявится не раньше, чем истечёт кэш, а при интервале скрейпа 15 с задержка ещё и
складывается — новая метрика появляется с запозданием до `cache_seconds + 15 с`.

**5.4. `pgstattuple` — расширение.** Без `CREATE EXTENSION pgstattuple` namespace
`pgcol_index_frag` падает на разборе, а экспортёр пишет ошибку в лог на каждый скрейп
(`CASE`/`COALESCE` не помогают: запрос к отсутствующей функции не проходит разбор).
Если расширения нет — namespace надо закомментировать целиком.

**5.5. Права.** Достаточно `pg_monitor`: `pg_stat_user_*`, `pg_statio_*`, `pg_stats`,
размеры и полный текст в `pg_stat_statements` читаются без суперпользователя.
`pgstatindex` требует прав на индекс — для `pg_monitor` достаточно, для чужих схем
может понадобиться `GRANT SELECT`.

**5.6. `queries.yaml` — DEPRECATED** в postgres_exporter v0.15: экспортёр пишет
предупреждение в лог при старте. Долгосрочно — `--collector.custom_queries`,
`sql_exporter` или `pgwatch`.

---

## 6. Чего в этих метриках нет

| Нужно | Где это | Статус |
|---|---|:--:|
| Роль узла, репликация, слоты, wraparound, архиватор | namespace `pgcls_*`, дашборд «Состояние кластера» | ✅ |
| 🎯 **M35** `pg.health.invalid_indexes` | `pg_index.indisvalid`/`indisready` — **метрики нет**, нужно добавить в `pgcol_index` | 🔧 |
| 🎯 **M36** `pg.health.stale_stats` целиком | есть возраст анализа, **нет `n_mod_since_analyze`** — без него «не анализировали сутки» не отличить от «с анализа изменилось 50 % строк» | 🔧 |
| ☆ **M31** `pg.qry.stmt_mean_drift` | метрика `mean_time_ms` есть, **панели со сравнением `offset 1d` нет** | 🟡 |
| Распухание таблиц точным методом | `pgstattuple()` вместо оценки по `pg_stats` — дорого, в экспортёре не место | — |
| Блокировки, сессии, долгие запросы | `pgcls_sess_*` / `pgcls_locks_*`, кластерный дашборд | ✅ |

Оба 🔧-пункта закрываются правкой существующих запросов в `queries.yaml`:

```sql
-- M35: в pgcol_index добавить join с pg_index и два флага
       x.indisvalid::int AS is_valid,
       x.indisready::int AS is_ready
--   ... FROM pg_stat_user_indexes s JOIN pg_index x ON x.indexrelid = s.indexrelid

-- M36: в pgcol_table добавить колонку
       s.n_mod_since_analyze
```

`indisvalid = false` — это сорванный `CREATE INDEX CONCURRENTLY`: индекс занимает место
и замедляет запись, но планировщиком не используется. `n_mod_since_analyze` в паре с
`last_autoanalyze_ts` отличает «давно не анализировали статичную таблицу» (норма) от
«с анализа изменилось полтаблицы» (деградация планов).

---

## 7. Структура дашборда

`uid: pg-tables`, заголовок «PostgreSQL — таблицы и сущности», `refresh: 30s`.
В скобках — идентификаторы требований из заголовков панелей.

| Секция | Панели |
|---|---|
| **Обзор БД — $pg_cluster / $db_name**<br>`M21, M28, M36, M40` | `[M40]` размер БД, `[доп]` соединения, cache hit, deadlocks; `[M36]` **таблица «Топ самых больших таблиц: вакуум/анализ»** (размер + 4 метки времени, `0 → «никогда»`); `[M40]` размер таблиц (piechart, без партиций) и **таблица партиций** со `bounds`; `[M28]` транзакции commit/rollback; `[M21]` temp files |
| **Таблицы (обзор)** | `[доп]` топ по `dead_ratio` и топ по `bloat_ratio` (bargauge, `topk(20)`) |
| **Таблица $table**<br>`M36, M40` | `[M40]` размеры total/heap/index/toast; `[доп]` живые/мёртвые строки; `[доп]`/`[M36]` «время с последнего (auto)vacuum/(auto)analyze»; `[доп]` seq vs idx scan; `[доп]` tuple-операции и HOT |
| **Индексы**<br>`M33, M36` | `[M33]` топ индексов по размеру, `[M33]` сканы индексов по `$table`, `[M36]` время с последнего `ANALYZE` |
| **Запросы (`pg_stat_statements`)**<br>`M21, M27, M32, M34` | `[M27 M32]` топ по времени, `[M27]` по ОЗУ, `[M27]` по CPU, `[M21 M27]` по temp; `[M34]` фрагментация индексов |

> ⚠️ Панель «Фрагментация индексов» (`M34`) лежит в секции «Запросы» — исторически, она
> про индексы. Переносится в секцию «Индексы» одной правкой `gridPos`.

Все панели ходят через переменную `${ds}` — uid источника в JSON не прошит.

---

## 8. Фильтры

| № | Переменная | Тип | Зависит от | Запрос |
|:-:|---|---|---|---|
| 1 | `$ds` | datasource | — | `prometheus` — это **тип** источника, не имя: выпадашку Grafana заполняет сама всеми источниками этого типа |
| 2 | `$pg_cluster` | query | `$ds` | `label_values(pgcol_db_size_bytes, pg_cluster)` |
| 3 | `$db_name` | query | `$pg_cluster` | `label_values(pgcol_db_size_bytes{pg_cluster="$pg_cluster"}, db_name)` |
| 4 | `$table` | query | `$pg_cluster`, `$db_name` | `label_values(pgcol_table_total_bytes{pg_cluster="$pg_cluster", db_name="$db_name"}, table)` |

Якорь фильтров — **`pgcol_db_size_bytes`**, а не `up`: здесь нужна метка `db_name`,
которой у `up` нет. Обратная сторона такого якоря: если экспортёр перестал отвечать,
сервер исчезнет из выпадашки «Кластер / сервер» — для дашборда обслуживания это
допустимо (смотреть всё равно нечего), а вот для дашборда состояния кластера якорем
обязан быть `up`, иначе упавший узел нельзя выбрать именно тогда, когда он нужен.

> 🔧 **Расхождение с описанием проекта.** По замыслу `$table` должен фильтровать по
> `is_partition="false"`, чтобы в список не попадали имена партиций. В текущем JSON
> этого фильтра **нет** — проверено: в списке `$table` присутствуют `events_2024` и
> `events_2025`. Либо вернуть фильтр в запрос переменной
> (`pgcol_table_total_bytes{…, is_partition="false"}`), либо принять как есть и
> поправить замысел. Партиции в фильтре не ломают панели (метрики по ним есть),
> поэтому это вопрос удобства, а не корректности.

---

## 9. Карта требований

Статусы: ✅ метрика собирается и панель есть, 🟡 метрика есть, панели нет,
🔧 нужна новая метрика.

| ID | Требование | Приор. | Метрика(и) | Ст. |
|:--:|---|---|---|:--:|
| **M21** | `pg.vac.temp_bytes` | core | `pgcol_db_temp_bytes`, `pgcol_db_temp_files`, `pgcol_statement_temp_bytes` | ✅ |
| **M27** | `pg.stat_statements` | — | весь `pgcol_statement_*` | ✅ |
| **M28** | `pg.qry.rollback_ratio` | core | `pgcol_db_xact_commit`, `pgcol_db_xact_rollback` | ✅ |
| **M31** | `pg.qry.stmt_mean_drift` | nice | `pgcol_statement_mean_time_ms` + `offset 1d` | 🟡 |
| **M32** | `pg.qry.top_movers` | core | `topk(10, increase(pgcol_statement_total_time_ms[1h]))` | ✅ |
| **M33** | `pg.health.unused_indexes` | core | `pgcol_index_idx_scan == 0` + `pgcol_index_size_bytes` | ✅ |
| **M34** | `pg.health.index_bloat` | nice | `pgcol_index_frag_bloat_ratio`, `…_fragmentation` | ✅ |
| **M35** | `pg.health.invalid_indexes` | core | `pg_index.indisvalid` — **нет** | 🔧 |
| **M36** | `pg.health.stale_stats` | core | `pgcol_table_last_autoanalyze_ts` + **`n_mod_since_analyze` (нет)** | ✅/🔧 |
| **M40** | `pg.io.growth` | core | `pgcol_db_size_bytes`, `pgcol_table_total_bytes`, `pgcol_partition_size_bytes` | ✅ |

Остальные требования закрываются кластерным дашбордом либо вообще не postgres_exporter'ом
(node_exporter, Patroni, etcd, отчёты бэкапов) — см. таблицу метрик, раздел
«Где искать ID».

---

## 10. Проверено на стенде

Фикстура `fixture.sql` в БД `shop` (PostgreSQL 16.14, контейнер `pgmon`), экспортёр
`postgres-exporter`, job `postgres-tables`:

| Что | Значение |
|---|---|
| Таблиц в `pgcol_table` | 11, из них 2 листовые партиции (`is_partition="true"`) |
| Схемы | `public` (pgbench), `sales`, `analytics` |
| Партиции | `events` → `events_2024`, `events_2025` с `bounds` по годам |
| Индексов | 9 (в `pgcol_index` и `pgcol_index_frag`) по 5 таблицам |
| Таблиц в bloat | 10 — партиционированная `events` (`relkind='p'`) отсутствует, это ожидаемо |
| Запросов в `pg_stat_statements` | 50 (жёсткий `LIMIT 50`), длина метки `query` — до 120 символов |
| Крупнейшие объекты | `pgbench_accounts` 155 МБ, `pgbench_history` 95 МБ, `sales.customers` 11.5 МБ |
| Размер БД | ≈ 279 МБ (`pgcol_db_size_bytes`) |
| Расширения в БД | `pg_stat_statements`, `pgstattuple`, `plpgsql` — оба нужных для `pgcol_statement` и `pgcol_index_frag` на месте |
| Настройки | `track_io_timing=on` (поэтому `cpu_time_ms` осмыслен и не равен `total_time_ms`), `pg_stat_statements.max=5000`, `shared_preload_libraries=pg_stat_statements` |

Метрик `pgcol_*` в хранилище: **46**.
