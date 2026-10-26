# Метрики состояния кластера PostgreSQL из postgres_exporter

Справочник для второго дашборда — **«Состояние кластера»** (health), в дополнение к
существующему **«Обслуживание»** (`pg-tables.json`: таблицы, вакуум, bloat, запросы).

- Обслуживающий дашборд отвечает на вопрос «что внутри БД требует работы DBA».
- Этот — на вопрос **«кластер жив, здоров и не приближается к аварии?»**, и сразу
  по **нескольким кластерам** (Patroni: лидер + реплики + логические подписчики).

Всё, что ниже, читается **одним read-only подключением** ролью `pg_monitor` и видно
из любой БД. Проверено на PostgreSQL 16.14 (одиночный инстанс) и на живом
3-узловом Patroni-кластере `pg-cluster` (pg1/pg2/pg3 + etcd×3); отличия версий отмечены.

> **Требования.** Метрики, закрывающие пункты из [`required_metrics.md`](required_metrics.md),
> **помечены в тексте** маркером, **идентификатором требования `Mnn`** и его именем:
> 🎯 — core, ☆ — nice-to-have, ◻ — приоритет в требованиях не указан.
>
> `Mnn` — единый ключ трассировки: он же стоит в заголовке каждой панели дашборда
> (`[M07] Отставание наката, сек`) и в описаниях метрик `cluster-queries.yaml`.
> Полная карта «41 требование → метрика → статус», включая то, что
> postgres_exporter дать не может, — в **§10**; фактическое покрытие — в **§11.4**.

---

## 1. Главное: три уровня привязки

Это ключ ко всему документу. postgres_exporter **всегда читает метрику через
подключение к одному узлу**, но описывать она может три разные вещи — и от этого
зависит набор меток и то, **с какого узла значение вообще брать**.

| Код | Уровень | Набор меток | Что это значит на практике |
|:---:|---|---|---|
| **У** | **Узел** (инстанс) | `{pg_cluster, node}` | Своё значение на каждом узле. Статистика процессов, WAL, конфиг, соединения. Показывать **по всем узлам**. |
| **Б~** | **БД, локально узлу** | `{pg_cluster, node, db_name}` | Счётчик живёт в статистике конкретного узла. На реплике свои цифры (у лидера коммиты, у реплики почти нули). Нужно **либо фильтровать лидера, либо смотреть осознанно по узлам**. |
| **Б=** | **БД, реплицируется** | `{pg_cluster, db_name}` | Значение берётся из каталога/файлов и **физически одинаково на всех узлах**. Если собирать со всех, получите N идентичных серий. Брать **с одного узла**. |
| **К** | **Кластер (HA)** | `{pg_cluster}` | Либо реплицируемое состояние, либо факт, который осмыслен только как **агрегат по узлам** (сколько лидеров, сколько реплик живо). В SQL такой метрики нет — она **считается в Grafana** из «У»-метрик. |
| **У+** | Узел + своя размерность | `{pg_cluster, node, <объект>}` | Слот, подключённая реплика, подписка, tablespace, GUC, wait-event. Доп. метка указана в таблицах. |

### Это проверено, а не выведено из документации

Прогон одного и того же запроса на pg1/pg2/pg3 живого кластера:

| Что мерили | pg1 | pg2 | pg3 | Вывод |
|---|---|---|---|---|
| `age(datfrozenxid)` для `postgres` | 3174418 | 3174418 | 3174418 | **Б=** — одинаково, каталог реплицируется |
| `pg_database_size('postgres')` | 7683095 | 7683095 | 7683095 | **Б=** — физический размер, одинаков |
| `pg_stat_database.xact_commit` | 8 | 9 | 9 | **Б~** — различается, статистика локальна |
| `pg_stat_replication` (строк) | 2 | 0 | 0 | **У** — только у того, кто отдаёт WAL |
| `pg_replication_slots` (строк) | 2 | 0 | **2** | **У** — слоты **не реплицируются**; на pg3 висят свои (остаток от прошлой роли) |
| файлов в `pg_ls_waldir()` | 28 | 26 | 25 | **У** — своё содержимое `pg_wal` |
| `pg_is_in_recovery()` | 1 | 1 | 1 | **У** → агрегат **К**: лидеров 0 (это standby-кластер) |

> 💡 Последняя строка — живой пример работы «К»-метрики: кластер поднялся как
> **standby-кластер** (pg1 = Standby Leader в archive recovery), primary нет ни одного.
> `sum by (pg_cluster) (pgcls_node_is_primary) == 0` ловит это сразу, тогда как
> по отдельным узлам всё выглядит «нормально работающим».

### Практические следствия для PromQL

```promql
# У  — показываем все узлы как есть
pgcls_node_uptime_seconds{pg_cluster="shop"}

# Б= — иначе 3 одинаковые линии на каждую БД; берём максимум по кластеру
max by (pg_cluster, db_name) (pgcls_db_xid_age{pg_cluster="shop"})

# Б~ — осмысленно только с лидера: оставляем серии лидера через and on(...)
sum by (pg_cluster, db_name) (
  rate(pgcls_db_xact_commit[5m]) and on(pg_cluster, node) (pgcls_node_is_primary == 1)
)
# ВНИМАНИЕ: форма `* on(...) group_left pgcls_node_is_primary` здесь неверна —
# проверено: она не отбрасывает реплики, а даёт им значение 0 (3 серии вместо 2).
# Под sum by итог совпадает, но в неагрегированных панелях появятся плоские нули.

# К  — агрегат, которого нет в SQL
count by (pg_cluster) (pgcls_node_is_primary == 1)   # должно быть ровно 1
```

---

## 2. Модель меток для мультикластерного мониторинга

Сейчас в стеке один таргет и `pg_cluster` задаётся как target-label в
`victoriametrics/scrape.yml`. Для кластерного дашборда нужен **таргет на каждый узел**,
иначе ни репликации, ни ролей, ни расхождений конфига видно не будет.

```yaml
scrape_configs:
  - job_name: postgres
    static_configs:
      - targets: ["pg1-exporter:9187"]
        labels: { pg_cluster: pg-cluster, node: pg1 }
      - targets: ["pg2-exporter:9187"]
        labels: { pg_cluster: pg-cluster, node: pg2 }
      - targets: ["pg3-exporter:9187"]
        labels: { pg_cluster: pg-cluster, node: pg3 }
      - targets: ["bil1-exporter:9187"]
        labels: { pg_cluster: billing,    node: bil1 }
```

| Метка | Откуда | Уровень | Примечание |
|---|---|---|---|
| `pg_cluster` | scrape-конфиг | К | имя HA-кластера (= Patroni `scope`) |
| `node` | scrape-конфиг | У | имя узла, **стабильно при failover** |
| `instance` | автоматически | У | `host:port` экспортёра |
| `db_name` | SQL (`datname`) | Б | для Б=-метрик агрегировать по кластеру |

> ⚠️ **Роль (primary/standby) нельзя делать меткой.** При failover она меняется:
> target-label пришлось бы править руками, а метка-из-SQL породит разрыв серии и
> сломает `rate()`. Роль отдаём **метрикой-флагом** `pgcls_node_is_primary` (1/0) —
> тогда «кто лидер» это запрос, а не конфиг, и фильтр `and on(...) (is_primary == 1)`
> (см. выше) делает Б~-метрики корректными автоматически после любого переключения.

---

## 3. Группы метрик

Легенда: **Тип** — `G` gauge, `C` counter (на дашборде через `rate()`/`increase()`).
**Привязка** — код из §1. Маркеры требований (§10): **🎯** core, **☆** nice-to-have,
**◻** без приоритета; под именем метрики — код требования (`→ pg.repl.sync_count`).
Метрики без маркера в `required_metrics.md` не заказаны, но нужны для диагностики
помеченных (например, `slot_safe_wal_size_bytes` объясняет `pg.repl.slot_retained`).

### A. Идентичность и доступность узла

Источник: `pg_postmaster_start_time()`, `pg_is_in_recovery()`, `pg_settings`.

| Метрика | Тип | Привязка | Метки | О чём говорит |
|---|:--:|:--:|---|---|
| 🎯 **`node_is_primary`**<br>→ **M01** `pg.cluster.leader_count`<br>→ **M04** `pg.ha.primary_up` (частично, §6) | G | У → **К** | `pg_cluster, node` | роль узла. Агрегат по кластеру ≠ 1 → **нет лидера или split-brain**. `count by (pg_cluster) (… == 1)` — это и есть `leader_count`; 0 → нет лидера, > 1 → split-brain |
| `node_is_in_recovery` | G | У | `pg_cluster, node` | обратный флаг, удобен для фильтров |
| `node_uptime_seconds` | G | У | `pg_cluster, node` | падение до ~0 = рестарт/failover |
| `node_start_ts` | G | У | `pg_cluster, node` | панель «последний рестарт» |
| `node_version_num` | G | У | `pg_cluster, node` | разъезд версий между узлами |
| `node_recovery_paused` | G | У | `pg_cluster, node` | `pg_is_wal_replay_paused()` — накат приостановлен |
| 🎯 **`node_timeline_id`**<br>→ **M02** `pg.cluster.timeline_change` | G | У → **К** | `pg_cluster, node` | расхождение TL между узлами = следствие failover. Требование: `changes(pgcls_node_timeline_id[1h]) > 0` — **факт переключения**; авторитетный счётчик failover даёт только Patroni (§6) |
| `pg_up` | G | У | `pg_cluster, node` | даёт сам экспортёр; 0 = не смог подключиться |

> `current_setting('cluster_name')` и `inet_server_addr()` на практике пустые
> (unix-сокет, Patroni не всегда ставит `cluster_name`) — проверено. Идентичность
> берём **только из меток скрейпа**, не из SQL.

### B. Репликация — сторона отдающего WAL

Источник: `pg_stat_replication`. Колонки проверены: `pid, usesysid, usename,
application_name, client_addr, client_hostname, client_port, backend_start,
backend_xmin, state, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag,
flush_lag, replay_lag, sync_priority, sync_state, reply_time`.

Все метрики **У+**, доп. метки: `application_name` (= имя узла-получателя в Patroni),
`client_addr`, `state`, `sync_state`.

> Проверено: строки есть **не только у primary**. На pg1 (Standby Leader) их 2 — он
> каскадно отдаёт WAL на pg2/pg3. Поэтому метрика привязана к «узлу-отправителю»,
> а не к «primary».

| Метрика | Тип | Привязка | Метки | О чём говорит | Порог |
|---|:--:|:--:|---|---|---|
| 🎯 **`repl_standby_count`**<br>→ **M08** `pg.repl.standby_count` | G | У | `pg_cluster, node` | сколько получателей подключено | `<` ожидаемого → реплика отвалилась (ожидаемое — из метки `expected_standbys`, `CLUSTER-FILTERS.md` §6.3) |
| 🎯 **`repl_sync_standby_count`**<br>→ **M05** `pg.repl.sync_count` | G | У | `pg_cluster, node` | `sync_state='sync'` | `< N` → **RPO=0 нарушен**; 0 при `synchronous_commit=on` → **запись встанет**. N брать из `setting_value{name="synchronous_standby_names"}` или метки `expected_sync` |
| `repl_sent_lag_bytes` | G | У+ | `+ application_name` | отправка/сеть не успевает | |
| `repl_write_lag_bytes` | G | У+ | `+ application_name` | реплика не успевает писать | |
| 🎯 **`repl_flush_lag_bytes`**<br>→ **M06** `pg.repl.sync_flush_lag` | G | У+ | `+ application_name, sync_state` | fsync реплики не успевает | **с `sync_state="sync"`** это и есть удержанный лаг, который бьёт по всем коммитам |
| 🎯 **`repl_replay_lag_bytes`**<br>→ **M07** `pg.repl.async_lag` | G | У+ | `+ application_name, sync_state` | **главная метрика отставания** | warn 64 MB / crit 512 MB; для требования фильтр `sync_state="async"` |
| `repl_write_lag_seconds` | G | У+ | `+ application_name` | отставание во времени | |
| 🎯 **`repl_flush_lag_seconds`**<br>→ **M06** `pg.repl.sync_flush_lag` | G | У+ | `+ application_name, sync_state` | то же в секундах — понятнее для оценки «встали ли коммиты» | warn 1 s на sync-реплике |
| 🎯 **`repl_replay_lag_seconds`**<br>→ **M07** `pg.repl.async_lag` | G | У+ | `+ application_name, sync_state` | понятнее байтов для RPO | warn 30 s / crit 300 s |
| `repl_state_streaming` | G | У+ | `+ application_name, state` | `catchup`/`backup` длительно → проблема | |
| `repl_reply_age_seconds` | G | У+ | `+ application_name` | реплика молчит | warn 60 s |

> 🎯 **Важно для требований `pg.repl.sync_flush_lag` и `pg.repl.async_lag`:** метку
> `sync_state` надо отдавать **на самих lag-метриках**, а не только на
> `repl_state_streaming`. Без неё синхронную и асинхронную реплику в запросе не
> развести, а это разные требования с разными порогами: удержанный sync-лаг
> тормозит каждый коммит на лидере, async-лаг — только чтение с реплики.
>
> ```promql
> # удержанный лаг синхронной реплики (pg.repl.sync_flush_lag)
> max by (pg_cluster, application_name) (
>   pgcls_repl_flush_lag_seconds{pg_cluster="$pg_cluster", sync_state="sync"})
> # отставание читающих реплик (pg.repl.async_lag)
> max by (pg_cluster, application_name) (
>   pgcls_repl_replay_lag_seconds{pg_cluster="$pg_cluster", sync_state="async"})
> ```

```sql
-- на узле, который не отдаёт WAL, вернёт 0 строк
SELECT r.application_name, r.client_addr::text AS client_addr,
       r.state, r.sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), r.sent_lsn)   AS sent_lag_bytes,
       pg_wal_lsn_diff(pg_current_wal_lsn(), r.write_lsn)  AS write_lag_bytes,
       pg_wal_lsn_diff(pg_current_wal_lsn(), r.flush_lsn)  AS flush_lag_bytes,
       pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn) AS replay_lag_bytes,
       COALESCE(extract(epoch FROM r.write_lag),  0) AS write_lag_seconds,
       COALESCE(extract(epoch FROM r.flush_lag),  0) AS flush_lag_seconds,
       COALESCE(extract(epoch FROM r.replay_lag), 0) AS replay_lag_seconds,
       COALESCE(extract(epoch FROM now()-r.reply_time), 0) AS reply_age_seconds
FROM pg_stat_replication r;
```

> ⚠️ На узле в recovery `pg_current_wal_lsn()` **падает**. Для каскадной схемы
> (pg1 = Standby Leader с 2 получателями) диффы нужно считать от
> `pg_last_wal_receive_lsn()`. См. §5.1.

### C. Репликация — сторона получателя WAL

Источник: `pg_stat_wal_receiver`, функции `pg_last_*`.

| Метрика | Тип | Привязка | Метки | О чём говорит |
|---|:--:|:--:|---|---|
| `recv_active` | G | У | `pg_cluster, node` | 0 на реплике = **накат оборван** |
| `recv_status_streaming` | G | У+ | `+ status, sender_host` | `status` из `pg_stat_wal_receiver` |
| `recv_msg_age_seconds` | G | У | `pg_cluster, node` | `now()-last_msg_receipt_time` — сендер молчит |
| `standby_replay_delay_seconds` | G | У | `pg_cluster, node` | `now()-pg_last_xact_replay_timestamp()` — отставание наката **с точки зрения самой реплики** |
| `standby_receive_lsn` / `standby_replay_lsn` | G | У | `pg_cluster, node` | LSN числом, для дельт между узлами в Grafana |
| `standby_recv_replay_diff_bytes` | G | У | `pg_cluster, node` | WAL получен, но не применён → конфликт recovery или долгий запрос на реплике |
| `db_recovery_conflicts_*` | C | **Б~** | `pg_cluster, node, db_name` | `pg_stat_database_conflicts`: `confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock, confl_tablespace, confl_active_logicalslot` — запросы на реплике отменяются |

```sql
SELECT COALESCE((SELECT 1 FROM pg_stat_wal_receiver LIMIT 1), 0) AS recv_active,
       COALESCE((SELECT extract(epoch FROM now()-last_msg_receipt_time)
                   FROM pg_stat_wal_receiver LIMIT 1), 0) AS recv_msg_age_seconds,
       COALESCE(extract(epoch FROM now()-pg_last_xact_replay_timestamp()), 0) AS replay_delay_seconds,
       COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(),
                                pg_last_wal_replay_lsn()), 0) AS recv_replay_diff_bytes;
```

> ⚠️ **Два подтверждённых подводных камня** (вы на них уже наступали в `pgservercollect`):
> 1. В `pg_stat_wal_receiver` **нет колонки `received_lsn`** (была в PG ≤ 12).
>    Есть `written_lsn` и `flushed_lsn` — проверено на PG 16.
> 2. `pg_current_wal_lsn()` / `pg_walfile_name()` **падают во время recovery**.
>
> Проверено: `pg_last_wal_receive_lsn()`, `pg_last_wal_replay_lsn()` и
> `pg_last_xact_replay_timestamp()` на primary возвращают **NULL, а не ошибку** —
> значит их можно звать безусловно, достаточно `COALESCE(...,0)`.

### D. Слоты репликации — риск переполнения `pg_wal`

Источник: `pg_replication_slots` (`slot_name, plugin, slot_type, datoid, database,
temporary, active, active_pid, xmin, catalog_xmin, restart_lsn, confirmed_flush_lsn,
wal_status, safe_wal_size, two_phase, conflicting`).

Все **У+**, доп. метки: `slot_name`, `slot_type` (physical/logical), `plugin`, `database`.

> ⚠️ **Слоты не реплицируются** — проверено: pg1 = 2 слота, pg2 = 0, pg3 = 2.
> Поэтому это строго **У+**, и собирать надо **со всех узлов**: забытый слот на бывшем
> лидере так же съедает диск, как на действующем. (В PG 17 появился
> `pg_sync_replication_slots` / failover-слоты — тогда часть станет реплицируемой.)

| Метрика | Тип | Привязка | О чём говорит | Порог |
|---|:--:|:--:|---|---|
| 🎯 **`slot_active`**<br>→ **M09** `pg.repl.slot_retained` | G | У+ | `active::int`; **0 у постоянного слота — самая частая причина «кончился диск под WAL»** | 0 = warn сразу. «Слот умер» из требования — это именно `slot_active == 0` |
| 🎯 **`slot_retained_bytes`**<br>→ **M09** `pg.repl.slot_retained`<br>◻ → **M10** `pg.repl.log_slot_retained` | G | У+ | сколько WAL держит слот | warn 10 GB / crit 50 GB. Требование по логическим слотам — та же метрика с `slot_type="logical"`, отдельной метрики не нужно |
| `slot_safe_wal_size_bytes` | G | У+ | сколько ещё можно сгенерить, пока слот не станет `lost` | < 1 GB = crit |
| `slot_wal_status_code` | G | У+ | `reserved`/`extended`/`unreserved`/`lost` → 0..3 | `lost` = данные для подписчика потеряны |
| `slot_conflicting` | G | У+ | PG 16+: слот сломан конфликтом recovery | 1 = crit |
| 🎯 **`slot_xmin_age`**<br>→ **M23** `pg.sess.xmin_horizon` | G | У+ | слот тормозит vacuum **на всём узле** | одна из трёх причин удержанного горизонта (см. §G) |
| 🎯 **`slot_catalog_xmin_age`**<br>→ **M10** `pg.repl.log_slot_retained` | G | У+ | то же для каталога (логические слоты) | растёт только у логических слотов — признак забытой подписки |

Логическая репликация (у вас в стеке есть `subscriber`) — метрики **У+** на узле-подписчике,
доп. метка `subname`:

| Метрика | Тип | Привязка | Источник | О чём говорит |
|---|:--:|:--:|---|---|
| ◻ **`sub_apply_error_count`** / **`sub_sync_error_count`**<br>→ **M11** `pg.subscription_origin` | C | У+ | `pg_stat_subscription_stats` (PG 15+) | подписка падает на применении |
| ◻ **`sub_latest_end_age_seconds`**<br>→ **M11** `pg.subscription_origin` | G | У+ | `pg_stat_subscription.latest_end_time` | подписчик отстал/замер |
| `sub_worker_count` | G | У+ | `pg_stat_subscription` | воркеры живы |
| ◻ **`origin_remote_lsn`** / **`origin_local_lsn`**<br>→ **M11** `pg.subscription_origin` | G | У+ (`+ origin`) | **`pg_replication_origin_status`** — НОВОЕ, в стеке не реализовано | докуда применён поток от издателя. Разность с LSN издателя = лаг логической репликации в байтах; считается в Grafana между узлами |
| `slot_spill_bytes`, `slot_stream_bytes` | C | У+ | `pg_stat_replication_slots` | декодирование выливается на диск → мало `logical_decoding_work_mem` |

```sql
-- origin-прогресс на узле-подписчике (НОВОЕ, для pg.subscription_origin)
SELECT external_id                                        AS origin,
       COALESCE(pg_wal_lsn_diff(remote_lsn, '0/0'), 0)     AS origin_remote_lsn,
       COALESCE(pg_wal_lsn_diff(local_lsn,  '0/0'), 0)     AS origin_local_lsn
FROM pg_replication_origin_status;
```

> ⚠️ Два предостережения по `pg.subscription_origin`:
> 1. **Формулировка требования неоднозначна** — «origin» может означать и лаг
>    origin-а (эта метрика), и ошибки применения (`sub_apply_error_count`). Пока
>    закрываю обеими, уточнить у заказчика (§10.3).
> 2. **Права не проверены.** `pg_ls_waldir()`/`pg_stat_replication` под `pg_monitor`
>    читаются (§5.7), а `pg_replication_origin_status` — нет: в живом стенде
>    подписок не было. Если `pg_monitor` не хватит, метрику отдавать
>    `SECURITY DEFINER`-обёрткой, а не поднимать права экспортёру.

### E. WAL, checkpoint, архивация

Все **У** (`{pg_cluster, node}`) — у каждого узла свои WAL, свой checkpointer, свой архиватор.
Проверено: `pg_ls_waldir()` дал 28/26/25 файлов на pg1/pg2/pg3.

| Метрика | Тип | Привязка | Источник | О чём говорит |
|---|:--:|:--:|---|---|
| 🎯 **`wal_bytes`**<br>→ **M16** `pg.wal.bytes_rate` | C | У | `pg_stat_wal` (PG 14+) | `rate()` = скорость генерации WAL; база для `max_wal_size` и канала репликации. Требование: сравнивать с пропускной способностью сети до реплик |
| `wal_records`, `wal_fpi` | C | У | `pg_stat_wal` | высокий `fpi` → слишком частые checkpoint |
| `wal_buffers_full` | C | У | `pg_stat_wal` | мало `wal_buffers` |
| `wal_write_time`, `wal_sync_time` | C | У | `pg_stat_wal` | требует `track_io_timing=on` (у вас **on**) |
| `wal_dir_bytes`, `wal_dir_files` | G | У | `pg_ls_waldir()` | фактический объём `pg_wal` — растёт при залипшем слоте/архиваторе |
| 🎯 **`ckpt_timed`**, **`ckpt_req`**<br>→ **M17** `pg.wal.ckpt_req_ratio` | C | У | `pg_stat_bgwriter` | доля `req` высока → мал `max_wal_size`, I/O штормит на чекпоинтах. Само отношение считается в Grafana (формула ниже) |
| `ckpt_write_time`, `ckpt_sync_time` | C | У | `pg_stat_bgwriter` | длинные checkpoint = пилы по latency |
| `buffers_checkpoint/clean/backend` | C | У | `pg_stat_bgwriter` | `buffers_backend` велик → bgwriter не справляется |
| 🎯 **`buffers_backend_fsync`**<br>→ **M18** `pg.wal.backend_fsync` | C | У | `pg_stat_bgwriter` (PG ≤ 16) — **НОВОЕ**, в стеке не реализовано | бэкенд сам делает fsync, не дождавшись checkpointer → **IO насыщен**. Любой ненулевой `rate()` — к разбору. **PG 17**: колонки нет, берётся из `pg_stat_io` (`fsyncs` при `backend_type='client backend'`) |
| `maxwritten_clean` | C | У | `pg_stat_bgwriter` | bgwriter прерывается по лимиту |
| `archiver_archived_count` | C | У | `pg_stat_archiver` | архивация идёт |
| 🎯 **`archiver_failed_count`**<br>→ **M12** `pg.arch.failed` | C | У | `pg_stat_archiver` | **рост = PITR ломается, WAL копится** (дыра в PITR + `pg_wal` пухнет) |
| `archiver_last_archived_age_seconds` | G | У | `pg_stat_archiver` | архиватор замер | 
| `archive_mode_on` | G | У | `pg_settings` | архивация включена вообще |
| 🎯 **`arch_ready_count`**<br>→ **M13** `pg.arch.ready_queue` | G | У | **`pg_ls_archive_statusdir()`** (PG 12+) — **НОВОЕ**, в стеке не реализовано | сколько WAL-сегментов ждут архивации. **Затор архивации**: растущая очередь = `pg_wal` не чистится, даже если `archiver_failed_count` стоит на месте (команда висит, а не падает) |

```sql
-- очередь архивации (НОВОЕ, для pg.arch.ready_queue); pg_monitor достаточно
SELECT count(*) FILTER (WHERE name LIKE '%.ready') AS arch_ready_count,
       count(*) FILTER (WHERE name LIKE '%.done')  AS arch_done_count
FROM pg_ls_archive_statusdir();
```

🎯 Отношение checkpoint'ов по требованию `pg.wal.ckpt_req_ratio` — вычисляемое,
метрики для него уже есть:

```promql
100 * rate(pgcls_ckpt_req{pg_cluster="$pg_cluster", node="$node"}[$__rate_interval])
    / clamp_min(
        rate(pgcls_ckpt_req{pg_cluster="$pg_cluster", node="$node"}[$__rate_interval])
      + rate(pgcls_ckpt_timed{pg_cluster="$pg_cluster", node="$node"}[$__rate_interval]),
        0.0001)
```

> ⚠️ **PG 17**: `pg_stat_bgwriter` разделён — checkpoint-колонки ушли в
> `pg_stat_checkpointer`, `buffers_backend` исчез (см. `pg_stat_io`). В
> `pgservercollect` у вас это учтено; в queries.yaml понадобится версионирование.

### F. Соединения, активность, ожидания, блокировки

Источник: `pg_stat_activity`, `pg_locks`, `pg_prepared_xacts`, `pg_settings`.
База — **У**; у `pg_stat_activity` есть `datname`, поэтому те же метрики можно
дополнительно резать до **Б~** (решить на этапе дашборда: разрез по БД утраивает
кардинальность).

| Метрика | Тип | Привязка | Метки | О чём говорит | Порог |
|---|:--:|:--:|---|---|---|
| `max_connections` | G | У | `pg_cluster, node` | знаменатель для насыщения | |
| `backends_total` | G | У (/Б~) | `+ db_name` опц. | `count(*) FROM pg_stat_activity` | |
| 🎯 **`connections_used_ratio`**<br>→ **M24** `pg.sess.conn_pct` | G | У | `pg_cluster, node` | насыщение пула соединений — слоты подключений заканчиваются | warn 70 % / crit 85 % |
| `backends_active` | G | У (/Б~) | | `state='active'` — реальная параллельность | > числа ядер = очередь |
| 🎯 **`backends_idle_in_xact`**<br>→ **M25** `pg.sess.idle_in_trx` | G | У (/Б~) | | **держит xmin (bloat), блокирует vacuum и создаёт локи** | warn > 5 |
| `oldest_xact_age_seconds` | G | У | `pg_cluster, node` | `max(now()-xact_start)` по не-idle | warn 300 s / crit 3600 s |
| 🎯 **`oldest_query_age_seconds`**<br>→ **M29** `pg.qry.long_running` | G | У | `pg_cluster, node` | долгие запросы: держат снапшот и локи | warn 300 s |
| 🎯 **`long_running_count`**<br>→ **M29** `pg.qry.long_running` | G | У+ (`+ bucket`) | **НОВОЕ**, в стеке не реализовано: `pg_stat_activity` | сколько активных запросов живут дольше порога (60 s / 300 s / 3600 s). Один `oldest` не отличает «один тяжёлый отчёт» от «встала вся база» | warn > 0 на 300 s |
| 🎯 **`oldest_idle_in_xact_seconds`**<br>→ **M25** `pg.sess.idle_in_trx` | G | У | `pg_cluster, node` | главный враг wraparound | warn 300 s |
| 🎯 **`locks_not_granted`**<br>→ **M26** `pg.sess.lock_waiters` | G | У | `pg_cluster, node` | `pg_locks WHERE NOT granted` — **очередь блокировок** (инцидентная метрика) | > 0 длительно = цепочка блокировок |
| 🎯 **`locks_by_mode`**<br>→ **M26** `pg.sess.lock_waiters` | G | У+ | `+ mode, granted` | откуда `AccessExclusiveLock`. В реализации — отдельный namespace: **`pgcls_locks_count{mode, granted}`** (`count(*) FROM pg_locks GROUP BY mode, granted`), т.к. это построчная метрика, а `pgcls_sess` возвращает одну строку на узел | |
| 🎯 **`waiting_by_event_type`**<br>→ **M26** `pg.sess.lock_waiters` | G | У+ | `+ wait_event_type` | `Lock`/`IO`/`LWLock`/`Client` — профиль узкого места | |
| `backends_by_type` | G | У+ | `+ backend_type` | автовакуум-воркеры на пределе | |
| 🎯 **`autovacuum_workers_running`**<br>→ **M22** `pg.vac.workers_set` | G | У | `pg_cluster, node` | = `autovacuum_max_workers` → **пул воркеров насыщен**, очередь вакуума. Знаменатель — `setting_value{name="autovacuum_max_workers"}` (§I) | warn ≥ 100 % |
| ☆ **`autovacuum_antiwrap_running`**<br>→ **M20** `pg.vac.antiwrap_running` | G | У | **НОВОЕ**, в стеке не реализовано: `pg_stat_activity` | сколько воркеров идут в режиме `(to prevent wraparound)` — маркер того, что аварийная очистка уже началась (а значит `pg.vac.xid_age` перевалил `autovacuum_freeze_max_age`) | > 0 = информативно, не авария |
| 🎯 **`prepared_xacts_count`**<br>→ **M23** `pg.sess.xmin_horizon` | G | **К** | `pg_cluster` | 2PC лежит в WAL → **реплицируется**; забытый держит WAL и xmin вечно | warn > 0 |
| `oldest_prepared_xact_seconds` | G | **К** | `pg_cluster` | `now()-prepared` | warn 60 s |

```sql
-- НОВОЕ: счётчики долгих запросов и аварийного автовакуума
-- (для pg.qry.long_running и pg.vac.antiwrap_running)
SELECT count(*) FILTER (WHERE a.backend_type = 'client backend'
                          AND a.state = 'active'
                          AND now() - a.query_start > interval '60 seconds')  AS long_running_60s,
       count(*) FILTER (WHERE a.backend_type = 'client backend'
                          AND a.state = 'active'
                          AND now() - a.query_start > interval '300 seconds') AS long_running_300s,
       count(*) FILTER (WHERE a.backend_type = 'autovacuum worker')           AS autovacuum_workers_running,
       count(*) FILTER (WHERE a.backend_type = 'autovacuum worker'
                          AND a.query ~* 'to prevent wraparound')             AS autovacuum_antiwrap_running
FROM pg_stat_activity a;
```

> `long_running_count` с меткой `bucket` вместо трёх колонок — дело вкуса; тремя
> колонками проще, метка нужна только если порогов станет больше.

> Привязка `prepared_xacts` к **К** — по семантике PG (`pg_twophase` попадает в WAL и
> накатывается на реплики). На живом кластере подтвердить не смог: подготовленных
> транзакций там 0, а создавать их в вашем DR-стенде я не стал. Если важно —
> проверяется одним `PREPARE TRANSACTION` на лидере.

### G. Wraparound — предаварийные метрики

Самая важная группа для «состояния»: исчерпание XID останавливает кластер.
**Привязка Б=** — значение реплицируется, одинаково на всех узлах (проверено:
3174418 на pg1/pg2/pg3). Собирать со всех узлов можно, но на дашборде
**агрегировать `max by (pg_cluster, db_name)`**, иначе N одинаковых серий на БД.

| Метрика | Тип | Привязка | Метки | Порог |
|---|:--:|:--:|---|---|
| 🎯 **`db_xid_age`**<br>→ **M19** `pg.vac.xid_age` | G | **Б=** | `pg_cluster, db_name` | warn 50 % / crit 80 % от `autovacuum_freeze_max_age` (по умолчанию 200 М — старт принудительной вакуумации; 1.6 млрд — остановка БД) |
| 🎯 **`db_xid_pct`**<br>→ **M19** `pg.vac.xid_age` | G | **Б=** | `pg_cluster, db_name` | warn 50 / crit 80 |
| 🎯 **`db_mxid_age`**<br>→ **M19** `pg.vac.xid_age` | G | **Б=** | `pg_cluster, db_name` | против `autovacuum_multixact_freeze_max_age` |
| 🎯 **`slot_xmin_age`**<br>→ **M23** `pg.sess.xmin_horizon` | G | У+ | `+ slot_name` | кто держит горизонт — слот |
| 🎯 **`backend_xmin_age`**<br>→ **M23** `pg.sess.xmin_horizon` | G | У | `pg_cluster, node` | кто держит горизонт — сессия |
| 🎯 **`prepared_xact_age`**<br>→ **M23** `pg.sess.xmin_horizon` | G | К | `pg_cluster` | кто держит горизонт — 2PC |

```sql
SELECT d.datname AS db_name,
       age(d.datfrozenxid)   AS xid_age,
       mxid_age(d.datminmxid) AS mxid_age,
       round(100.0*age(d.datfrozenxid)
             / current_setting('autovacuum_freeze_max_age')::bigint, 2) AS xid_pct
FROM pg_database d WHERE d.datallowconn;
```

🎯 Требование `pg.sess.xmin_horizon` («держится горизонт — вакуум не работает и
таблицы пухнут») — это **максимум из трёх источников**, отдельной метрики не нужно:

```promql
max by (pg_cluster) (
    pgcls_backend_xmin_age{pg_cluster="$pg_cluster"}
 or pgcls_slot_xmin_age{pg_cluster="$pg_cluster"}
 or pgcls_prepared_xact_age{pg_cluster="$pg_cluster"}
)
```

> `or` здесь — объединение серий (имена метрик разные, поэтому ни одна не
> вытесняется), а `max by` даёт итоговый горизонт. Разворачивать его обратно на три
> метрики нужно в таблице «кто держит»: сессия, слот или 2PC — лечатся по-разному.

### H. Нагрузка и эффективность по БД

У вас уже есть `pgcol_db_*` по **текущей** БД. Для кластерного дашборда нужно по всем
БД — `pg_stat_database` виден целиком из одного коннекта. **Здесь две разные привязки,
и это важно не перепутать:**

| Метрика | Тип | Привязка | Метки | О чём говорит |
|---|:--:|:--:|---|---|
| 🎯 **`db_size_bytes`**<br>→ **M40** `pg.io.growth` | G | **Б=** | `pg_cluster, db_name` | физический размер — одинаков на узлах (проверено) |
| 🎯 **`cluster_size_bytes`**<br>→ **M40** `pg.io.growth` | G | **Б=→К** | `pg_cluster` | сумма по БД, **планирование объёма**: `predict_linear(max by (pg_cluster) (pgcls_cluster_size_bytes)[7d:1h], 30*86400)` |
| `tablespace_size_bytes` | G | **Б=** + `spcname` | `pg_cluster, spcname` | диск на нестандартных tablespace |
| 🎯 **`db_xact_commit`**, **`db_xact_rollback`**<br>→ **M28** `pg.qry.rollback_ratio` | C | **Б~** | `pg_cluster, node, db_name` | TPS и **всплеск ошибок приложения**. **Различается по узлам** (проверено: 8/9/9) — брать с лидера; само отношение считается в Grafana (формула ниже) |
| `db_cache_hit_ratio` | G | **Б~** | `+ node` | < 95 % → мал `shared_buffers`; у реплики свой профиль |
| 🎯 **`db_blk_read_time`**, **`db_blk_write_time`**<br>→ **M39** `pg.io.disk_latency` (суррогат) | C | **Б~** | `+ node` | IO-время (нужен `track_io_timing`). Честную latency диска даёт только node_exporter (§6); это — время, которое PG **сам** ждал на IO, по БД |
| `db_deadlocks` | C | **Б~** | `+ node` | любой рост — к разбору |
| 🎯 **`db_temp_files`**, **`db_temp_bytes`**<br>→ **M21** `pg.vac.temp_bytes` | C | **Б~** | `+ node` | спиллы на диск: мал `work_mem`, планы деградируют. ⚠️ В требованиях метрика лежит в группе `vac.*`, хотя к вакууму отношения не имеет — это `pg_stat_database.temp_bytes` (§10.2) |
| 🎯 **`db_checksum_failures`**<br>→ **M38** `pg.io.checksum_fail` | C | **Б~** | `+ node` | **повреждение данных, crit немедленно**; на разных узлах разное — реплика может быть цела. Работает только при `data_checksums=on` (флаг — в §I) |
| `db_sessions`, `db_sessions_abandoned/fatal/killed` | C | **Б~** | `+ node` | обрывы соединений (PG 14+) |
| `db_active_time`, `db_idle_in_transaction_time` | C | **Б~** | `+ node` | где время сессий (PG 14+) |
| `db_tup_returned/fetched/inserted/updated/deleted` | C | **Б~** | `+ node` | профиль чтения/записи |
| `db_numbackends` | G | **Б~** | `+ node` | соединения в разрезе БД |
| `db_conflicts` | C | **Б~** | `+ node` | отмены на standby |
| `io_*` | C | У+ | `+ backend_type, object, context` | `pg_stat_io` (**PG 16+**): `reads/hits/evictions/fsyncs/extends`; заменяет `buffers_backend` в PG 17 |
| `slru_*` | C | У+ | `+ name` | `pg_stat_slru` — ловит проблемы с multixact/subtrans |

🎯 Требование `pg.qry.rollback_ratio` — вычисляемое, с фильтром лидера из §1:

```promql
100 *
  sum by (pg_cluster, db_name) (
    rate(pgcls_db_xact_rollback{pg_cluster="$pg_cluster"}[$__rate_interval])
    and on(pg_cluster, node) (pgcls_node_is_primary == 1))
/ clamp_min(
  sum by (pg_cluster, db_name) (
    ( rate(pgcls_db_xact_commit{pg_cluster="$pg_cluster"}[$__rate_interval])
    + rate(pgcls_db_xact_rollback{pg_cluster="$pg_cluster"}[$__rate_interval]) )
    and on(pg_cluster, node) (pgcls_node_is_primary == 1)), 0.0001)
```

> ⚠️ `rollback_ratio` ловит только то, что докатилось до `ROLLBACK`. Ошибку с
> конкретным SQLSTATE (требование `pg.qry.sqlstate_error`: `53100` disk full,
> `XX00x` corruption) `pg_stat_database` не показывает **никак** — нужен другой
> источник, см. §6.

### I. Конфигурация как метрика

Источник `pg_settings`. Привязка **У+** (доп. метка `name`) — у каждого узла свой
`postgresql.conf`, и именно расхождения между узлами одного кластера надо видеть
(после ручной правки на одной ноде).

| Метрика | Привязка | Что показывать |
|---|:--:|---|
| `setting_value` | У+`name` | `max_connections`, `shared_buffers`, `work_mem`, `maintenance_work_mem`, `max_wal_size`, `checkpoint_timeout`, `autovacuum_max_workers`, `autovacuum_freeze_max_age`, `max_replication_slots`, `max_wal_senders`, `statement_timeout` |
| `setting_flag` | У+`name` | `archive_mode`, `hot_standby_feedback`, `synchronous_commit`, `track_io_timing`, `fsync`, `full_page_writes`, `data_checksums`, `wal_log_hints` |
| `wal_level_code` | У | `minimal`/`replica`/`logical` → 0/1/2 |
| `pending_restart_count` | У | `count(*) FROM pg_settings WHERE pending_restart` — конфиг применён не полностью |
| `config_reload_age_seconds` | У | `now() - pg_conf_load_time()` |

Снято с тестового узла: `max_connections=100`, `shared_buffers=16384` (блоков по 8 kB =
128 MB), `max_wal_size=1024` (MB), `wal_level=logical`, `track_io_timing=on`,
`archive_mode=off`, `hot_standby_feedback=off`.

Панель «расхождение конфига» — чистая «К»-метрика, считается в Grafana:

```promql
count by (pg_cluster, name) (count by (pg_cluster, name, value) (pgcls_setting_value)) > 1
```

> `hot_standby_feedback=off` при наличии реплик стоит вынести отдельно: это причина
> конфликтов recovery и отмены запросов на standby.

### J. Прогресс длительных операций

Все **У+** (доп. метки `pid`, `datname`, `phase`).

| Метрика | Привязка | Источник | О чём говорит |
|---|:--:|---|---|
| ☆ **`progress_vacuum_*`**<br>→ **M20** `pg.vac.antiwrap_running` | У+ | `pg_stat_progress_vacuum` (`phase, heap_blks_total/scanned/vacuumed, index_vacuum_count`) | идёт ли антивраппараунд-вакуум и **успеет ли** (прогресс по блокам). Сам факт «идёт» дешевле брать из `autovacuum_antiwrap_running` (§F) |
| `progress_basebackup_*` | У+ | `pg_stat_progress_basebackup` (`backup_total, backup_streamed`) | **Patroni поднимает реплику** — видно прямо на дашборде |
| `progress_analyze/cluster/create_index/copy_*` | У+ | соответствующие `pg_stat_progress_*` | долгие DDL/загрузки |

### K. Объекты, индексы и запросы — namespace `pgcol_*`

Группа добавлена **ради требований**: в `required_metrics.md` разделы «Обслуживание»
и «Запросы» содержат 7 пунктов, которые к HA-кластеру не относятся и живут не в
`pgcls_*`, а в уже существующем `postgres_exporter/queries.yaml` (дашборд
`pg-tables.json`). Привязка у всех — **Б~ + объект** (`db_name, schema, table[, index]`
или `queryid`), собираются с лидера; на реплике `pg_stat_user_*` почти нулевые.

| Требование | Метрика | Статус | О чём говорит |
|---|---|:--:|---|
| 🎯 **M33** `pg.health.unused_indexes` | `pgcol_index_idx_scan == 0` + `pgcol_index_size_bytes` | есть | мёртвый вес: место, замедление записи, лишний WAL |
| 🎯 **M35** `pg.health.invalid_indexes` | **`pgcol_index_is_valid`**, **`pgcol_index_is_ready`** — **НОВОЕ** | нет | `indisvalid=false` (сорванный `CREATE INDEX CONCURRENTLY`): замедляет запись, на чтении не используется |
| ☆ **M34** `pg.health.index_bloat` | `pgcol_index_frag_bloat_ratio`, `pgcol_index_frag_fragmentation` | есть | раздутый индекс медленнее, больше и вытесняет кэш |
| 🎯 **M36** `pg.health.stale_stats` | `pgcol_table_last_autoanalyze_ts`, `..._last_analyze_ts` + **`pgcol_table_n_mod_since_analyze`** — **НОВОЕ** | частично | возраста анализа мало: «не анализировали сутки» нормально для статичной таблицы и авария для той, где с анализа изменилось 50 % строк |
| ◻ **M27** `pg.stat_statements` | `pgcol_statement_calls/total_time_ms/mean_time_ms/rows/mem_bytes/cpu_time_ms/temp_bytes` | есть | динамика запросов |
| 🎯 **M32** `pg.qry.top_movers` | `topk(10, increase(pgcol_statement_total_time_ms[1h]))` | есть | базовая видимость производительности |
| ☆ **M31** `pg.qry.stmt_mean_drift` | `pgcol_statement_mean_time_ms` vs своё же значение сутки назад (`offset 1d`) | есть | адресная деградация конкретного запроса |

```sql
-- НОВОЕ для pg.health.invalid_indexes: добавить в pgcol_index
       x.indisvalid::int AS is_valid,
       x.indisready::int AS is_ready
--   ... FROM pg_stat_user_indexes s JOIN pg_index x ON x.indexrelid = s.indexrelid

-- НОВОЕ для pg.health.stale_stats: добавить в pgcol_table
       s.n_mod_since_analyze
```

> ⚠️ По `pg.qry.stmt_mean_drift` и `pg.qry.top_movers` помнить про **вытеснение**
> `pg_stat_statements`: при переполнении `pg_stat_statements.max` запись исчезает, и
> `increase()` увидит это как сброс. Сам `queryid` стабилен между рестартами, но
> ряд — нет; для baseline-сравнений надёжнее recording rule, а не `offset` по сырой
> метрике.

---

## 4. Сводная карта: что к чему привязано

| Источник в PG | Привязка | Метки | Собирать с |
|---|:--:|---|---|
| `pg_is_in_recovery()`, `pg_postmaster_start_time()` | У → К | `pg_cluster, node` | всех узлов |
| `pg_stat_replication` | У+`application_name` | `+ application_name` | всех (каскад!) |
| `pg_stat_wal_receiver`, `pg_last_*` | У | `pg_cluster, node` | всех узлов |
| `pg_replication_slots` | У+`slot_name` | `+ slot_name` | **всех узлов** (не реплицируются) |
| `pg_stat_replication_slots` | У+`slot_name` | `+ slot_name` | всех узлов |
| `pg_stat_subscription[_stats]` | У+`subname` | `+ subname` | узла-подписчика |
| `pg_stat_wal`, `pg_stat_bgwriter`, `pg_stat_archiver` | У | `pg_cluster, node` | всех узлов |
| `pg_ls_waldir()` | У | `pg_cluster, node` | всех узлов |
| `pg_stat_activity`, `pg_locks` | У (+`mode`/`wait_event_type`/`backend_type`) | | всех узлов |
| `pg_prepared_xacts` | К | `pg_cluster` | одного узла |
| `pg_settings` | У+`name` | `+ name` | **всех узлов** (ради расхождений) |
| `pg_database`: `datfrozenxid`, `datminmxid` | **Б=** | `pg_cluster, db_name` | одного узла |
| `pg_database_size()`, `pg_tablespace_size()` | **Б=** | `pg_cluster, db_name`/`spcname` | одного узла |
| `pg_stat_database` (счётчики) | **Б~** | `pg_cluster, node, db_name` | всех, смотреть лидера |
| `pg_stat_database_conflicts` | **Б~** | `pg_cluster, node, db_name` | реплик |
| `pg_stat_io`, `pg_stat_slru` | У+ | | всех узлов |
| `pg_stat_progress_*` | У+`pid` | | всех узлов |
| 🎯 `pg_ls_archive_statusdir()` — **НОВОЕ** | У | `pg_cluster, node` | всех узлов |
| ◻ `pg_replication_origin_status` — **НОВОЕ** | У+`origin` | `+ origin` | узла-подписчика |
| 🎯 `pg_index.indisvalid`, `n_mod_since_analyze` — **НОВОЕ** | Б~ + объект | `+ schema, table, index` | лидера (namespace `pgcol_*`) |

**Оценка кардинальности** на 3 кластера × 3 узла × 5 БД: У-метрик ≈ 9 серий на метрику,
Б~ ≈ 45, Б= ≈ 15, У+`slot_name` — умножается на число слотов. Основной риск по
кардинальности — `pg_stat_io` (`backend_type × object × context` ≈ 30 строк на узел)
и `pg_settings` (если выгружать все ~350 GUC, а не отобранный список).

---

## 5. Особенности сбора (чтобы не наступить дважды)

**5.1. Запросы, безопасные для любой роли.** Один `queries.yaml` едет на лидера и на
реплики. Primary-only функции (`pg_current_wal_lsn`, `pg_walfile_name`) оборачивать в
`CASE WHEN pg_is_in_recovery() THEN NULL ELSE … END` — проверено, CASE не вычисляет
невыбранную ветку для volatile-функций. Для каскадной схемы «standby, который
отдаёт WAL» (ваш pg1) диффы в §B считать от `pg_last_wal_receive_lsn()`.

**5.2. NULL → 0.** postgres_exporter на NULL ругается и пропускает значение. Везде
`COALESCE(..., 0)`, иначе панели будут с дырами (особенно `*_lag` и `safe_wal_size`).

**5.3. LSN → число.** `pg_lsn` экспортёру не отдать: либо `pg_wal_lsn_diff(a,b)` для
дельты, либо `pg_wal_lsn_diff(lsn,'0/0')` для абсолютного значения.

**5.4. Текстовые состояния → код.** `wal_status`, `state`, `sync_state`, `wal_level`
отдавать и меткой (для таблиц), и числовым кодом (для порогов и алертов).

**5.5. Роль — метрика, не метка** (см. §2), иначе failover рвёт серии.

**5.6. `cache_seconds`.** Лёгкое (репликация, активность, слоты, wraparound) — `0…15`,
чтобы отставание было видно в реальном времени. Тяжёлое (`pg_ls_waldir()`,
`pg_database_size()` по всем БД, tablespaces) — `60…300`.

**5.7. Права.** Достаточно `GRANT pg_monitor` — проверено: `pg_ls_waldir()`,
`pg_stat_replication`, `pg_replication_slots` и полные тексты запросов в
`pg_stat_activity` читаются без суперпользователя. `pg_ls_archive_statusdir()`
(новая метрика `arch_ready_count`) по документации в том же списке «superuser или
`pg_monitor`», что и `pg_ls_waldir()` — на стенде не гонял, архивация там была
выключена. **Не проверено:** `pg_replication_origin_status` — если `pg_monitor` не
хватит, обёртка `SECURITY DEFINER`, а не суперпользователь экспортёру.

**5.8. Отдельный namespace.** Текущие `pgcol_*` — per-database/per-table. Кластерным
дать свой префикс (`pgcls_*`), чтобы дашборды не перепутались и можно было развести
`cache_seconds`.

**5.9. `queries.yaml` — DEPRECATED** в postgres_exporter v0.15 (есть warning в логах).
Если жить долго — смотреть на `--collector.custom_queries` / `sql_exporter` / `pgwatch`.

**5.10. Версии.** `pg_stat_io` — PG 16+; `pg_stat_wal` — PG 14+;
`pg_stat_subscription_stats` — PG 15+; `pg_stat_checkpointer` — PG 17+;
`conflicting` в слотах — PG 16+.

---

## 6. Чего postgres_exporter дать НЕ может

PostgreSQL по SQL не знает ни про ОС, ни про Patroni, ни про DCS. Без этих источников
дашборд «состояния кластера» будет с дырами.

| Нужно для оценки кластера | Треб. | Уровень | Откуда брать |
|---|---|:--:|---|
| Кто лидер **по версии Patroni/DCS**, число failover/switchover, статус member, paused-режим | 🎯 **M04** `pg.ha.primary_up`<br>🎯 **M01** `pg.cluster.leader_count` (авторитетно)<br>🎯 **M02** `pg.cluster.timeline_change` (счётчик) | К, У | **Patroni REST `/metrics`** (≥ 2.1, порт 8008): `patroni_primary`, `patroni_standby_leader`, `patroni_xlog_location`, `patroni_dcs_last_seen`, `patroni_pending_restart` |
| Здоровье **etcd** (кворум, leader changes) | 🎯 **M03** `pg.dcs.etcd_leader` | К | `/metrics` самого etcd + `patroni_dcs_last_seen` (потеря DCS → лидер уходит в read-only, а SQL об этом не скажет) |
| CPU, LA, RAM, swap, **свободное место под `pg_data`/`pg_wal`**, IO-latency, сеть | 🎯 **M37** `pg.io.fs_usage`<br>🎯 **M39** `pg.io.disk_latency`<br>🎯 **M41** `pg.host.mem_oom` | У | **node_exporter** — критично: «кончился диск» самая частая авария, а PG об этом не знает. OOM-kill: `node_vmstat_oom_kill` |
| Пулы, `cl_waiting`, `sv_active`, отказы пулера | 🎯 **M04** `pg.ha.primary_up` (часть «живой бэкенд на записи») | У | **pgbouncer_exporter** (`pgbouncer1` в стеке) |
| Успешность и возраст бэкапов (pgBackRest/WAL-G) | 🎯 **M14** `pg.bkp.last_success_age` | К | их отчёты/экспортёры (`backup1`) |
| **Успешность restore-теста** | 🎯 **M15** `pg.bkp.restore_test_age` | К | только собственный job: восстановить бэкап, прогнать проверку, выложить timestamp в textfile-collector node_exporter'а / pushgateway. Ни PG, ни pgBackRest сами это не измеряют |
| Ошибки по **SQLSTATE** (`53100` disk full, `XX00x` corruption) | 🎯 **M30** `pg.qry.sqlstate_error` | У | **нет SQL-источника вообще**: `pg_stat_database` разбивки по SQLSTATE не ведёт. Либо логи (`patroni-postgres-logging` + Loki/mtail), либо расширение `pg_stat_monitor` (в нём есть `sqlstate`) |
| Логи: FATAL, `too many connections`, checkpoint warnings | | У | ваш проект `patroni-postgres-logging` |

Минимальный набор job'ов: `postgres` (×N узлов) + `patroni` (×N) + `node` (×N) +
`pgbouncer` + `etcd`.

---

## 7. Черновик структуры дашборда «Состояние кластера»

Переменные: `$pg_cluster` (мульти-выбор), `$node`. В скобках — привязка панели.

| Секция | Ключевые панели | Требования |
|---|---|---|
| **1. Светофор кластеров** | таблица **по кластерам** (К): лидеров 1?, узлов живо, max lag, xid%, slots-warn. Ниже таблица **по узлам** (У): роль, uptime, версия, TL, conn%, lag | **M01** `cluster.leader_count`, **M02** `cluster.timeline_change`, **M04** `ha.primary_up`, **M24** `sess.conn_pct` |
| **2. Репликация** | replay lag в байтах и секундах (У+); состав sync/async (У); receive→replay diff (У); recovery conflicts (Б~); состояние wal_receiver (У) | **M07** `repl.async_lag`, **M06** `repl.sync_flush_lag`, **M05** `repl.sync_count`, **M08** `repl.standby_count` |
| **3. Слоты и WAL** | таблица слотов по всем узлам (У+); размер `pg_wal` (У); скорость генерации WAL (У); архиватор: failed + возраст + **очередь `.ready`** (У) | **M09** `repl.slot_retained`, **M10** `repl.log_slot_retained`, **M16** `wal.bytes_rate`, **M12** `arch.failed`, **M13** `arch.ready_queue` |
| **4. Предаварийное** | xid%/mxid% по БД — `max by (pg_cluster, db_name)` (Б=); oldest idle-in-xact (У); **горизонт xmin: сессия/слот/2PC** (У, У+, К); checksum failures (Б~); locks_not_granted (У) | **M19** `vac.xid_age`, **M20** `vac.antiwrap_running`, **M23** `sess.xmin_horizon`, **M25** `sess.idle_in_trx`, **M26** `sess.lock_waiters`, **M38** `io.checksum_fail` |
| **5. Нагрузка** | TPS commit/rollback **и rollback-ratio** с лидера (Б~ + `and on(...) is_primary == 1`); cache hit (Б~); active backends vs max_connections (У); wait_event_type (У+); deadlocks, temp (Б~); **долгие запросы** (У) | **M28** `qry.rollback_ratio`, **M29** `qry.long_running`, **M21** `vac.temp_bytes`, **M24** `sess.conn_pct` |
| **6. Checkpoint / IO** | timed vs req **и доля req** (У); write/sync time (У); buffers_backend, **backend_fsync** или `pg_stat_io` (У+); bgwriter (У) | **M17** `wal.ckpt_req_ratio`, **M18** `wal.backend_fsync` |
| **7. Конфигурация** | таблица GUC по узлам с подсветкой расхождений (У+`name`); pending_restart (У); флаги archive_mode / hot_standby_feedback / data_checksums (У); **`autovacuum_max_workers` как знаменатель** | **M22** `vac.workers_set` |
| **8. Операции** | прогресс vacuum и basebackup — видно подъём реплики Patroni (У+) | **M20** `vac.antiwrap_running` |
| **9. Размеры** | размер БД и кластера — `max by` (Б=); tablespaces (Б=); тренд и прогноз (`predict_linear`) | **M40** `io.growth` |
| **10. Логическая репликация** (новая) | подписки: ошибки применения, возраст `latest_end`, лаг origin, spill слотов (У+) | **M11** `subscription_origin`, **M10** `repl.log_slot_retained` |

> Секции **Запросы** и **Обслуживание объектов** из `required_metrics.md`
> (**M32** `qry.top_movers`, **M31** `qry.stmt_mean_drift`, **M27** `stat_statements`, `health.*`) на этот
> дашборд не выносятся — они уже есть в `pg-tables.json` (§3 K). Требования
> **M37** `io.fs_usage`, **M39** `io.disk_latency`, **M41** `host.mem_oom`, `bkp.*`, **M03** `dcs.etcd_leader`,
> **M30** `qry.sqlstate_error` требуют своих job'ов (§6): для них либо отдельная секция
> «Хост и DCS», либо отдельный дашборд.

---

## 8. Фильтры дашборда

Переменные `$pg_cluster` / `$node` / `$db_name`, выбор опорной метрики для
`label_values`, соглашение `pg_cluster = node` для standalone-серверов без Patroni и
правила «какой фильтр к какому уровню метрик» — в отдельном документе
[CLUSTER-FILTERS.md](CLUSTER-FILTERS.md).

---

## 9. Что дальше

> **Статус на 2026-10-26:** пункты 3–5 выполнены — `cluster-queries.yaml` написан,
> `scrape.yml` переведён на 4 job'а и 10 таргетов, `pg-cluster.json` собран и
> подключён к живому Patroni-кластеру. Подробности и отличия реализации — **§11**.

1. Согласовать объём: все группы A–K или сначала A–G (минимум «жив/здоров»).
2. Решить по §6: добавляем ли job'ы `patroni`, `etcd` и `node_exporter` — без них не
   будет видно ни факта failover, ни свободного места под WAL, и **8 требований из 41
   не закрываются принципиально** (§10).
3. Написать `postgres_exporter/cluster-queries.yaml`, namespace `pgcls_*` — это
   разблокирует **27 требований** (15 уже заложенных в заготовку дашборда + 12 без
   панелей), т.к. сейчас все `pgcls_*` в `pg-cluster.json` пустые.
4. Перевести `scrape.yml` на несколько таргетов с метками `pg_cluster` + `node`
   (+ `expected_standbys` / `expected_sync` — иначе `repl.standby_count` и
   `repl.sync_count` не с чем сравнивать).
5. Собрать `grafana/dashboards/pg-cluster.json` по §7.
6. По Б~-метрикам определиться: резать по `db_name` или держать агрегат по узлу
   (см. оценку кардинальности в §4).
7. Закрыть 🔧-пункты §10: 4 новых метрики в `cluster-queries.yaml`
   (`arch_ready_count`, `buffers_backend_fsync`, `long_running_count` +
   `autovacuum_antiwrap_running`, `origin_*`) и 2 добавления в существующий
   `queries.yaml` (`indisvalid`, `n_mod_since_analyze`).
8. Ответить на вопросы §10.3 — без них часть core-требований не реализуема.

---

## 10. Карта требований `required_metrics.md`

42 требования из [`required_metrics.md`](required_metrics.md) → метрика этого
документа (M42 добавлено позже остальных, см. §11.5). Ключ строки — идентификатор `Mnn` из `required_metrics.md`; по нему же
ищется панель на дашборде (заголовок начинается с `[Mnn]`). Статусы:

| | Значение | Шт. |
|:--:|---|:--:|
| ✅ | метрика описана выше **и** панель уже есть (`pg-cluster.json` — заготовка, `pg-tables.json` — рабочий) | 15 |
| 🟡 | метрика описана выше, **панели нет** | 12 |
| 🔧 | нужна **новая SQL-метрика** — описана выше с пометкой «НОВОЕ» | 6 |
| 🚫 | **из postgres_exporter недостижимо**, нужен другой источник — §6 | 8 |

> ⚠️ Статусы в этой таблице — **проектные** (ожидания на момент разбора требований).
> Фактическое состояние после подключения живого кластера — в **§11.4**: 25 требований
> закрыты живыми панелями, в том числе `pg.dcs.etcd_leader` и `pg.ha.primary_up`,
> которые здесь помечены 🚫 (их закрыли job'ы `patroni` и `etcd`, а не SQL).

### 10.1. Таблица соответствия

| ID | Требование | Раздел / приор. | Метрика(и) | Ст. |
|:--:|---|---|---|:--:|
| **M01** | `pg.cluster.leader_count` | Кластер / core | `node_is_primary` → `count by (pg_cluster) (… == 1)` (§A) | ✅ |
| **M02** | `pg.cluster.timeline_change` | Кластер / core | `node_timeline_id` + `changes()` (§A) | 🟡 |
| **M03** | `pg.dcs.etcd_leader` | Кластер / core | etcd `/metrics`, `patroni_dcs_last_seen` (§6) | 🚫 |
| **M04** | `pg.ha.primary_up` | Кластер / core | суррогат `node_is_primary == 1 and up == 1`; честно — `patroni_primary` + pgbouncer (§6) | 🚫 |
| **M05** | `pg.repl.sync_count` | Кластер / core | `repl_sync_standby_count` (§B); N — из `expected_sync` | 🟡 |
| **M06** | `pg.repl.sync_flush_lag` | Кластер / core | `repl_flush_lag_bytes/seconds{sync_state="sync"}` (§B) | 🟡 |
| **M07** | `pg.repl.async_lag` | Кластер / core | `repl_replay_lag_bytes/seconds` (§B) | ✅ |
| **M08** | `pg.repl.standby_count` | Кластер / core | `repl_standby_count` + `expected_standbys` (§B) | 🟡 |
| **M09** | `pg.repl.slot_retained` | Кластер / core | `slot_retained_bytes`, `slot_active`, `slot_wal_status_code`, `slot_safe_wal_size_bytes` (§D) | ✅ |
| **M10** | `pg.repl.log_slot_retained` | Обслуживание / ◻ | те же с `slot_type="logical"` + `slot_catalog_xmin_age`, `slot_spill_bytes` (§D) | 🟡 |
| **M11** | `pg.subscription_origin` | Обслуживание / ◻ | **`origin_remote_lsn`/`origin_local_lsn`** + `sub_apply_error_count` (§D) | 🔧 |
| **M12** | `pg.arch.failed` | Кластер / core | `archiver_failed_count` (§E) | ✅ |
| **M13** | `pg.arch.ready_queue` | Кластер / core | **`arch_ready_count`** (§E) | 🔧 |
| **M14** | `pg.bkp.last_success_age` | Кластер / core | pgBackRest/WAL-G (§6) | 🚫 |
| **M15** | `pg.bkp.restore_test_age` | Обслуживание / core | собственный restore-job → textfile/pushgateway (§6) | 🚫 |
| **M16** | `pg.wal.bytes_rate` | Кластер / core | `rate(wal_bytes)` (§E) | ✅ |
| **M17** | `pg.wal.ckpt_req_ratio` | Кластер / core | `ckpt_req` / (`ckpt_req`+`ckpt_timed`) (§E) | ✅ |
| **M18** | `pg.wal.backend_fsync` | Кластер / core | **`buffers_backend_fsync`**, PG 17 — `io_fsyncs` (§E) | 🔧 |
| **M19** | `pg.vac.xid_age` | Кластер / core | `db_xid_age`, `db_xid_pct`, `db_mxid_age` (§G) | ✅ |
| **M20** | `pg.vac.antiwrap_running` | Кластер / ☆ | **`autovacuum_antiwrap_running`** (§F) + `progress_vacuum_*` (§J) | 🔧 |
| **M21** | `pg.vac.temp_bytes` | Обслуживание / core | `db_temp_bytes`, `db_temp_files` (§H) | 🟡 |
| **M22** | `pg.vac.workers_set` | Обслуживание / core | `autovacuum_workers_running` / `setting_value{name="autovacuum_max_workers"}` (§F, §I) | 🟡 |
| **M23** | `pg.sess.xmin_horizon` | Обслуживание / core | `max` из `backend_xmin_age`, `slot_xmin_age`, `prepared_xact_age` (§G) | 🟡 |
| **M24** | `pg.sess.conn_pct` | Кластер / core | `connections_used_ratio` (§F) | 🟡 |
| **M25** | `pg.sess.idle_in_trx` | Обслуживание / core | `oldest_idle_in_xact_seconds` (панель есть), `backends_idle_in_xact` (нет) (§F) | ✅ |
| **M26** | `pg.sess.lock_waiters` | Инцидентный / core | `locks_not_granted`, `locks_by_mode`, `waiting_by_event_type` (§F) | ✅ |
| **M27** | `pg.stat_statements` | Обслуживание / ◻ | `pgcol_statement_*` (§K) | ✅ |
| **M28** | `pg.qry.rollback_ratio` | Запросы / core | `db_xact_rollback` / (`commit`+`rollback`) с лидера (§H) | 🟡 |
| **M29** | `pg.qry.long_running` | Запросы / core | `oldest_query_age_seconds` + **`long_running_count`** (§F) | 🟡 |
| **M30** | `pg.qry.sqlstate_error` | Запросы / core | SQL-источника нет: логи или `pg_stat_monitor` (§6) | 🚫 |
| **M31** | `pg.qry.stmt_mean_drift` | Запросы / ☆ | `pgcol_statement_mean_time_ms` + `offset 1d` (§K) | ✅ |
| **M32** | `pg.qry.top_movers` | Запросы / core | `topk(increase(pgcol_statement_total_time_ms))` (§K) | ✅ |
| **M33** | `pg.health.unused_indexes` | Обслуживание / core | `pgcol_index_idx_scan == 0` + `pgcol_index_size_bytes` (§K) | ✅ |
| **M34** | `pg.health.index_bloat` | Обслуживание / ☆ | `pgcol_index_frag_bloat_ratio` (§K) | ✅ |
| **M35** | `pg.health.invalid_indexes` | Обслуживание / core | **`pgcol_index_is_valid`** (§K) | 🔧 |
| **M36** | `pg.health.stale_stats` | Обслуживание / core | `pgcol_table_last_autoanalyze_ts` + **`n_mod_since_analyze`** (§K) | 🔧 |
| **M37** | `pg.io.fs_usage` | IO / core | node_exporter (§6) | 🚫 |
| **M38** | `pg.io.checksum_fail` | IO / core | `db_checksum_failures` (§H) | 🟡 |
| **M39** | `pg.io.disk_latency` | IO / core | node_exporter; суррогат `db_blk_read_time`, `io_*` (§H, §6) | 🚫 |
| **M40** | `pg.io.growth` | IO / core | `db_size_bytes`, `cluster_size_bytes`, `tablespace_size_bytes` + `predict_linear` (§H) | ✅ |
| **M41** | `pg.host.mem_oom` | IO / core | node_exporter `node_vmstat_oom_kill` + логи (§6) | 🚫 |
| **M42** | `pg.qry.qps` | Запросы / core | `pgcls_stmt_calls` (`pg_stat_statements`, выключено) + оценка по `db_xact_*` | 🔧 |

Распределение по разделам требований: Кластер — 18, Обслуживание — 12, Запросы — 5,
IO — 5, Инцидентный — 1. Приоритеты: 35 core, 3 nice-to-have
(`vac.antiwrap_running`, `health.index_bloat`, `qry.stmt_mean_drift`), 3 без
приоритета (`repl.log_slot_retained`, `subscription_origin`, `stat_statements`).

### 10.2. Замечания к списку требований

Фиксирую расхождения, которые видны при сопоставлении с метриками PG — чтобы они не
всплыли на приёмке.

1. **Опечатки в именах:** `pg,sess,idle_in_trx` и `pg.qry,stmt_mean_drift` (запятые
   вместо точек), `pg.subscription_origin` (пробел после `pg.`).
2. **`pg.vac.temp_bytes` лежит не в своей группе.** Это `pg_stat_database.temp_bytes`
   — спиллы из-за `work_mem`; к вакууму отношения не имеет. Логичнее
   `pg.qry.temp_bytes` или `pg.sess.temp_bytes`.
3. **`pg.repl.log_slot_retained` — не отдельная метрика**, а `slot_retained_bytes` с
   `slot_type="logical"`. Отдельный SQL под неё писать не нужно.
4. **`pg.vac.xid_age` — метрика уровня БД, а не узла** (Б= в терминах §1): значение
   реплицируется и одинаково на всех узлах, на дашборде обязателен
   `max by (pg_cluster, db_name)`, иначе N одинаковых линий.
5. **Раздел `IO` смешивает два источника:** `fs_usage`, `disk_latency`, `mem_oom` —
   это хост (node_exporter), `checksum_fail` и `growth` — это PostgreSQL. На дашборде
   это две разные группы панелей, а не одна.
6. **`pg.bkp.restore_test_age` отнесён к «Обслуживанию»**, хотя парный
   `pg.bkp.last_success_age` — к «Кластеру». Группу бэкапов стоит сделать одну.
7. **Пять разделов требований против двух дашбордов:** «Обслуживание» + «Запросы» ≈
   `pg-tables.json`, «Кластер» ≈ `pg-cluster.json`, а «IO» и «Инцидентный» не покрыты
   ничем. Нужно решение: отдельные дашборды или секции в существующих (§7).
8. **У трёх пунктов не указан приоритет** (`repl.log_slot_retained`,
   `subscription_origin`, `stat_statements`) — считаю их core-минус, т.е. делаю после
   core.

### 10.3. Открытые вопросы (блокируют core-требования)

1. **`pg.repl.sync_count < N` — откуда N?** Предлагаю метку `expected_sync` в
   scrape-конфиге (аналогично `expected_standbys`, `CLUSTER-FILTERS.md` §6.3) либо
   парсинг `synchronous_standby_names` из `pg_settings`. Без этого порог не задать.
2. **`pg.qry.sqlstate_error` — какой источник?** Логи (`patroni-postgres-logging` +
   Loki/mtail) или расширение `pg_stat_monitor`. Второе даёт готовую метку `sqlstate`,
   но это сторонний модуль в `shared_preload_libraries`.
3. **`pg.bkp.*` — какой инструмент бэкапа в проде** (pgBackRest / WAL-G / своё) и есть
   ли у него экспортёр? От этого зависит, писать ли свой textfile-коллектор.
4. **`pg.subscription_origin` — что именно мерим:** лаг origin-а на подписчике или
   ошибки применения? Сейчас заложено и то, и другое (§D).
5. **Добавляем ли job'ы `patroni`, `etcd`, `node_exporter`?** Без них 8 требований
   (6 из них core: `dcs.etcd_leader`, `ha.primary_up`, `bkp.*`, `io.fs_usage`,
   `io.disk_latency`, `host.mem_oom`) закрыть нечем — это не вопрос дашборда, а
   вопрос состава стека.

---

## 11. Реализация: стенд `pg-cluster` (что собрано и как называется)

Собрано и проверено на живом Patroni-кластере из `../../dialog/dba/patroni_cluster`:
**Patroni 4.1.5, PostgreSQL 16.15, scope `pg-cluster`**, узлы pg1 (лидер) / pg2 / pg3
(streaming, async), etcd×3 с mTLS, pgbouncer1, subscriber, backup1.

### 11.1. Состав сбора

| Файл | Что делает |
|---|---|
| `postgres_exporter/cluster-queries.yaml` | 17 namespace `pgcls_*` → **103 метрики**; один файл на все роли (лидер и реплики), проверен на pg1 и pg2 |
| `victoriametrics/scrape.yml` | 4 job'а, 10 таргетов: `postgres` (pg1/pg2/pg3-exporter), `patroni` (pgN:8008), `etcd` (etcdN:2379, mTLS), `postgres-tables` (фикстура стека) |
| `compose.yaml` | 3 экспортёра (по одному на узел) + VictoriaMetrics в сети `patroni-net` (external) |
| `grafana/dashboards/pg-cluster.json` | 11 секций, 67 панелей; 110 запросов отвечают данными |

Job `postgres-tables` выделен специально: якорь фильтров `up{job="postgres"}`
(`CLUSTER-FILTERS.md` §2) должен видеть **только узлы Patroni**, иначе одиночная
фикстура попадёт в светофор парка как «кластер без лидера».

**Роль для экспортёра.** Сейчас DSN экспортёров — суперпользователь тестового стенда
(`postgres`), переопределяется через `.env`:

```sql
-- на лидере, один раз; роль реплицируется на pg2/pg3 через WAL
CREATE ROLE monitoring LOGIN PASSWORD '<пароль>';
GRANT pg_monitor TO monitoring;
```
```ini
# monitoring/.env
PG_MON_USER=monitoring
PG_MON_PASSWORD=<пароль>
```
Патрони эту роль не знает — при повторном bootstrap кластера её нужно создать снова
(или добавить в плейбук `02_patroni_playbook.yml`).

### 11.2. Фактические имена метрик (отличия от §3)

postgres_exporter собирает имя как `<namespace>_<колонка>`, а namespace — это **одна
SQL-строка на запрос**. Из этого три отличия от «проектных» имён выше; ориентироваться
при написании панелей и алертов нужно на этот столбец.

| В §3 | В реализации | Почему |
|---|---|---|
| `repl_standby_count`, `repl_sync_standby_count` | **`pgcls_node_standby_count`**, **`pgcls_node_sync_standby_count`** | namespace `pgcls_repl` занят построчными метриками получателей. Если считать их тем же запросом, при 0 получателей метрика **исчезнет** вместо «0» — ровно в аварии «реплика отцепилась». Поэтому счётчики живут в узловом запросе, который всегда возвращает строку |
| `arch_ready_count` | **`pgcls_archiver_ready_count`**, `pgcls_archiver_done_count` | один namespace на `pg_stat_archiver` + `pg_ls_archive_statusdir()` |
| `connections_used_ratio`, `locks_not_granted`, `oldest_*`, `backends_*`, `autovacuum_workers_running`, `prepared_xacts_count`, `backend_xmin_age`, `long_running_count` | **`pgcls_sess_*`**: `conn_used_pct`, `locks_not_granted`, `oldest_query_age_seconds`, `oldest_idle_in_xact_seconds`, `backends_idle_in_xact`, `autovacuum_workers_running`, `autovacuum_antiwrap_running`, `backend_xmin_age`, `prepared_xacts_count`, `long_running_60s`, `long_running_300s` | всё это один запрос к `pg_stat_activity` (+ `pg_locks`, `pg_prepared_xacts`), namespace `pgcls_sess`. Вместо метки `bucket` — две колонки-порога: проще и дешевле по кардинальности |
| `node_timeline_id` | **`patroni_postgres_timeline`** | `pg_control_checkpoint()` по умолчанию только для суперпользователя, а `pg_walfile_name()` падает в recovery. Timeline берём у Patroni — он и есть источник истины по failover |
| `locks_by_mode` | **`pgcls_locks_count`** с метками `mode` и `granted` | отдельный namespace `pgcls_locks`: построчный разрез `pg_locks`, тогда как `pgcls_sess_locks_not_granted` — суммарный счётчик одной строкой. `granted` добавлена сверх проекта: без неё «ждут» и «держат» в одном числе, а это разные события |
| `cluster_size_bytes` | `sum(max by (db_name) (pgcls_db_size_bytes))` | считается в Grafana, отдельная метрика не нужна |

Экспортёр добавляет к `pgcls_*` свою метку `server="pgN:5432"` — в панелях она не
используется, в таблицах выброшена трансформацией.

### 11.3. Что на стенде пусто и почему это не поломка

Проверено на живом кластере; в панелях эти случаи подписаны:

| Пусто | Причина | Что включить, чтобы увидеть данные |
|---|---|---|
| Архиватор, очередь `.ready` | `archive_mode=off` (после PITR-демо) | `patronictl edit-config` → `archive_mode: on` + `archive_command` |
| Удержанный лаг sync-реплики | `synchronous_standby_names` пуст, все реплики async | `synchronous_standby_names: '*'` или `ANY 1 (pg2,pg3)` |
| WAL write/sync time, `blk_*_time` | `track_io_timing=off` | `track_io_timing: on` |
| Подписки и origin (секция 11) | `pg_subscription` пуст (контейнер `subscriber` поднят, но подписка не создана) | создать подписку на `subscriber` |
| Прогресс vacuum / basebackup | операции не идут | норма; заполнится при `VACUUM FREEZE` и при подъёме реплики Patroni |
| Расхождения GUC | конфиги узлов идентичны | норма |
| `pgcol_statement_*` для `pg-cluster` | на кластере `shared_preload_libraries` пуст — `pg_stat_statements` не загружен | добавить в Patroni-конфиг; сейчас эти метрики есть только у фикстуры стека |
| Точный QPS (M42), серия «pg_stat_statements» в сводке | то же: расширения нет (в `pg_available_extensions` оно есть, но не загружено) | `edit-config` → `shared_preload_libraries: pg_stat_statements`, рестарт узлов, `CREATE EXTENSION`, затем раскомментировать блок `pgcls_stmt` в `cluster-queries.yaml` |

Заодно подтвердилось §D: **слоты не реплицируются** — на pg2 висят неактивные слоты
`pg1` и `pg3` (остаток от прошлой роли, `retained_bytes` ≈ 6 КБ), и в таблице слотов
они видны именно потому, что панель игнорирует `$node`.

### 11.4. Статус требований после подключения

Трассировка по идентификаторам `Mnn` (`required_metrics.md`): на дашборде ID стоит в
начале заголовка панели, так что любую строку таблицы можно проверить поиском по
заголовкам.

| | ID | Шт. | Комментарий |
|:--:|---|:--:|---|
| ✅ панель + данные | M01–M05, M07–M10, M12, M13, M16–M26, M28, M29, M38–M40 | **27** | M12, M13 и M39 отдают нули: `archive_mode=off`, `track_io_timing=off` — метрики собираются, значения вырожденные |
| 🟡 панель есть, серий нет | M06, M11 | **2** | нет sync-реплики и нет подписок — см. §11.3 |
| 🔧 нужны правки `queries.yaml` | M35, M36 | **2** | `indisvalid`, `n_mod_since_analyze` — дашборд «Обслуживание» (§3 K) |
| ⚠️ есть у фикстуры, на кластере нужен `pg_stat_statements` | M27, M31, M32 (+ M33, M34 — per-object) | **5** | на `pg-cluster` `shared_preload_libraries` пуст |
| 🚫 нужен другой источник | M14, M15 (бэкапы), M30 (логи/`pg_stat_monitor`), M37, M41 (node_exporter) | **5** | §6 |
| 🔧 панель есть, точного источника нет | M42 | **1** | QPS: панель в сводке работает на оценке по транзакциям, точная серия появится после включения `pg_stat_statements` |

Итого 27 + 2 + 2 + 5 + 5 + 1 = 42.

На дашборде `pg-cluster` присутствуют **29 идентификаторов** (27 ✅ + 2 🟡); остальные
12 (M14, M15, M27, M30–M37, M41) на него намеренно не выносились — об этом написано в
панели «Как читать дашборд».

Заголовки панелей `pg-tables.json` («Обслуживание») тоже помечены — там живут
**M21, M27, M28, M32, M33, M34, M36, M40**. Итого по двум дашбордам закрыты панелями
**34 требования из 41**; без панели остаются 7: M14, M15, M30, M37, M41 (нужен другой
источник), **M31** (метрика `pgcol_statement_mean_time_ms` есть, не хватает панели со
сравнением `offset 1d`) и **M35** (метрики `indisvalid` ещё нет). Таблица «где искать
ID» — в `required_metrics.md`.

Следующий шаг по покрытию — `node_exporter` на pg1/pg2/pg3: он закрывает M37, M39 и
M41, а «кончился диск под `pg_wal`» — самая частая авария, про которую PostgreSQL по
SQL не знает (§6).

### 11.5. Секция 0 «Сводка»

Добавлена над «1. Обзор»: график нагрузки на всю ширину, под ним два графика
блокировок по 12 колонок — «сколько работы, с какой скоростью, не стоит ли она
в очереди и из-за чего именно».

| Панель | ID | Что показывает |
|---|---|---|
| Нагрузка: TPS и QPS с лидера | M28 + **M42** | **объединённый** график, 4 серии: `commit/с` и `rollback/с` в разрезе БД (тот же запрос, что в секции 6), **точный QPS** = `rate(sum(pg_stat_statements.calls))` (пусто, пока расширение не включено) и **оценка QPS** = сумма `commit+rollback` по всем БД. TPS и QPS — величины одной размерности (операций в секунду), поэтому делят одну ось: видно и профиль нагрузки, и во сколько операторов укладывается транзакция |
| Блокировки без granted | M26 | тот же график, что в секции 5 — `pg_locks WHERE NOT granted` по узлам. Рядом с TPS/QPS он объясняет провал темпа: нагрузка упала не сама, а потому что запросы стоят в очереди за блокировкой |
| Блокировки по типам (mode) | M26 | **новая метрика** `pgcls_locks_count{mode, granted}`: `count(*) FROM pg_locks GROUP BY mode, granted`, с накоплением. Серии «ждут» — разрез панели слева (какой режим стоит в очереди), серии «держат» — рабочий фон; всплеск `AccessExclusiveLock` на нём означает DDL или `VACUUM FULL`, который сейчас блокирует остальных |

**Намеренных дублей на дашборде два** — M28 (секция 6) и M26 (секция 5); оба вынесены в
сводку по запросу. M42 (QPS) живёт только в сводке, внутри объединённой панели: отдельной
секции «Запросы» на кластерном дашборде нет, она на `pg-tables`. Остальные панели существуют в одном экземпляре. В сводке лежат
только графики-индикаторы: «кто держит» и «что именно блокирует» остаётся в профильных
секциях (`locks_by_mode`, `wait_event_type`, idle in transaction), чтобы сводка не
превращалась во второй дашборд.

Про оценку честно: при autocommit-нагрузке «транзакций в секунду» и есть QPS, потому
что каждый запрос — своя транзакция. Как только в нагрузке появятся явные
`BEGIN … COMMIT` с несколькими операторами, оценка станет **занижать** QPS, и расхождение
двух серий на одной панели как раз и покажет, насколько. Поэтому серии живут вместе,
а не в разных панелях.

Требование **M42** (`pg.qry.qps`) заведено в `required_metrics.md` первым свободным
номером: QPS в исходной постановке не было, а правило там — номера не переиспользовать.
