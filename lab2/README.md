# Лабораторная работа номер 2 по дисицплине "Распределенные системы хранения данных" - Отчёт

## Информация

Университет ИТМО, Факультет программной инженерии и компьютерной техники

Санкт-Петербург, 2025

ФИО: Билошицкий Михаил Владимирович

Преподаватель: Николаев Владимир Вячеславович

Группа: P3316

Вариант: 78523

## Ход выполнения работы

### Подготовка окружения

1.  **Создание директорий:**
    ```bash
    # Директория для кластера БД
    mkdir -p $HOME/onb52

    # Директория для WAL-файлов
    mkdir -p $HOME/nwx49

    # Директории для временных табличных пространств
    mkdir -p $HOME/syi73
    mkdir -p $HOME/poe29

    # Директория для кастомного табличного пространства (для данных чата)
    mkdir -p $HOME/pgdata_custom_ts

    # Проверим созданные директории
    ls -ld $HOME/onb52 $HOME/nwx49 $HOME/syi73 $HOME/poe29 $HOME/pgdata_custom_ts
    ```

### Этап 1. Инициализация кластера БД

```bash
initdb -D $HOME/onb52 \
       -X $HOME/nwx49 \
       --locale=ru_RU.KOI8-R \
       --encoding=KOI8-R \
       --auth-local=peer \
       --auth-host=scram-sha-256
```

*   `-D $HOME/onb52`: Директория кластера.
*   `-X $HOME/nwx49`: Директория для WAL-файлов.
*   `--locale=ru_RU.KOI8-R`: Русская локаль.
*   `--encoding=KOI8-R`: Кодировка для баз данных по умолчанию.
*   `--auth-local=peer`: Для Unix-domain сокет соединений использовать аутентификацию `peer`.
*   `--auth-host=scram-sha-256`: Для TCP/IP соединений использовать аутентификацию `scram-sha-256` (требует пароль).

---

### Этап 2. Конфигурация и запуск сервера БД

1.  **Редактирование `postgresql.conf`:**
    Файл находится в `$HOME/onb52/postgresql.conf`.
    Откройте его текстовым редактором (например, `nano $HOME/onb52/postgresql.conf`) и измените/добавьте следующие строки:

    ```ini
    #------------------------------------------------------------------------------
    # CONNECTIONS AND AUTHENTICATION
    #------------------------------------------------------------------------------

    # - Connection Settings -

    listen_addresses = 'localhost'  # Слушать только localhost
    port = 9523                     # Порт сервера
    max_connections = 20            # Максимальное количество подключений

    #------------------------------------------------------------------------------
    # RESOURCE USAGE (PLANNER)
    #------------------------------------------------------------------------------

    # - Memory -

    shared_buffers = 512MB          # OLAP: Рекомендуется 25% RAM, для малого сервера 512MB - хороший старт
                                    # для пакетной обработки 256MB
    temp_buffers = 16MB             # OLAP: Для временных таблиц в сессии
    work_mem = 64MB                 # OLAP: На одну операцию сортировки/хеширования. 6 пользователей * ~2-4 операции = ~1GB при пике
                                    # Это позволит обрабатывать части пакетов по 256МБ.

    # - Kernel Resource Usage -

    effective_cache_size = 1GB      # OLAP: Оценка общего кэша (shared_buffers + OS cache)

    #------------------------------------------------------------------------------
    # WRITE AHEAD LOG
    #------------------------------------------------------------------------------

    # - Settings -

    wal_buffers = 16MB              # Размер буфера WAL, обычно -1 (авто: 1/32 shared_buffers) или фиксированное значение.

    # - Checkpoints -

    checkpoint_timeout = 30min      # OLAP: Увеличиваем интервал для снижения I/O от чекпоинтов

    #------------------------------------------------------------------------------
    # ERROR REPORTING AND LOGGING
    #------------------------------------------------------------------------------

    # - Where to Log -

    log_destination = 'stderr'      # Стандартный вывод ошибок, будет перенаправлен pg_ctl
    logging_collector = on          # Включить сборщик логов
    log_directory = 'log'           # Директория для логов (относительно DATA_DIR)
    log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log' # Формат имени файла лога с датой и временем

    # - When to Log -

    log_min_messages = info         # Уровень сообщений info
    log_min_error_statement = error # Логировать запросы, вызвавшие ошибки уровня error и выше

    # - What to Log -
    log_connections = on            # Логировать подключения
    log_disconnections = on         # Логировать завершение сессий
    log_duration = off              # Логировать длительность каждого завершенного оператора
    log_min_duration_statement = 0  # Логировать длительность выполнения ВСЕХ команд (0 мс) (ТРЕБУЕТСЯ)
    log_line_prefix = '%m [%p] %u@%d [%a] ' # Префикс для строк лога: время, PID, пользователь@база, приложение

    #------------------------------------------------------------------------------
    # CLIENT CONNECTION DEFAULTS
    #------------------------------------------------------------------------------

    # - Locale and Formatting -

    lc_messages = 'ru_RU.KOI8-R'
    lc_monetary = 'ru_RU.KOI8-R'
    lc_numeric = 'ru_RU.KOI8-R'
    lc_time = 'ru_RU.KOI8-R'

    #------------------------------------------------------------------------------
    # LOCK MANAGEMENT
    #------------------------------------------------------------------------------

    commit_delay = 10000            # OLAP: 10 мс, может помочь сгруппировать коммиты при пакетной записи

    #------------------------------------------------------------------------------
    # VERSION/PLATFORM COMPATIBILITY
    #------------------------------------------------------------------------------

    # - Previous PostgreSQL Versions -

    fsync = on                    # Принудительная синхронизация с диском (важно для надежности)

    # - Other Platforms and Clients -

    password_encryption = scram-sha-256

    temp_tablespaces = 'ts_temp1, ts_temp2'
    ```

2.  **Редактирование `pg_hba.conf`:**
    Файл находится в `$HOME/onb52/pg_hba.conf`.

    ```ini
    # TYPE  DATABASE        USER            ADDRESS                 METHOD

    # "local" is for Unix domain socket connections only
    local   all             all                                     peer
    # IPv4 local connections:
    host    all             all             127.0.0.1/32            scram-sha-256
    # IPv6 local connections:
    host    all             all             ::1/128                 scram-sha-256
    ```

3.  **Запуск сервера:**

    ```bash
    pg_ctl -D $HOME/onb52 -l $HOME/pg_server.log start
    ```
    *   `-D $HOME/onb52`: Указывает на директорию кластера.
    *   `-l $HOME/pg_server.log`: Записывать логи запуска/остановки сервера в этот файл.
    *   `start`: Команда для запуска.

    Проверить статус:
    ```bash
    pg_ctl -D $HOME/onb52 status
    ```

4.  **Установка пароля для суперпользователя `postgres0` (для TCP/IP подключений):**
    Пользователь ОС `postgres0` является суперпользователем PostgreSQL в данном кластере.

    ```bash
    # Подключаемся через Unix-сокет (peer аутентификация)
    psql -p 9523 -d postgres # или просто psql -p 9523

    # Внутри psql выполняем команду для установки пароля
    alter user postgres0 password 'SuperSekretPa$$wOrd';
    \q
    ```

5.  **Демонстрация работы подключений:**

    *   **Unix-domain сокет (peer):**
        ```bash
        psql -p 9523 -d postgres -c "select current_user, session_user;"
        ```
        Эта команда должна успешно выполниться без запроса пароля и показать пользователя `postgres0`.

    *   **Сокет TCP/IP (localhost, scram-sha-256):**
        ```bash
        psql -h 127.0.0.1 -p 9523 -U postgres0 -d postgres -c "select current_user, session_user;"
        ```
        Эта команда должна запросить пароль `SuperSekretPa$$wOrd`.

6.  **Демонстрация расположения WAL-файлов:**

    ```bash
    ls -la $HOME/nwx49
    ```

    Также можно проверить параметр сервера:
    ```bash
    psql -p 9523 -d postgres -c "show wal_segment_size;" # Показывает размер сегмента WAL
    psql -p 9523 -U postgres0 -h 127.0.0.1 -d postgres -c "show data_directory;" # Показывает data_directory
    ```
---

### Этап 3. Дополнительные табличные пространства и наполнение базы

1.  **Создание табличных пространств:**
    Подключаемся к серверу от имени суперпользователя `postgres0` (можно через Unix-сокет, так как мы на том же узле):

    ```bash
    psql -p 9523 -d postgres
    ```

    Внутри `psql` выполняем:

    ```sql
    -- создаем табличные пространства для временных объектов
    create tablespace ts_temp1 location '/var/db/postgres0/syi73';
    create tablespace ts_temp2 location '/var/db/postgres0/poe29';

    -- создаем табличное пространство для данных чата
    create tablespace ts_chatdata location '/var/db/postgres0/pgdata_custom_ts';

    -- проверяем созданные табличные пространства
    select spcname, pg_tablespace_location(oid) as location from pg_tablespace;
    ```

2.  **Настройка `temp_tablespaces` на уровне сервера:**
    Это укажет PostgreSQL использовать созданные табличные пространства для временных файлов.

    ```sql
    alter system set temp_tablespaces = 'ts_temp1, ts_temp2';
    select pg_reload_conf();
    \q
    ```

    ```sql
    psql -p 9523 -d postgres # переподключение к сессии
    show temp_tablespaces;
    ```

3.  **Создание новой базы данных `loudblackuser`:**

    ```sql
    create database loudblackuser
        template template1
        encoding 'KOI8-R'
        locale 'ru_RU.KOI8-R';
        owner postgres0
    ```
    Проверим:
    ```sql
    \l loudblackuser
    ```

4.  **Создание новой роли `chat_app_user`:**
    Придумаем имя `chat_app_user` и пароль `ChatAppPa$$wOrd`.

    ```sql
    create role chat_app_user with
        login
        password 'ChatAppPa$$wOrd';

    -- предоставляем права на подключение к базе loudblackuser
    grant connect on database loudblackuser to chat_app_user;

    -- Предоставляем право создавать объекты в табличном пространстве ts_chatdata
    grant create on tablespace ts_chatdata to chat_app_user;

    -- Теперь переключаемся на базу loudblackuser для выдачи прав на схему
    \c loudblackuser

    -- предоставляем права на использование схемы public и создание объектов в ней
    grant usage, create on schema public to chat_app_user;
    ```

5.  **Подключение от имени `chat_app_user` и создание структуры БД:**
    ```bash
    psql -h 127.0.0.1 -p 9523 -U chat_app_user -d loudblackuser
    ```

    Внутри `psql` (теперь мы работаем как `chat_app_user`):

    ```sql
    create table users (
        user_id serial primary key,
        username varchar(50) not null unique,
        created_at timestamptz default now()
    ) tablespace ts_chatdata;

    create table chats (
        chat_id serial primary key,
        chat_name varchar(100) not null,
        created_at timestamptz default now()
    ) tablespace ts_chatdata;

    create table chat_participants (
        chat_id int not null references chats(chat_id) on delete cascade,
        user_id int not null references users(user_id) on delete cascade,
        joined_at timestamptz default now(),
        primary key (chat_id, user_id)
    ) tablespace ts_chatdata;

    create table messages (
        message_id bigserial primary key,
        chat_id int not null references chats(chat_id) on delete cascade,
        user_id int not null references users(user_id) on delete set null, -- если юзер удален, сообщения остаются от "unknown"
        content text not null,
        sent_at timestamptz default now()
    ) tablespace ts_chatdata;

    -- проверим, что таблицы созданы и где они находятся
    select tablename, tablespace from pg_tables where schemaname = 'public';
    ```

6.  **Наполнение таблиц тестовыми данными (от имени `chat_app_user`):**

    ```sql
    -- добавляем пользователей
    insert into users (username) values
        ('alice'),
        ('bob'),
        ('charlie');

    -- добавляем чаты
    insert into chats (chat_name) values
        ('обсуждение проекта x'),
        ('разговоры о погоде');

    -- добавляем участников в чаты
    -- alice и bob в чате 'обсуждение проекта x'
    insert into chat_participants (chat_id, user_id) values
        ((select chat_id from chats where chat_name = 'обсуждение проекта x'), (select user_id from users where username = 'alice')),
        ((select chat_id from chats where chat_name = 'обсуждение проекта x'), (select user_id from users where username = 'bob'));

    -- charlie в чате 'разговоры о погоде'
    insert into chat_participants (chat_id, user_id) values
        ((select chat_id from chats where chat_name = 'разговоры о погоде'), (select user_id from users where username = 'charlie'));

    -- alice также в чате 'разговоры о погоде'
    insert into chat_participants (chat_id, user_id) values
        ((select chat_id from chats where chat_name = 'разговоры о погоде'), (select user_id from users where username = 'alice'));


    -- добавляем сообщения
    -- в чат 'обсуждение проекта x'
    insert into messages (chat_id, user_id, content) values
        ((select chat_id from chats where chat_name = 'обсуждение проекта x'), (select user_id from users where username = 'alice'), 'привет, боб! как дела с задачей?'),
        ((select chat_id from chats where chat_name = 'обсуждение проекта x'), (select user_id from users where username = 'bob'), 'привет, элис! почти готово, остались тесты.');

    -- в чат 'разговоры о погоде'
    insert into messages (chat_id, user_id, content) values
        ((select chat_id from chats where chat_name = 'разговоры о погоде'), (select user_id from users where username = 'charlie'), 'сегодня отличный день!'),
        ((select chat_id from chats where chat_name = 'разговоры о погоде'), (select user_id from users where username = 'alice'), 'да, солнечно, но ветрено.');

    -- проверим наполнение
    select * from users;
    select * from chats;
    select * from chat_participants;
    select * from messages;
    ```

7.  **Вывод списка всех табличных пространств кластера и содержащиеся в них объекты (красиво):**

    Подключаемся как суперпользователь `postgres0` к служебной базе `postgres` для получения общей информации о кластере:
    ```bash
    psql -p 9523 -d postgres
    ```

    Выполняем запрос:
    ```sql
    -- Cписок всех табличных пространств кластера:
    select
        ts.spcname as "имя табличного пространства",
        pg_catalog.pg_get_userbyid(ts.spcowner) as "владелец",
        pg_catalog.pg_tablespace_location(ts.oid) as "расположение",
        pg_catalog.pg_size_pretty(pg_catalog.pg_tablespace_size(ts.oid)) as "общий размер на диске"
    from
        pg_catalog.pg_tablespace ts
    order by
        ts.spcname;
    ```

    Теперь подключаемся к базе `loudblackuser`, чтобы посмотреть объекты внутри неё:
    ```bash
    psql -p 9523 -U postgres0 -d loudblackuser
    ```

    Выполняем запрос:
    ```sql
    -- Список всех табличных пространств и объектов внутри них
    select
        spc.spcname as "табличное пространство",
        string_agg(distinct obj.object_name, ', ' order by obj.object_name) as "объекты в табличном пространстве (в текущей БД)"
    from
        pg_catalog.pg_tablespace spc -- Все физические ТП кластера
    left join
        (
            -- Подзапрос для объектов с учетом фильтров по типу и схеме
            select
                obj_details.final_physical_oid, -- Итоговый OID физического ТП объекта
                obj_details.object_name         -- Полное имя объекта (схема.имя)
            from
                (
                    -- Детализация объекта: определение OID его фактического ТП, имени и схемы
                    select
                        case
                            when cl.reltablespace = 0 then -- Для объектов в ТП по умолчанию текущей БД:
                                coalesce(
                                    -- Определяем OID фактического ТП по умолчанию для текущей БД
                                    (select nullif(pdb.dattablespace, 0) from pg_catalog.pg_database pdb where pdb.datname = current_database()),
                                    -- Если для БД ТП не задан (dattablespace=0), используем OID 'pg_default'
                                    (select pts.oid from pg_catalog.pg_tablespace pts where pts.spcname = 'pg_default')
                                )
                            else cl.reltablespace -- Иначе - OID ТП, явно указанный для объекта
                        end as final_physical_oid,
                        ns.nspname || '.' || cl.relname as object_name,
                        ns.nspname as object_schema_name -- Имя схемы объекта (для фильтрации)
                    from pg_catalog.pg_class cl -- Объекты из pg_class
                    join pg_catalog.pg_namespace ns on ns.oid = cl.relnamespace
                    where cl.relkind in ('r', 'i', 'S', 'm', 't')
                ) obj_details
            join pg_catalog.pg_tablespace obj_ts on obj_ts.oid = obj_details.final_physical_oid -- Имя ТП объекта (нужно для фильтрации по имени ТП)
        ) obj on spc.oid = obj.final_physical_oid -- Соединяем ТП с отфильтрованными объектами
    group by spc.oid, spc.spcname
    order by spc.spcname;
    ```
---
