# Лабораторная работа номер 3 по дисицплине "Распределенные системы хранения данных" - Отчёт

## Информация

Университет ИТМО, Факультет программной инженерии и компьютерной техники

Санкт-Петербург, 2025

ФИО: Билошицкий Михаил Владимирович

Преподаватель: Николаев Владимир Вячеславович

Группа: P3316

Вариант: 32585

## Ход выполнения работы

### **1. Задание**

**Цель работы** - настроить процедуру периодического резервного копирования базы данных, сконфигурированной в ходе выполнения лабораторной работы №2, а также разработать и отладить сценарии восстановления в случае сбоев.

*   **Этап 1. Резервное копирование:** Настроить периодические **холодные полные копии**. Полная копия (`rsync`) по расписанию (`cron`) раз в сутки. СУБД на время копирования останавливается. На резервном узле хранить 14 копий, при создании 15-й самая старая удаляется. Подсчитать объем копий за месяц при росте БД на 500МБ/сутки.
*   **Этап 2. Потеря основного узла:** Восстановить работу СУБД на резервном узле.
*   **Этап 3. Повреждение файлов БД:** Симулировать сбой удалением конфигурационных файлов. Выполнить полное восстановление из резервной копии в новую директорию на основном узле.
*   **Этап 4. Логическое повреждение данных:** Настроить архивацию WAL. Симулировать ошибку (`DROP TABLE`). Выполнить восстановление на момент времени до ошибки (PITR).

#### **Данные для подключения**

**Основной узел**
*   Виртуальная машина: `pg120`
*   Пользователь: `postgres0`
*   Пароль: `lzwvJ9op`
*   Каталоги кластера: `$HOME/onb52` (PGDATA), `$HOME/nwx49` (WAL), `$HOME/syi73` (TSP), `$HOME/poe29` (TSP), `$HOME/pgdata_custom_ts` (TSP).

**Резервный узел**
*   Виртуальная машина: `pg112`
*   Пользователь: `postgres4`
*   Пароль: `bx0oHbwm`

---

### **2. Подготовительный этап: Настройка SSH-доступа**

Для автоматизации процессов `rsync` и `scp` в скриптах необходимо настроить беспарольный доступ с основного узла на резервный по SSH-ключам.

1.  **На основном узле (`pg120`)** генерируем пару SSH-ключей для пользователя `postgres0`.

    ```bash
    [postgres0@pg120 ~]$ ssh-keygen -t rsa -b 4096
    ```

2.  Копируем публичный ключ на **резервный узел (`pg112`)** для пользователя `postgres4`.

    ```bash
    [postgres0@pg120 ~]$ ssh-copy-id postgres4@pg112
    ```

3.  Проверяем беспарольный доступ.

    ```bash
    [postgres0@pg120 ~]$ ssh postgres4@pg112 'echo "SSH connection successful"'
    SSH connection successful
    ```

---

### **Этап 1. Резервное копирование**

#### **Задание**
Настроить периодические холодные полные копии. Копирование (`rsync`) раз в сутки, СУБД останавливается. На резервном узле хранить 14 копий. При создании 15-й самая старая удаляется.

#### **Настройка и выполнение**

1.  Создадим на **резервном узле (`pg112`)** директорию для хранения бэкапов.

    ```bash
    [postgres0@pg120 ~]$ ssh postgres4@pg112 'mkdir -p /var/db/postgres4/cold_backups'
    ```

2.  Создадим на **основном узле (`pg120`)** скрипт `cold_backup.sh`. Скрипт копирует все каталоги, составляющие кластер, для обеспечения его целостности.

    ```bash
    # ~/cold_backup.sh

    # --- Переменные ---
    # Список всех директорий, составляющих кластер
    CLUSTER_DIRS_TO_BACKUP=("$HOME/onb52" "$HOME/nwx49" "$HOME/syi73" "$HOME/poe29" "$HOME/pgdata_custom_ts")
    PGDATA_PATH="$HOME/onb52" # Главный каталог данных для управления сервером

    REMOTE_USER="postgres4"
    REMOTE_HOST="pg112"
    REMOTE_BACKUP_DIR="/var/db/postgres4/cold_backups"
    BACKUP_SUBDIR="backup-$(date +%F_%H-%M-%S)"
    MAX_BACKUPS=14

    echo "--- Starting cold backup at $(date) ---"

    # 1. Остановка СУБД на основном узле
    echo "Stopping PostgreSQL server..."
    pg_ctl -D "$PGDATA_PATH" stop -m fast
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to stop PostgreSQL server. Aborting."
        exit 1
    fi
    echo "Server stopped."

    # 2. Комплексное копирование данных с помощью rsync
    echo "Syncing all cluster directories to $REMOTE_HOST..."
    # Создаем на удаленном хосте директорию для сегодняшнего бэкапа
    ssh "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_BACKUP_DIR/$BACKUP_SUBDIR"

    # Копируем каждую директорию кластера в соответствующий подкаталог бэкапа
    for dir in "${CLUSTER_DIRS_TO_BACKUP[@]}"; do
        echo "Backing up $(basename "$dir")..."
        rsync -a --delete "$dir/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_DIR/$BACKUP_SUBDIR/$(basename "$dir")/"
    done

    if [ $? -ne 0 ]; then
        echo "ERROR: rsync failed. Starting server anyway."
    else
        echo "Rsync of all components completed successfully."
    fi

    # 3. Запуск СУБД
    echo "Starting PostgreSQL server..."
    pg_ctl -D "$PGDATA_PATH" start
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to start PostgreSQL server!"
        exit 1
    fi
    echo "Server started."

    # 4. Ротация бэкапов на резервном узле
    echo "Rotating backups on remote host..."
    ssh "$REMOTE_USER@$REMOTE_HOST" "ls -dt $REMOTE_BACKUP_DIR/backup-* | tail -n +$(($MAX_BACKUPS + 1)) | xargs rm -rf"
    echo "Rotation complete."

    echo "--- Backup finished at $(date) ---"
    ```

    Примечание: для исключения редких несогласованностей между `pg_control` и `pg_wal` рекомендуется использовать единый tar‑поток вместо нескольких `rsync` вызовов. Это даёт консистентный срез директорий за одну операцию передачи:

    ```bash
    # Рекомендуемый вариант копирования единым tar-потоком
    [postgres0@pg120 ~]$ ssh postgres4@pg112 "mkdir -p /var/db/postgres4/cold_backups/$BACKUP_SUBDIR"
    [postgres0@pg120 ~]$ tar -C "$HOME" -cf - onb52 nwx49 syi73 poe29 pgdata_custom_ts \
      | ssh postgres4@pg112 "tar -C /var/db/postgres4/cold_backups/$BACKUP_SUBDIR -xf -"
    ```

3.  Дадим скрипту права на выполнение и настроим `cron` для ежедневного запуска.

    ```bash
    [postgres0@pg120 ~]$ chmod +x cold_backup.sh
    [postgres0@pg120 ~]$ crontab -e
    # Добавляем строку в редакторе:
    30 2 * * * /var/db/postgres0/cold_backup.sh >> /var/db/postgres0/backup.log 2>&1
    ```

    Для наглядности можно запустить скрипт немеделенно:
    ```bash
    [postgres0@pg120 ~]$ ./cold_backup.sh 
    --- Starting cold backup at пятница, 13 июня 2025 г. 13:00:44 (MSK) ---
    Stopping PostgreSQL server...
    ожидание завершения работы сервера.... готово
    сервер остановлен
    Server stopped.
    Syncing all cluster directories to pg112...
    Backing up onb52...
    Backing up nwx49...
    Backing up syi73...
    Backing up poe29...
    Backing up pgdata_custom_ts...
    Rsync of all components completed successfully.
    Starting PostgreSQL server...
    ожидание запуска сервера....2025-06-13 13:00:49.521 MSK [85970] @ [] СООБЩЕНИЕ:  передача вывода в протокол процессу сбора протоколов
    2025-06-13 13:00:49.521 MSK [85970] @ [] ПОДСКАЗКА:  В дальнейшем протоколы будут выводиться в каталог "log".
    готово
    сервер запущен
    Server started.
    Rotating backups on remote host...
    Rotation complete.
    --- Backup finished at пятница, 13 июня 2025 г. 13:00:49 (MSK) ---
    ```

#### **Подсчет и анализ объема**

*   **Условия:** Средний объем новых данных в БД за сутки: 500 МБ. Срок хранения: 14 копий.
*   **Расчет:** Начальный размер БД `S₀` = 10 ГБ. Размер копии на день `n`: `Sₙ = S₀ + n * 500 МБ`. Спустя 30 дней на диске будут копии за дни 17-30. Общий объем = 14 * `S₀` + 500 МБ * (17 + ... + 30) = 140 ГБ + 164.5 ГБ = **304.5 ГБ**.
*   **Анализ:** Метод прост и надежен, но требует простоя системы и потребляет много дискового пространства.

#### **Логи**

Проверка структуры бэкапа на резервном узле `pg112`.

```bash
[postgres4@pg112 ~]$ ls -al cold_backups/backup-2025-06-13_13-00-44/
total 20
drwxr-xr-x   7 postgres4 postgres  7 13 июня  13:00 .
drwxr-xr-x   3 postgres4 postgres  3 13 июня  13:00 ..
drwx------   3 postgres4 postgres  4 18 мая   14:30 nwx49
drwx------  19 postgres4 postgres 26 13 июня  13:00 onb52
drwx------   3 postgres4 postgres  3 18 мая   14:37 pgdata_custom_ts
drwx------   3 postgres4 postgres  3 18 мая   14:37 poe29
drwx------   3 postgres4 postgres  3 18 мая   14:37 syi73
```

**Результат:** Бэкап содержит все необходимые компоненты кластера.

### **Этап 2. Потеря основного узла**

#### **Задание**

Сценарий подразумевает полную недоступность основного узла. Необходимо восстановить работу СУБД на резервном узле из созданной ранее копии.

#### **Выполнение**

1.  **Симуляция сбоя:** Узел `pg120` недоступен.
2.  Переходим на **резервный узел `pg112`** и создаем скрипт `restore_last_backup.sh`.

    ```bash
    # ~/restore_last_backup.sh

    set -e

    # --- Переменные ---
    BACKUP_ROOT_DIR="/var/db/postgres4/cold_backups"
    CLUSTER_COMPONENTS=("onb52" "nwx49" "syi73" "poe29" "pgdata_custom_ts")
    PGDATA_DIR_NAME="onb52"
    PGDATA_PATH="$HOME/$PGDATA_DIR_NAME"
    LOG_FILE="$HOME/postgres_restore.log"

    echo "--- Starting restoration process ---"

    # 0. Остановка существующего сервера
    # Проверяем, существует ли каталог данных. Если нет, то и сервера точно нет.
    if [ -d "$PGDATA_PATH" ]; then
        # Проверяем статус сервера. `pg_ctl status` возвращает 0, если работает, и не 0, если нет.
        if pg_ctl -D "$PGDATA_PATH" status > /dev/null 2>&1; then
            echo "PostgreSQL server is running. Stopping it first..."
            pg_ctl -D "$PGDATA_PATH" stop -m fast
            echo "Server stopped."
        else
            echo "PostgreSQL server is not running or PGDATA is inconsistent. Proceeding..."
        fi
    else
        echo "No previous PGDATA found. Starting fresh restoration."
    fi

    # 1. Находим последнюю резервную копию
    # Получаем список бэкапов, сортируем по имени в обратном порядке (новые сначала)
    backup_list=()
    while IFS= read -r -d $'\0' dir; do
        backup_list+=("$dir")
    done < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -type d -name "backup-*" -print0 | sort -zr)

    if [ ${#backup_list[@]} -eq 0 ]; then
        echo "ERROR: No backups found in $BACKUP_ROOT_DIR"
        exit 1
    fi

    LATEST_BACKUP="${backup_list[0]}"
    echo

    # 2. Очищаем старые директории кластера
    echo "Cleaning up old cluster directories..."
    for component in "${CLUSTER_COMPONENTS[@]}"; do
        rm -rf "$HOME/$component"
    done

    # 3. Восстанавливаем структуру каталогов из бэкапа
    echo "Restoring cluster structure from backup..."
    for component in "${CLUSTER_COMPONENTS[@]}"; do
        echo "Restoring $component..."
        cp -a "$LATEST_BACKUP/$component/" "$HOME/$component"
    done

    # 4. Коррекция символических ссылок
    echo "Correcting symbolic links..."
    rm -rf "$PGDATA_PATH/pg_wal"
    ln -s "$HOME/nwx49" "$PGDATA_PATH/pg_wal"
    echo "Link for pg_wal recreated."

    TBLSPC_DIR="$PGDATA_PATH/pg_tblspc"
    declare -A TBLSPC_LINKS
    for link_path in "$LATEST_BACKUP/$PGDATA_DIR_NAME/pg_tblspc"/*; do
        if [ -L "$link_path" ]; then
            oid=$(basename "$link_path")
            target_dir_name=$(basename "$(readlink "$link_path")")
            TBLSPC_LINKS[$oid]=$target_dir_name
        fi
    done

    find "$TBLSPC_DIR" -type l -delete

    for oid in "${!TBLSPC_LINKS[@]}"; do
        target_dir_name=${TBLSPC_LINKS[$oid]}
        ln -s "$HOME/$target_dir_name" "$TBLSPC_DIR/$oid"
        echo "Link for tablespace OID $oid -> $target_dir_name recreated."
    done
    echo "All links have been corrected."

    # 5. Запуск сервера PostgreSQL
    echo "Starting PostgreSQL server..."
    pg_ctl -D "$PGDATA_PATH" -l "$LOG_FILE" start

    sleep 5 # Даем серверу время на запуск

    # 6. Проверка статуса
    pg_ctl -D "$PGDATA_PATH" status

    echo "--- Restoration process finished successfully ---"
    ```
3.  Даем скрипту права на выполнение и запускаем его.

    ```bash
    [postgres4@pg112 ~]$ chmod +x restore_last_backup.sh
    [postgres4@pg112 ~]$ ./restore_last_backup.sh
    ```

#### **Логи**

```bash
[postgres4@pg112 ~]$ ./restore_last_backup.sh 
--- Starting restoration process ---
PostgreSQL server is not running or PGDATA is inconsistent. Proceeding...

Cleaning up old cluster directories...
Restoring cluster structure from backup...
Restoring onb52...
Restoring nwx49...
Restoring syi73...
Restoring poe29...
Restoring pgdata_custom_ts...
Correcting symbolic links...
Link for pg_wal recreated.
Link for tablespace OID 16389 -> poe29 recreated.
Link for tablespace OID 16388 -> syi73 recreated.
Link for tablespace OID 16390 -> pgdata_custom_ts recreated.
All links have been corrected.
Starting PostgreSQL server...
ожидание запуска сервера.... готово
сервер запущен
pg_ctl: сервер работает (PID: 86141)
/usr/local/bin/postgres "-D" "/var/db/postgres4/onb52"
--- Restoration process finished successfully ---
```

Пробуем подключиться и видим, что структура таблиц и данные в них перенесены:

```bash
[postgres4@pg112 ~]$ psql -p 9523 -U postgres0 -d loudblackuser
psql (16.4)
Введите "help", чтобы получить справку.

loudblackuser=# \dt
                   Список отношений
 Схема  |        Имя        |   Тип   |   Владелец    
--------+-------------------+---------+---------------
 public | chat_participants | таблица | chat_app_user
 public | chats             | таблица | chat_app_user
 public | messages          | таблица | chat_app_user
 public | users             | таблица | chat_app_user
(4 строки)

loudblackuser=# select * from users;
 user_id | username |          created_at           
---------+----------+-------------------------------
       1 | alice    | 2025-05-18 14:44:15.268273+03
       2 | bob      | 2025-05-18 14:44:15.268273+03
       3 | charlie  | 2025-05-18 14:44:15.268273+03
(3 строки)

loudblackuser=#
```

---

## **Этап 3. Повреждение файлов БД**

#### **Задание**
Симулировать сбой удалением конфигурационных файлов. Восстановить данные из резервной копии в новую директорию на основном узле.

#### **Выполнение**

1.  **Симуляция сбоя на основном узле (`pg120`)**:
    *   Останавливаем сервер, удаляем конфигурационные файлы и пытаемся его запустить.

    ```bash
    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 stop -m fast
    ожидание завершения работы сервера.... готово
    сервер остановлен
    [postgres0@pg120 ~]$ rm $HOME/onb52/postgresql.conf $HOME/onb52/pg_hba.conf
    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 start
    ожидание запуска сервера....postgres не может открыть файл конфигурации сервера "/var/db/postgres0/onb52/postgresql.conf": No such file or directory
    прекращение ожидания
    pg_ctl: не удалось запустить сервер
    Изучите протокол выполнения.
    ```

2.  **Восстановление на основном узле (`pg120`)**:
    *   Поскольку исходные директории "недоступны", создаем новые с суффиксом `_restored`.
    *   Копируем все компоненты кластера из последней резервной копии с `pg112`.
    *   Корректируем символические ссылки, как в Этапе 2.
    *   Запускаем сервер.

    ```bash
    # Создаем новые директории
    [postgres0@pg120 ~]$ for dir in onb52 nwx49 syi73 poe29 pgdata_custom_ts; do mkdir $HOME/${dir}_restored; done
    
    # Копируем данные с резервного узла
    [postgres0@pg120 ~]$ LATEST_BACKUP_PATH="/var/db/postgres4/cold_backups/нужный бекап"
    [postgres0@pg120 ~]$ for dir in onb52 nwx49 syi73 poe29 pgdata_custom_ts; do
        rsync -a postgres4@pg112:$LATEST_BACKUP_PATH/$dir/ $HOME/${dir}_restored/
    done

    # Определяем пути для удобства
    [postgres0@pg120 ~]$ PGDATA_RESTORED="$HOME/onb52_restored"
    [postgres0@pg120 ~]$ TBLSPC_DIR_RESTORED="$PGDATA_RESTORED/pg_tblspc"

    # 1. Корректируем ссылку на WAL-каталог
    [postgres0@pg120 ~]$ rm $PGDATA_RESTORED/pg_wal
    [postgres0@pg120 ~]$ ln -s $HOME/nwx49_restored $PGDATA_RESTORED/pg_wal

    # 2. Корректируем ссылки на табличные пространства
    declare -A TBLSPC_LINKS
    for link_path in "$PGDATA_RESTORED/pg_tblspc"/*; do
        if [ -L "$link_path" ]; then
            oid=$(basename "$link_path")
            target_dir_name=$(basename "$(readlink "$link_path")")
            TBLSPC_LINKS[$oid]=$target_dir_name
        fi
    done

    # Удаляем старые, некорректные ссылки
    [postgres0@pg120 ~]$ find "$TBLSPC_DIR_RESTORED" -type l -delete

    # Создаем новые, правильные ссылки на директории с суффиксом _restored
    for oid in "${!TBLSPC_LINKS[@]}"; do
        target_dir_name=${TBLSPC_LINKS[$oid]}
        ln -s "$HOME/${target_dir_name}_restored" "$TBLSPC_DIR_RESTORED/$oid"
        echo "Link for tablespace OID $oid -> ${target_dir_name}_restored recreated."
    done

    # Запускаем сервер
    [postgres0@pg120 ~]$ pg_ctl -D $PGDATA_RESTORED start
    ожидание запуска сервера....2025-06-13 03:56:40.896 MSK [19639] @ [] СООБЩЕНИЕ:  передача вывода в протокол процессу сбора протоколов
    2025-06-13 03:56:40.896 MSK [19639] @ [] ПОДСКАЗКА:  В дальнейшем протоколы будут выводиться в каталог "log".
    готово
    сервер запущен
    ```

#### **Логи**

```bash
[postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52_restored start
ожидание запуска сервера.... готово
сервер запущен

[postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52_restored status
pg_ctl: сервер работает (PID: 21345)
/usr/local/bin/postgres "-D" "/home/postgres0/onb52_restored"
```
**Результат:** Сервер успешно восстановлен в новом наборе директорий из холодной копии.

---

------------

### **Этап 4. Логическое повреждение данных**

#### **Задание**
Настроить архивацию WAL. Симулировать ошибку, удалив две таблицы (`DROP TABLE`). Выполнить восстановление на момент времени до ошибки (Point-in-Time Recovery), продемонстрировав весь процесс.

#### **Выполнение**

Процесс состоит из четырех основных шагов: настройка архивации, создание базовой копии, симуляция полезной работы и ошибки, и, наконец, восстановление на момент времени до сбоя.

**1. Настройка архивации WAL на основном узле (`pg120`)**

Для возможности восстановления на момент времени (PITR) необходимо включить непрерывное архивирование Write-Ahead Log (WAL).

*   Создаем каталог для хранения архивных WAL-файлов на резервном узле `pg112`.

    ```bash
    [postgres0@pg120 ~]$ ssh postgres4@pg112 'mkdir -p /var/db/postgres4/wal_archive'
    ```
*   Добавляем необходимые параметры в конфигурационный файл `postgresql.conf` на основном узле.

    ```bash
    [postgres0@pg120 ~]$ echo "wal_level = replica" >> $HOME/onb52/postgresql.conf
    [postgres0@pg120 ~]$ echo "archive_mode = on" >> $HOME/onb52/postgresql.conf
    [postgres0@pg120 ~]$ echo "archive_command = 'scp %p postgres4@pg112:/var/db/postgres4/wal_archive/%f'" >> $HOME/onb52/postgresql.conf
    ```
*   Перезапускаем сервер для применения новых настроек.

    ```bash
    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 restart
    ожидание завершения работы сервера.... готово
    сервер остановлен
    ожидание запуска сервера.... готово
    сервер запущен
    ```

**2. Создание базовой резервной копии**

Восстановление PITR требует наличия базовой копии, на которую будут "накатываться" WAL-файлы. Создаем ее с помощью `pg_basebackup`.

```bash
[postgres0@pg120 ~]$ pg_basebackup -D $HOME/pitr_base_backup -Ft -X none -P -p 9523
31689/31689 КБ (100%), табличное пространство 4/4
```

**3. Симуляция работы и логической ошибки**

Выполняем несколько полезных операций, затем фиксируем точное время и совершаем ошибочное действие (`DROP TABLE`).

```bash
[postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser
psql (16.4)
Введите "help", чтобы получить справку.

loudblackuser=# INSERT INTO users (username) VALUES ('user_to_be_restored_1');
INSERT 0 1
loudblackuser=# INSERT INTO chats (chat_name) VALUES ('chat_to_restore_1');
INSERT 0 1

-- Фиксируем точное время ДО ошибки. Это наша точка восстановления.
loudblackuser=# SELECT now();
              now              
-------------------------------
 2025-09-08 03:57:38.590612+03
(1 строка)

-- Симулируем ошибку, удаляя важные таблицы
loudblackuser=# DROP TABLE messages;
DROP TABLE
loudblackuser=# DROP TABLE chat_participants;
DROP TABLE
loudblackuser=# \q
```

**4. Гарантированная доставка WAL-файлов в архив**

Перед остановкой сервера принудительно переключаем WAL-сегмент дважды, чтобы все последние изменения гарантированно ушли в архив.

```bash
[postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser -c "SELECT pg_switch_wal();"
 pg_switch_wal 
---------------
 0/3018AF8
(1 строка)

[postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser -c "SELECT pg_switch_wal();"
 pg_switch_wal 
---------------
 0/3020000
(1 строка)

[postgres0@pg120 ~]$ ssh postgres4@pg112 'ls -l /var/db/postgres4/wal_archive'
```
**Анализ:** Проверка показала, что WAL-файлы успешно архивируются на резервном узле.

**5. Восстановление на момент времени (Point-in-Time Recovery)**

Теперь выполняем непосредственно процедуру восстановления.

*   Останавливаем поврежденный сервер.

    ```bash
    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 stop -m smart
    ожидание завершения работы сервера.... готово
    сервер остановлен
    ```
*   Убираем старый каталог данных и создаем новый.

    ```bash
    [postgres0@pg120 ~]$ mv $HOME/onb52 $HOME/onb52_crashed
    [postgres0@pg120 ~]$ mkdir $HOME/onb52
    [postgres0@pg120 ~]$ chmod 700 $HOME/onb52
    ```
*   Распаковываем базовую резервную копию.

    ```bash
    [postgres0@pg120 ~]$ tar -xf $HOME/pitr_base_backup/base.tar -C $HOME/onb52
    ```

*   Восстанавливаем символические ссылки для tablespaces на основе tablespace_map:
    ```bash
    # Создаем символические ссылки на основе файла tablespace_map
    [postgres0@pg120 ~]$ while read oid path; do
        ln -s "$path" "$HOME/onb52/pg_tblspc/$oid"
    done < "$HOME/onb52/tablespace_map"

    # Альтернативный вариант - создание ссылок вручную (если известны OID):
    # ln -s $HOME/syi73 $HOME/onb52/pg_tblspc/16388
    # ln -s $HOME/poe29 $HOME/onb52/pg_tblspc/16389
    # ln -s $HOME/pgdata_custom_ts $HOME/onb52/pg_tblspc/16390
    ```

*   Распаковываем тар‑архивы таблспейсов:

    ```bash
    [postgres0@pg120 ~]$ for l in "$HOME/onb52/pg_tblspc"/*; do
        if [ -L "$l" ]; then  # Проверяем, что это символическая ссылка
            oid=$(basename "$l")
            dest=$(readlink -f "$l")
            tf="$HOME/pitr_base_backup/$oid.tar"
            
            if [ -f "$tf" ]; then
                echo "Restoring tablespace $oid into $dest"
                # Очищаем и создаём директорию
                rm -rf "$dest"
                mkdir -p "$dest"
                # Извлекаем архив
                tar -xf "$tf" -C "$dest"
                # Устанавливаем правильные права
                chmod 700 "$dest"
            fi
        fi
    done
    ```
*   Создаем конфигурацию для восстановления, указывая точное время, зафиксированное ранее.

    ```bash
    [postgres0@pg120 ~]$ touch $HOME/onb52/recovery.signal
    [postgres0@pg120 ~]$ cat >> $HOME/onb52/postgresql.conf <<EOF
restore_command = 'scp postgres4@pg112:/var/db/postgres4/wal_archive/%f %p'
recovery_target_time = '2025-09-08 04:15:08.978111+03'
recovery_target_action = 'promote'
EOF
    ```
*   Запускаем сервер. Он автоматически войдет в режим восстановления.

    ```bash
    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 start
    ожидание запуска сервера.... готово
    сервер запущен
    ```
*   Проверяем результат.

    ```bash
    [postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser
    ```

#### Протокол выполнения

    ```
    [postgres0@pg120 ~]$ rm -rf onb52_crashed pitr_base_backup && ./rollback_primary_node.sh && pg_ctl -D onb52 stop
    --- Starting rollback process for the primary node ---
    PostgreSQL server is running. Stopping it...
    ожидание завершения работы сервера.... готово
    сервер остановлен
    Server stopped.
    Finding the latest backup on pg112...
    Found latest backup on remote host: /var/db/postgres4/cold_backups/backup-2025-09-08_03-03-11
    Cleaning up local cluster directories...
    Restoring cluster structure from remote backup using rsync...
    Restoring onb52...
    Restoring nwx49...
    Restoring syi73...
    Restoring poe29...
    Restoring pgdata_custom_ts...
    All components restored.
    Correcting symbolic links for local environment...
    Link for pg_wal recreated for local user.
    Link for tablespace OID 16389 -> poe29 recreated for local user.
    Link for tablespace OID 16388 -> syi73 recreated for local user.
    Link for tablespace OID 16390 -> pgdata_custom_ts recreated for local user.
    All links have been corrected.
    Starting the rolled-back PostgreSQL server...
    ожидание запуска сервера.... готово
    сервер запущен
    pg_ctl: сервер работает (PID: 11956)
    /usr/local/bin/postgres "-D" "/var/db/postgres0/onb52"
    --- Rollback process for the primary node finished successfully ---
    ожидание завершения работы сервера.... готово
    сервер остановлен
    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 restart
    pg_ctl: файл PID "/var/db/postgres0/onb52/postmaster.pid" не существует
    Запущен ли сервер?
    производится попытка запуска сервера в любом случае
    ожидание запуска сервера....2025-09-08 04:14:38.916 MSK [12081] @ [] СООБЩЕНИЕ:  передача вывода в протокол процессу сбора протоколов
    2025-09-08 04:14:38.916 MSK [12081] @ [] ПОДСКАЗКА:  В дальнейшем протоколы будут выводиться в каталог "log".
    готово
    сервер запущен
    [postgres0@pg120 ~]$ pg_basebackup -D $HOME/pitr_base_backup -Ft -X none -P -p 9523
    ЗАМЕЧАНИЕ:  все нужные сегменты WAL заархивированы4
    203677/203677 КБ (100%), табличное пространство 4/4
    [postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser
    psql (16.4)
    Введите "help", чтобы получить справку.

    loudblackuser=#     select * from users;
        select * from chats;
        select * from chat_participants;
        select * from messages;
    user_id | username |          created_at           
    ---------+----------+-------------------------------
        1 | alice    | 2025-09-08 03:02:35.336203+03
        2 | bob      | 2025-09-08 03:02:35.336203+03
        3 | charlie  | 2025-09-08 03:02:35.336203+03
    (3 строки)

    chat_id |      chat_name       |          created_at           
    ---------+----------------------+-------------------------------
        1 | обсуждение проекта x | 2025-09-08 03:02:38.715542+03
        2 | разговоры о погоде   | 2025-09-08 03:02:38.715542+03
    (2 строки)

    chat_id | user_id |           joined_at           
    ---------+---------+-------------------------------
        1 |       1 | 2025-09-08 03:02:43.266589+03
        1 |       2 | 2025-09-08 03:02:43.266589+03
        2 |       3 | 2025-09-08 03:02:46.799593+03
        2 |       1 | 2025-09-08 03:02:50.796875+03
    (4 строки)

    message_id | chat_id | user_id |                   content                   |            sent_at            
    ------------+---------+---------+---------------------------------------------+-------------------------------
            1 |       1 |       1 | привет, боб! как дела с задачей?            | 2025-09-08 03:02:55.427453+03
            2 |       1 |       2 | привет, элис! почти готово, остались тесты. | 2025-09-08 03:02:55.427453+03
            3 |       2 |       3 | сегодня отличный день!                      | 2025-09-08 03:03:00.753523+03
            4 |       2 |       1 | да, солнечно, но ветрено.                   | 2025-09-08 03:03:00.753523+03
    (4 строки)

    loudblackuser=# INSERT INTO users (username) VALUES ('user_to_be_restored_1');
    INSERT 0 1
    loudblackuser=# INSERT INTO chats (chat_name) VALUES ('chat_to_restore_1');
    INSERT 0 1
    loudblackuser=# SELECT now();
                now              
    -------------------------------
    2025-09-08 04:15:08.978111+03
    (1 строка)

    loudblackuser=# DROP TABLE messages;
    DROP TABLE
    loudblackuser=# DROP TABLE chat_participants;
    DROP TABLE
    loudblackuser=# exit
    [postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser -c "SELECT pg_switch_wal();"
    pg_switch_wal 
    ---------------
    0/19010060
    (1 строка)

    [postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser -c "SELECT pg_switch_wal();"
    pg_switch_wal 
    ---------------
    0/1A000000
    (1 строка)

    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 stop -m smart
    ожидание завершения работы сервера...... готово
    сервер остановлен
    [postgres0@pg120 ~]$ mv $HOME/onb52 $HOME/onb52_crashed
    [postgres0@pg120 ~]$ mkdir $HOME/onb52
    [postgres0@pg120 ~]$ chmod 700 $HOME/onb52
    [postgres0@pg120 ~]$ tar -xf $HOME/pitr_base_backup/base.tar -C $HOME/onb52
    [postgres0@pg120 ~]$ while read oid path; do
            ln -s "$path" "$HOME/onb52/pg_tblspc/$oid"
        done < "$HOME/onb52/tablespace_map"
    [postgres0@pg120 ~]$ for l in "$HOME/onb52/pg_tblspc"/*; do
            if [ -L "$l" ]; then  # Проверяем, что это символическая ссылка
                oid=$(basename "$l")
                dest=$(readlink -f "$l")
                tf="$HOME/pitr_base_backup/$oid.tar"
                
                if [ -f "$tf" ]; then
                    echo "Restoring tablespace $oid into $dest"
                    # Очищаем и создаём директорию
                    rm -rf "$dest"
                    mkdir -p "$dest"
                    # Извлекаем архив
                    tar -xf "$tf" -C "$dest"
                    # Устанавливаем правильные права
                    chmod 700 "$dest"
                fi
            fi
        done
    Restoring tablespace 16388 into /var/db/postgres0/syi73
    Restoring tablespace 16389 into /var/db/postgres0/poe29
    Restoring tablespace 16390 into /var/db/postgres0/pgdata_custom_ts
    [postgres0@pg120 ~]$ touch $HOME/onb52/recovery.signal
    [postgres0@pg120 ~]$ cat >> $HOME/onb52/postgresql.conf <<EOF
    restore_command = 'scp postgres4@pg112:/var/db/postgres4/wal_archive/%f %p'
    recovery_target_time = '2025-09-08 04:15:08.978111+03'
    recovery_target_action = 'promote'
    EOF
    [postgres0@pg120 ~]$ pg_ctl -D $HOME/onb52 start
    ожидание запуска сервера....2025-09-08 04:16:30.101 MSK [12658] @ [] СООБЩЕНИЕ:  передача вывода в протокол процессу сбора протоколов
    2025-09-08 04:16:30.101 MSK [12658] @ [] ПОДСКАЗКА:  В дальнейшем протоколы будут выводиться в каталог "log".
    ... готово
    сервер запущен
    [postgres0@pg120 ~]$ psql -p 9523 -U postgres0 -d loudblackuser
    psql (16.4)
    Введите "help", чтобы получить справку.

    loudblackuser=#     select * from users;
        select * from chats;
        select * from chat_participants;
        select * from messages;
    user_id |       username        |          created_at           
    ---------+-----------------------+-------------------------------
        1 | alice                 | 2025-09-08 03:02:35.336203+03
        2 | bob                   | 2025-09-08 03:02:35.336203+03
        3 | charlie               | 2025-09-08 03:02:35.336203+03
        4 | user_to_be_restored_1 | 2025-09-08 04:15:02.086888+03
    (4 строки)

    chat_id |      chat_name       |          created_at           
    ---------+----------------------+-------------------------------
        1 | обсуждение проекта x | 2025-09-08 03:02:38.715542+03
        2 | разговоры о погоде   | 2025-09-08 03:02:38.715542+03
        3 | chat_to_restore_1    | 2025-09-08 04:15:06.006339+03
    (3 строки)

    chat_id | user_id |           joined_at           
    ---------+---------+-------------------------------
        1 |       1 | 2025-09-08 03:02:43.266589+03
        1 |       2 | 2025-09-08 03:02:43.266589+03
        2 |       3 | 2025-09-08 03:02:46.799593+03
        2 |       1 | 2025-09-08 03:02:50.796875+03
    (4 строки)

    message_id | chat_id | user_id |                   content                   |            sent_at            
    ------------+---------+---------+---------------------------------------------+-------------------------------
            1 |       1 |       1 | привет, боб! как дела с задачей?            | 2025-09-08 03:02:55.427453+03
            2 |       1 |       2 | привет, элис! почти готово, остались тесты. | 2025-09-08 03:02:55.427453+03
            3 |       2 |       3 | сегодня отличный день!                      | 2025-09-08 03:03:00.753523+03
            4 |       2 |       1 | да, солнечно, но ветрено.                   | 2025-09-08 03:03:00.753523+03
    (4 строки)

    loudblackuser=# exit
    ```
