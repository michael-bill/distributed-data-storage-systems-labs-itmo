# Лабораторная работа номер 4 по дисицплине "Распределенные системы хранения данных" - Отчёт

## Информация

Университет ИТМО, Факультет программной инженерии и компьютерной техники

Санкт-Петербург, 2025

ФИО: Билошицкий Михаил Владимирович

Преподаватель: Николаев Владимир Вячеславович

Группа: P3316

Вариант: 67

## Задание

**Цель работы** - ознакомиться с методами и средствами построения отказоустойчивых решений на базе СУБД PostgreSQL, получить практические навыки восстановления работы системы после отказа.

Работа рассчитана на двух человек и выполняется в три этапа: настройка, симуляция и обработка сбоя, восстановление.

### Требования к выполнению работы

- В качестве хостов использовать одинаковые виртуальные машины.
- В первую очередь необходимо обеспечить сетевую связность между ВМ.
- Для подключения к СУБД (например, через `psql`) использовать отдельную виртуальную или физическую машину.
- Демонстрировать наполнение базы и доступ на запись на примере **не менее, чем двух** таблиц, столбцов, строк, транзакций и клиентских сессий.

### Этап 1. Конфигурация

Развернуть PostgreSQL на двух узлах в режиме горячего резерва (Master + Hot Standby). Не использовать дополнительные пакеты. Продемонстрировать доступ в режиме чтения/записи на основном сервере, в режиме чтения на резервном сервере, а также актуальность данных на них.

### Этап 2. Симуляция и обработка сбоя

**2.1 Подготовка:**
- Установить несколько клиентских подключений к СУБД.
- Продемонстрировать состояние данных и работу клиентов в режиме чтения/записи.

**2.2 Сбой:**
Симулировать программную ошибку на основном узле - выполнить команду `pkill -9 postgres`.

**2.3 Обработка:**
- Найти и продемонстрировать в логах релевантные сообщения об ошибках.
- Выполнить переключение (failover) на резервный сервер.
- Продемонстрировать состояние данных и работу клиентов в режиме чтения/записи.

### Восстановление

- Восстановить работу основного узла - откатить действие, выполненное на этапе 2.2.
- Актуализировать состояние базы на основном узле - накатить все изменения данных, выполненные на этапе 2.3.
- Восстанавить исправную работу узлов в исходной конфигурации (в соответствии с этапом 1).
- Продемонстрировать состояние данных и работу клиентов в режиме чтения/записи.

### Вопросы для подготовки к защите

- Синхронная и асинхронная репликация: отличия, ограничения и область применения.
- Кластер в режиме Active-Active и Active-Standby: отличия, ограничения и область применения.
- Балансировка нагрузки: описание и область применения.
- От чего зависит время простоя системы в случае отказа?

---

## Ход выполнения работы

### Архитектура и окружение

- **VM1** (192.168.56.2) - Master (Ubuntu, пользователь: main)
- **VM2** (192.168.56.3) - Hot Standby (Ubuntu, пользователь: main)
- **Client** - MacOS хост-машина для подключения к БД
- **PostgreSQL версия**: 17
- **Пароли**: 123qwe123qwe (для всех пользователей)

### Подготовка виртуальных машин

#### На обеих VM (VM1 и VM2):

```bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка SSH сервера
sudo apt install openssh-server -y
sudo systemctl enable ssh
sudo systemctl start ssh

# Проверка IP адреса
ip a

# Установка PostgreSQL 17
sudo apt install postgresql postgresql-contrib -y

# Проверка версии
sudo -u postgres psql -c "select version();"
```

#### Настройка SSH без пароля между VM

На VM1:
```bash
# Генерация SSH ключей
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Копирование ключа на VM2
ssh-copy-id main@192.168.56.3
```

На VM2:
```bash
# Генерация SSH ключей
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Копирование ключа на VM1
ssh-copy-id main@192.168.56.2
```

Проверка:
```bash
# С VM1 на VM2
ssh main@192.168.56.3 'echo "SSH connection successful"'

# С VM2 на VM1
ssh main@192.168.56.2 'echo "SSH connection successful"'
```

---

## Этап 1. Конфигурация Master + Hot Standby

### Настройка Master (VM1 - 192.168.56.2)

#### 1. Создание пользователя main1 с супер правами

```bash
# Переключение на пользователя postgres
sudo -i -u postgres

# Создание пользователя main1
createuser --superuser main1

# Установка пароля
psql -c "alter user main1 password '123qwe123qwe';"

# Создание базы данных для main1
createdb -O main1 main1

# Выход из пользователя postgres
exit
```

#### 2. Настройка postgresql.conf

```bash
# Редактирование конфигурации
sudo vim /etc/postgresql/17/main/postgresql.conf
```

Найти и изменить/добавить следующие параметры:
```conf
# Основные параметры
listen_addresses = '*'
port = 5432

# Параметры репликации
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
wal_keep_size = 256MB
hot_standby = on
wal_log_hints = on

# Архивирование WAL
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/archive/%f && cp %p /var/lib/postgresql/17/archive/%f'

# Логирование
log_connections = on
log_disconnections = on
log_replication_commands = on
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
```

#### 3. Создание директории для архивов

```bash
sudo -u postgres mkdir -p /var/lib/postgresql/17/archive
sudo chown postgres:postgres /var/lib/postgresql/17/archive
```

#### 4. Настройка pg_hba.conf

```bash
sudo vim /etc/postgresql/17/main/pg_hba.conf
```

Заменить содержимое на:
```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Локальные подключения
local   all             all                                     peer

# IPv4 подключения
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.56.0/24         md5

# Репликация
host    replication     replicator      192.168.56.3/32         md5
host    replication     replicator      192.168.56.0/24         md5
```

#### 5. Перезапуск PostgreSQL и создание пользователей

```bash
# Перезапуск службы
sudo systemctl restart postgresql

# Проверка статуса
sudo systemctl status postgresql

# Создание пользователя для репликации
psql -U main1 -d main1 -h 127.0.0.1
```

```sql
-- Создание пользователя репликации
create user replicator with replication encrypted password '123qwe123qwe';

-- Создание тестовой базы данных
create database testdb;
grant all privileges on database testdb to main1;

-- Проверка
\du
\l
\q
```

#### 6. Создание тестовых таблиц и данных

```bash
psql -U main1 -d testdb -h 127.0.0.1
```

```sql
-- Создание таблиц
create table users (
    id serial primary key,
    name varchar(100) not null,
    email varchar(100) unique,
    created_at timestamp default current_timestamp
);

create table orders (
    id serial primary key,
    user_id int references users(id),
    product varchar(200),
    amount decimal(10,2),
    order_date timestamp default current_timestamp
);

-- Наполнение данными
insert into users (name, email) values 
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com');

insert into orders (user_id, product, amount) values 
    (1, 'laptop', 1200.00),
    (2, 'mouse', 25.50),
    (3, 'keyboard', 75.00),
    (1, 'monitor', 300.00);

-- Проверка
select * from users;
select * from orders;
\q
```

### Настройка Standby (VM2 - 192.168.56.3)

#### 1. Создание пользователя main1

```bash
# Создание пользователя main1
sudo -i -u postgres
createuser --superuser main1
psql -c "alter user main1 password '123qwe123qwe';"
createdb -O main1 main1
exit
```

#### 2. Остановка PostgreSQL и очистка данных

```bash
# Остановка службы
sudo systemctl stop postgresql

# Сохранение конфигурации
sudo cp /etc/postgresql/17/main/postgresql.conf /tmp/postgresql.conf.backup
sudo cp /etc/postgresql/17/main/pg_hba.conf /tmp/pg_hba.conf.backup

# Очистка данных
sudo -i
rm -rf /var/lib/postgresql/17/main/*
exit
```

#### 3. Создание базового бэкапа с Master

```bash
# Выполнение базового бэкапа
sudo -u postgres pg_basebackup \
  -h 192.168.56.2 \
  -D /var/lib/postgresql/17/main \
  -U replicator \
  -v -P -W \
  -X stream \
  -R

# Пароль: 123qwe123qwe
```

#### 4. Настройка конфигурации на Standby

```bash
# Восстановление postgresql.conf
sudo cp /tmp/postgresql.conf.backup /etc/postgresql/17/main/postgresql.conf

# Редактирование для Standby
sudo vim /etc/postgresql/17/main/postgresql.conf
```

Убедиться, что есть:
```conf
listen_addresses = '*'
port = 5432
hot_standby = on
```

#### 5. Настройка pg_hba.conf на Standby

```bash
sudo vim /etc/postgresql/17/main/pg_hba.conf
```

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.56.0/24         md5
```

#### 6. Проверка автоматически созданных файлов

```bash
# Проверка наличия standby.signal
ls -la /var/lib/postgresql/17/main/standby.signal

# Проверка postgresql.auto.conf
cat /var/lib/postgresql/17/main/postgresql.auto.conf
```

#### 7. Запуск Standby

```bash
# Запуск PostgreSQL
sudo systemctl start postgresql

# Проверка статуса
sudo systemctl status postgresql

# Проверка логов
sudo tail -f /var/log/postgresql/postgresql-17-main.log
```

### Проверка репликации

#### На Master (VM1):

```bash
psql -U main1 -d main1 -h 127.0.0.1
```

```sql
-- Проверка состояния репликации
select * from pg_stat_replication;

-- Текущая позиция WAL
select pg_current_wal_lsn();
\q
```

#### На Standby (VM2):

```bash
psql -U main1 -d testdb -h 127.0.0.1
```

```sql
-- Проверка режима recovery
select pg_is_in_recovery();  -- должно вернуть 't' (true)

-- Проверка данных
select * from users;
select * from orders;

-- Попытка записи (должна выдать ошибку)
insert into users (name, email) values ('test', 'test@test.com');
\q
```

#### С клиентской машины (MacOS):

```bash
# Подключение к Master (чтение/запись)
psql -h 192.168.56.2 -U main1 -d testdb
# Пароль: 123qwe123qwe
```

```sql
-- Проверка чтения
select * from users;

-- Проверка записи
insert into users (name, email) values ('david', 'david@example.com');
select * from users;
\q
```

```bash
# Подключение к Standby (только чтение)
psql -h 192.168.56.3 -U main1 -d testdb
```

```sql
-- Проверка синхронизации данных
select * from users where name = 'david';

-- Попытка записи (ошибка)
insert into users (name, email) values ('eve', 'eve@example.com');
\q
```

---

## Создание скриптов автоматического переключения

### Скрипт мониторинга и автоматического failover на VM2

Создаем скрипт `/home/main/auto_failover.sh` на VM2:

```bash
vim /home/main/auto_failover.sh
```

```bash
#!/bin/bash

# Конфигурация
MASTER_HOST="192.168.56.2"
STANDBY_HOST="192.168.56.3"
DB_USER="main1"
DB_NAME="testdb"
PGDATA="/var/lib/postgresql/17/main"
LOG_FILE="/home/main/failover.log"
LOCK_FILE="/tmp/failover.lock"

# Проверка блокировки для предотвращения одновременных запусков
if [ -f "$LOCK_FILE" ]; then
    # Проверяем, не завис ли предыдущий процесс
    if kill -0 $(cat "$LOCK_FILE") 2>/dev/null; then
        exit 0  # Предыдущий процесс еще работает
    else
        rm -f "$LOCK_FILE"  # Удаляем устаревший lock файл
    fi
fi

# Создаем lock файл
echo $$ > "$LOCK_FILE"

# Функция очистки при выходе
cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Функция логирования
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

# Проверка доступности Master
check_master() {
    # Делаем несколько попыток с таймаутом
    for i in {1..3}; do
        if timeout 5 psql -h $MASTER_HOST -U $DB_USER -d $DB_NAME -c "select 1;" > /dev/null 2>&1; then
            return 0  # Master доступен
        fi
        sleep 2
    done
    return 1  # Master недоступен
}

# Проверка, является ли текущий узел Master
is_master() {
    # Делаем несколько быстрых попыток подключения
    for i in {1..5}; do
        result=$(timeout 3 psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME -t -c "select pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
        if [ "$result" = "f" ]; then
            return 0  # Это Master
        elif [ "$result" = "t" ]; then
            return 1  # Это Standby
        fi
        # Если результат пустой, ждем немного и пробуем снова
        sleep 1
    done
    return 1  # Не удалось определить статус
}

# Промоушн в Master
promote_to_master() {
    log_message "Promoting to Master..."
    
    # Сначала проверяем, не являемся ли мы уже Master
    if is_master; then
        log_message "Already in Master mode, no promotion needed"
        return 0
    fi
    
    # Выполняем промоушн
    promote_output=$(sudo -u postgres /usr/lib/postgresql/17/bin/pg_ctl promote -D $PGDATA 2>&1)
    promote_exit_code=$?
    
    log_message "Promote command output: $promote_output"
    log_message "Promote exit code: $promote_exit_code"
    
    # Если команда промоушна вернула ошибку, проверяем причину
    if [ $promote_exit_code -ne 0 ]; then
        if echo "$promote_output" | grep -q "server is not in standby mode"; then
            log_message "Server is already promoted, checking status..."
            if is_master; then
                log_message "Confirmed: already in Master mode"
                return 0
            fi
        fi
        log_message "Promote command failed with exit code $promote_exit_code"
        return 1
    fi
    
    # Ждем завершения промоушна
    sleep 3
    
    # Проверяем статус несколько раз с коротким интервалом
    for i in {1..10}; do
        log_message "Checking master status, attempt $i/10"
        if is_master; then
            log_message "Successfully promoted to Master"
            return 0
        fi
        sleep 1
    done
    
    log_message "Failed to promote to Master or unable to verify status"
    return 1
}

# Переключение обратно в Standby
switch_to_standby() {
    log_message "Switching back to Standby mode..."
    
    # Остановка PostgreSQL
    sudo systemctl stop postgresql
    
    # Очистка данных
    sudo -i -c "rm -rf /var/lib/postgresql/17/main/*"
    
    # Создание нового базового бэкапа
    sudo -u postgres pg_basebackup \
        -h $MASTER_HOST \
        -D $PGDATA \
        -U replicator \
        -v -P \
        -X stream \
        -R > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        # Запуск как Standby
        sudo systemctl start postgresql
        sleep 5
        
        if ! is_master; then
            log_message "Successfully switched back to Standby"
            return 0
        fi
    fi
    
    log_message "Failed to switch back to Standby"
    return 1
}

# Основная логика
main() {
    log_message "=== Starting failover check ==="
    
    # Проверяем текущее состояние
    log_message "Checking current node status..."
    if is_master; then
        log_message "Current node is MASTER"
        # Мы Master, проверяем, доступен ли оригинальный Master
        log_message "Checking if original Master is back online..."
        if check_master && [ "$MASTER_HOST" != "127.0.0.1" ]; then
            log_message "Original Master is back online, switching to Standby"
            switch_to_standby
        else
            log_message "We are Master, original Master still down or we are the original Master"
        fi
    else
        log_message "Current node is STANDBY"
        # Мы Standby, проверяем доступность Master
        log_message "Checking Master availability..."
        if ! check_master; then
            log_message "Master is down, initiating failover"
            promote_to_master
        else
            log_message "Master is available, we remain Standby"
        fi
    fi
    
    log_message "=== Failover check completed ==="
}

# Запуск основной логики
main
```

Делаем скрипт исполняемым:
```bash
chmod +x /home/main/auto_failover.sh
```

### Настройка cron для автоматического мониторинга

```bash
# Редактирование crontab
crontab -e
```

Добавить строку:
```
*/2 * * * * /home/main/auto_failover.sh
```

### Скрипт для VM1 (оригинальный Master)

Создаем скрипт `/home/main/master_monitor.sh` на VM1:

```bash
vim /home/main/master_monitor.sh
```

```bash
#!/bin/bash

# Конфигурация
STANDBY_HOST="192.168.56.3"
DB_USER="main1"
DB_NAME="testdb"
LOG_FILE="/home/main/master_monitor.log"

# Функция логирования
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

# Проверка, является ли Standby теперь Master
check_standby_is_master() {
    result=$(psql -h $STANDBY_HOST -U $DB_USER -d $DB_NAME -t -c "select pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
    if [ "$result" = "f" ]; then
        return 0  # Standby стал Master
    else
        return 1  # Standby остается Standby
    fi
}

# Основная логика
main() {
    # Проверяем статус PostgreSQL
    if ! systemctl is-active --quiet postgresql; then
        log_message "PostgreSQL is not running on original Master"
        
        # Проверяем, стал ли Standby Master
        if check_standby_is_master; then
            log_message "Standby has been promoted to Master"
        fi
    else
        log_message "PostgreSQL is running normally on Master"
    fi
}

# Запуск основной логики
main
```

Делаем скрипт исполняемым и добавляем в cron:
```bash
chmod +x /home/main/master_monitor.sh

# Добавление в cron
crontab -e
```

Добавить строку:
```
*/2 * * * * /home/main/master_monitor.sh
```

---

## Этап 2. Симуляция и обработка сбоя

### 2.1 Подготовка - демонстрация работы

#### Открыть несколько терминалов на MacOS:

**Терминал 1 - Мониторинг Master:**
```bash
# Подключение к Master
psql -h 192.168.56.2 -U main1 -d testdb
```

```sql
-- Добавление данных перед сбоем
insert into users (name, email) values ('before_crash', 'before@crash.com');
insert into orders (user_id, product, amount) values (1, 'before_crash_product', 999.99);

-- Проверка данных
select 'MASTER DATA:' as source;
select * from users order by id desc limit 3;
select * from orders order by id desc limit 3;
\q
```

**Терминал 2 - Мониторинг Standby:**
```bash
# Подключение к Standby
psql -h 192.168.56.3 -U main1 -d testdb
```

```sql
-- Проверка синхронизации
select 'STANDBY DATA:' as source;
select * from users order by id desc limit 3;
select * from orders order by id desc limit 3;

-- Проверка статуса
select 'STANDBY STATUS:' as info, pg_is_in_recovery() as is_standby;
\q
```

**Терминал 3 - Непрерывный мониторинг:**
```bash
# Мониторинг доступности Master
while true; do
    echo "=== $(date) ==="
    echo "Master status:"
    psql -h 192.168.56.2 -U main1 -d testdb -c "select 'Master is UP', count(*) from users;" 2>/dev/null || echo "Master is DOWN"
    
    echo "Standby status:"
    psql -h 192.168.56.3 -U main1 -d testdb -c "select 'Standby mode:', pg_is_in_recovery();" 2>/dev/null || echo "Standby is DOWN"
    
    echo "---"
    sleep 5
done
```

### 2.2 Сбой - симуляция программной ошибки

На VM1 (Master):
```bash
# Симуляция программной ошибки
sudo pkill -9 postgres
```

### 2.3 Обработка - автоматическое переключение

#### Наблюдение за логами на VM2:

```bash
# Просмотр логов автоматического переключения
tail -f /home/main/failover.log

# Просмотр логов PostgreSQL
sudo tail -f /var/log/postgresql/postgresql-17-main.log
```

#### Ожидание автоматического переключения (до 1 минуты)

Скрипт автоматически обнаружит недоступность Master и выполнит promote.

#### Проверка нового статуса на VM2:

```bash
psql -U main1 -d testdb -h 127.0.0.1
```

```sql
-- Проверка, что больше не в recovery режиме
select pg_is_in_recovery();  -- должно вернуть 'f' (false)

-- Проверка, что можем писать
insert into users (name, email) values ('after_failover', 'after@failover.com');
insert into orders (user_id, product, amount) values (2, 'failover_product', 777.77);

select * from users order by id desc limit 5;
select * from orders order by id desc limit 5;
\q
```

#### Проверка с клиента (MacOS):

```bash
# Теперь подключаемся к VM2 для записи
psql -h 192.168.56.3 -U main1 -d testdb
```

```sql
-- Проверка записи на новый Master
insert into users (name, email) values ('new_master_test', 'newmaster@test.com');
select * from users order by id desc limit 5;

-- Демонстрация транзакций
begin;
insert into users (name, email) values ('transaction_test', 'transaction@test.com');
insert into orders (user_id, product, amount) values (3, 'transaction_product', 555.55);
commit;

select * from users order by id desc limit 3;
select * from orders order by id desc limit 3;
\q
```

---

## Этап 3. Восстановление

### 3.1 Восстановление старого Master (VM1)

На VM1:
```bash
# Запуск PostgreSQL (попытка)
sudo systemctl start postgresql

# Проверка статуса
sudo systemctl status postgresql

# Если запустился, остановка для корректной настройки
sudo systemctl stop postgresql
```

#### Автоматическое переключение обратно

Скрипт на VM2 автоматически обнаружит, что оригинальный Master снова доступен, и переключится обратно в режим Standby.

#### Наблюдение за процессом:

На VM2:
```bash
# Просмотр логов переключения
tail -f /home/main/failover.log
```

На VM1:
```bash
# Просмотр логов мониторинга
tail -f /home/main/master_monitor.log
```

### 3.2 Проверка восстановления исходной конфигурации

#### На Master (VM1):

```bash
# Ожидание завершения автоматического процесса
sleep 60

# Проверка статуса
psql -U main1 -d testdb -h 127.0.0.1
```

```sql
-- Проверка статуса Master
select pg_is_in_recovery();  -- должно быть false

-- Проверка данных (должны быть все данные, включая добавленные во время сбоя)
select * from users order by id;
select * from orders order by id;

-- Проверка репликации
select * from pg_stat_replication;
\q
```

#### На Standby (VM2):

```bash
psql -U main1 -d testdb -h 127.0.0.1
```

```sql
-- Проверка статуса Standby
select pg_is_in_recovery();  -- должно быть true

-- Проверка синхронизации данных
select * from users order by id;
select * from orders order by id;

-- Попытка записи (должна быть ошибка)
insert into users (name, email) values ('test_after_restore', 'test@restore.com');
\q
```

### 3.3 Финальная демонстрация работы

#### С клиента (MacOS):

```bash
# Подключение к восстановленному Master
psql -h 192.168.56.2 -U main1 -d testdb
```

```sql
-- Финальный тест записи на Master
insert into users (name, email) values ('final_test', 'final@test.com');
insert into orders (user_id, product, amount) values (1, 'final_product', 123.45);

-- Проверка всех данных
select 'FINAL MASTER DATA:' as info;
select * from users order by id;
select * from orders order by id;
\q
```

```bash
# Проверка синхронизации на Standby
psql -h 192.168.56.3 -U main1 -d testdb
```

```sql
-- Проверка финальной синхронизации
select 'FINAL STANDBY DATA:' as info;
select * from users order by id;
select * from orders order by id;

-- Подтверждение режима Standby
select 'STANDBY STATUS:' as info, pg_is_in_recovery() as is_standby;
\q
```

---

## Устранение проблем

### Проблема: Медленная работа скрипта и конфликты запусков

**Симптомы:**
```
2025-09-15 02:42:01 - Checking current node status...
2025-09-15 02:42:21 - Current node is STANDBY  # 20 секунд на проверку!
```

И ошибки повторного промоушна:
```
2025-09-15 02:45:28 - Promote command output: pg_ctl: cannot promote server; server is not in standby mode
```

**Причины:**
1. Функция `is_master()` работает слишком медленно (до 20 секунд)
2. Новые запуски cron начинаются, пока предыдущие еще работают
3. Попытки повторного промоушна уже промоутнутого сервера

**Решения в обновленном скрипте:**
- **Lock-файл** для предотвращения одновременных запусков
- **Быстрые таймауты**: 3 секунды вместо без ограничений
- **Меньше попыток**: 5 вместо 10 для проверки статуса
- **Защита от повторного промоушна**: проверка текущего статуса перед промоушном
- **Обработка ошибки "not in standby mode"**: автоматическая проверка, что сервер уже Master
- **Частота cron**: каждые 2 минуты вместо каждой минуты

**Проверка успешности промоушна вручную:**
```bash
# На VM2 после сообщения о неудачном промоушне
psql -U main1 -d testdb -h 127.0.0.1 -c "select case when pg_is_in_recovery() then 'STANDBY' else 'MASTER' end as status;"

# Проверка логов PostgreSQL
sudo tail -20 /var/log/postgresql/postgresql-17-main.log

# Проверка процессов
ps aux | grep postgres
```

### Дополнительные команды для диагностики скрипта

```bash
# Просмотр полных логов failover
cat /home/main/failover.log

# Запуск скрипта вручную для отладки
/home/main/auto_failover.sh

# Проверка cron задач
crontab -l
sudo systemctl status cron

# Проверка прав на выполнение скрипта
ls -la /home/main/auto_failover.sh
```

---

## Полезные команды для диагностики

```bash
# Проверка процессов PostgreSQL
ps aux | grep postgres

# Статус службы
sudo systemctl status postgresql

# Логи PostgreSQL
sudo tail -f /var/log/postgresql/postgresql-17-main.log

# Логи автоматического переключения
tail -f /home/main/failover.log

# Проверка портов
sudo netstat -tlpn | grep 5432

# Проверка cron задач
crontab -l

# Проверка SSH соединения
ssh main@192.168.56.2 'echo "Connection OK"'
ssh main@192.168.56.3 'echo "Connection OK"'
```

### SQL команды для мониторинга:

```sql
-- Проверка репликации на Master
select application_name, state, sync_state, replay_lsn from pg_stat_replication;

-- Проверка задержки репликации
select extract(epoch from (now() - pg_last_xact_replay_timestamp())) as replication_lag;

-- Размер отставания WAL
select pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as replication_lag from pg_stat_replication;

-- Текущий статус узла
select case when pg_is_in_recovery() then 'STANDBY' else 'MASTER' end as node_status;
```

---

## Заключение

В результате выполнения лабораторной работы была успешно настроена отказоустойчивая система PostgreSQL с автоматическим переключением ролей:

1. **Настроена репликация Master + Hot Standby** между двумя виртуальными машинами
2. **Реализован автоматический failover** с помощью bash скриптов и cron
3. **Продемонстрирован сценарий отказа и восстановления** с сохранением всех данных
4. **Обеспечено автоматическое возвращение к исходной конфигурации** при восстановлении основного узла

Система способна автоматически переключаться между ролями Master и Standby в течение 1 минуты после обнаружения сбоя, обеспечивая минимальное время простоя и полную сохранность данных.

