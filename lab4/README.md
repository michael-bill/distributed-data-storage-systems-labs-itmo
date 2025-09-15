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

---

## Ход выполнения работы

### Архитектура

- **VM1** (192.168.56.2) - Master (Ubuntu)
- **VM2** (192.168.56.3) - Hot Standby (Ubuntu)
- **Client** - MacOS хост-машина
- **PostgreSQL**: версия 17
- **Пароль БД**: 123qwe123qwe

---

## Этап 1. Конфигурация Master + Hot Standby

### Подготовка окружения

#### Установка PostgreSQL на обеих VM:

```bash
# Обновление и установка PostgreSQL (выполнить на VM1 и VM2)
sudo apt update && sudo apt install postgresql postgresql-contrib -y
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Проверка версии
sudo -u postgres psql -c "select version();"

# Проверка IP (должно показать 192.168.56.2 или 192.168.56.3)
ip a | grep 192.168.56
```

### Настройка Master (VM1)

#### Блок 1: Создание пользователей и базы данных

```bash
# Переключение на пользователя postgres и настройка
sudo -i -u postgres
createuser --superuser main1
psql -c "alter user main1 password '123qwe123qwe';"
createuser --replication replicator
psql -c "alter user replicator password '123qwe123qwe';"
createdb -O main1 testdb
exit

# Проверка подключения
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb -c "select current_user;"
```

#### Блок 2: Конфигурация postgresql.conf

```bash
# Создание архивной директории
sudo -u postgres mkdir -p /var/lib/postgresql/17/archive

# Добавление параметров репликации в postgresql.conf
sudo tee -a /etc/postgresql/17/main/postgresql.conf > /dev/null << 'EOF'

# Master configuration
listen_addresses = '*'
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
wal_keep_size = 256MB
hot_standby = on
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/archive/%f && cp %p /var/lib/postgresql/17/archive/%f'
log_replication_commands = on
EOF
```

#### Блок 3: Конфигурация pg_hba.conf

```bash
# Настройка доступа для репликации
sudo tee /etc/postgresql/17/main/pg_hba.conf > /dev/null << 'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.56.0/24         md5
host    replication     replicator      192.168.56.0/24         md5
EOF

# Перезапуск PostgreSQL
sudo systemctl restart postgresql
sudo systemctl status postgresql
```

#### Блок 4: Создание тестовых данных

```bash
# Создание структуры БД и наполнение данными
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb << 'EOF'
-- Создание таблиц
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id),
    product VARCHAR(200),
    amount DECIMAL(10,2),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Наполнение данными
INSERT INTO users (name, email) VALUES 
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com');

INSERT INTO orders (user_id, product, amount) VALUES 
    (1, 'laptop', 1200.00),
    (2, 'mouse', 25.50),
    (3, 'keyboard', 75.00);

-- Проверка
SELECT * FROM users;
SELECT * FROM orders;
EOF
```

### Настройка Standby (VM2)

#### Блок 5: Подготовка Standby

```bash
# Создание пользователя main1
sudo -i -u postgres
createuser --superuser main1
psql -c "alter user main1 password '123qwe123qwe';"
exit

# Остановка PostgreSQL и очистка данных
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/17/main/*
```

#### Блок 6: Создание базового бэкапа

```bash
# Создание базового бэкапа с Master
sudo -u postgres bash -c "
export PGPASSWORD='123qwe123qwe'
pg_basebackup \
  -h 192.168.56.2 \
  -D /var/lib/postgresql/17/main \
  -U replicator \
  -v -P \
  -X stream \
  -R
"

# Настройка pg_hba.conf для Standby
sudo tee /etc/postgresql/17/main/pg_hba.conf > /dev/null << 'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.56.0/24         md5
EOF

# Запуск Standby
sudo systemctl start postgresql
sudo systemctl status postgresql
```

### Проверка репликации

#### Блок 7: Проверка на Master

```bash
# Проверка статуса репликации на Master (VM1)
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb << 'EOF'
-- Статус репликации
SELECT application_name, state, sync_state FROM pg_stat_replication;

-- Тест записи
INSERT INTO users (name, email) VALUES ('test_user', 'test@example.com');
SELECT * FROM users WHERE name = 'test_user';
EOF
```

#### Блок 8: Проверка на Standby

```bash
# Проверка на Standby (VM2)
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb << 'EOF'
-- Проверка режима Standby
SELECT pg_is_in_recovery();

-- Проверка данных (включая новые)
SELECT * FROM users WHERE name = 'test_user';

-- Попытка записи (должна быть ошибка)
INSERT INTO users (name, email) VALUES ('should_fail', 'fail@example.com');
EOF
```

#### Блок 9: Проверка с клиента (MacOS)

```bash
# Установка клиента (если не установлен)
brew install postgresql

# Тест подключения к Master
PGPASSWORD='123qwe123qwe' psql -h 192.168.56.2 -U main1 -d testdb -c "
SELECT 'MASTER: ' || current_database() AS connection_test;
SELECT COUNT(*) AS total_users FROM users;
"

# Тест подключения к Standby
PGPASSWORD='123qwe123qwe' psql -h 192.168.56.3 -U main1 -d testdb -c "
SELECT 'STANDBY: ' || current_database() AS connection_test;
SELECT COUNT(*) AS total_users FROM users;
SELECT 'Is Standby: ' || pg_is_in_recovery() AS standby_status;
"
```

---

## Этап 2. Симуляция и обработка сбоя

### 2.1 Подготовка - демонстрация работы

#### Блок 10: Несколько клиентских подключений

```bash
# Терминал 1 - Подключение к Master для записи
PGPASSWORD='123qwe123qwe' psql -h 192.168.56.2 -U main1 -d testdb << 'EOF'
-- Добавление данных перед сбоем
INSERT INTO users (name, email) VALUES ('before_crash', 'before@crash.com');
INSERT INTO orders (user_id, product, amount) VALUES (1, 'before_crash_product', 999.99);

-- Начинаем транзакцию (не завершаем)
BEGIN;
INSERT INTO users (name, email) VALUES ('in_transaction', 'transaction@example.com');
-- НЕ КОММИТИМ - оставляем транзакцию висящей
SELECT txid_current() AS transaction_id;
EOF
```

```bash
# Терминал 2 - Проверка данных на Master
PGPASSWORD='123qwe123qwe' psql -h 192.168.56.2 -U main1 -d testdb -c "
SELECT 'MASTER DATA BEFORE CRASH:' AS status;
SELECT * FROM users ORDER BY id DESC LIMIT 5;
SELECT * FROM orders ORDER BY id DESC LIMIT 3;
"
```

```bash
# Терминал 3 - Проверка данных на Standby
PGPASSWORD='123qwe123qwe' psql -h 192.168.56.3 -U main1 -d testdb -c "
SELECT 'STANDBY DATA BEFORE CRASH:' AS status;
SELECT * FROM users ORDER BY id DESC LIMIT 5;
SELECT * FROM orders ORDER BY id DESC LIMIT 3;
SELECT 'Standby Status: ' || pg_is_in_recovery() AS standby_check;
"
```

### 2.2 Сбой - симуляция программной ошибки

#### Блок 11: Симуляция сбоя на Master (VM1)

```bash
# На VM1 - убиваем все процессы PostgreSQL
sudo pkill -9 postgres

# Проверка, что процессы убиты
ps aux | grep postgres
sudo systemctl status postgresql
```

### 2.3 Обработка сбоя

#### Блок 12: Проверка логов

```bash
# На VM2 - проверка логов Standby
sudo tail -20 /var/log/postgresql/postgresql-17-main.log

# На VM1 - проверка логов Master (после сбоя)
sudo tail -20 /var/log/postgresql/postgresql-17-main.log
```

#### Блок 13: Ручное переключение (failover) на Standby

```bash
# На VM2 - промоушн в Master
sudo -u postgres /usr/lib/postgresql/17/bin/pg_ctl promote -D /var/lib/postgresql/17/main

# Добавление конфигурации Master для приема репликации
sudo tee -a /etc/postgresql/17/main/postgresql.conf > /dev/null << 'EOF'

# Master configuration after promotion
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
wal_keep_size = 256MB
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/archive/%f && cp %p /var/lib/postgresql/17/archive/%f'
log_replication_commands = on
EOF

# Создание директории для архивов
sudo -u postgres mkdir -p /var/lib/postgresql/17/archive

# Перезапуск для применения конфигурации
sudo systemctl restart postgresql
```

#### Блок 14: Проверка нового Master

```bash
# Проверка статуса нового Master (VM2)
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb << 'EOF'
-- Проверка статуса
SELECT 'NEW MASTER STATUS: ' || NOT pg_is_in_recovery() AS is_master;

-- Проверка данных
SELECT * FROM users ORDER BY id DESC LIMIT 5;

-- Тест записи в новый Master
INSERT INTO users (name, email) VALUES ('after_failover', 'after@failover.com');
INSERT INTO orders (user_id, product, amount) VALUES (2, 'failover_product', 777.77);

-- Демонстрация транзакции на новом Master
BEGIN;
INSERT INTO users (name, email) VALUES ('transaction_on_new_master', 'new_master@transaction.com');
UPDATE orders SET amount = amount * 1.1 WHERE user_id = 1;
COMMIT;

SELECT 'AFTER FAILOVER:' AS status;
SELECT * FROM users ORDER BY id DESC LIMIT 3;
SELECT * FROM orders ORDER BY id DESC LIMIT 3;
EOF
```

#### Блок 15: Проверка с клиента

```bash
# Подключение к новому Master с клиента (MacOS)
PGPASSWORD='123qwe123qwe' psql -h 192.168.56.3 -U main1 -d testdb -c "
SELECT 'CLIENT CONNECTION TO NEW MASTER:' AS status;
SELECT COUNT(*) AS total_users FROM users;
SELECT COUNT(*) AS total_orders FROM orders;

-- Клиентская транзакция
INSERT INTO users (name, email) VALUES ('client_user', 'client@example.com');
SELECT 'Client can write to new Master: OK' AS test_result;
"
```

---

## Восстановление

### Блок 16: Восстановление основного узла (VM1)

```bash
# На VM1 - запуск PostgreSQL
sudo systemctl start postgresql

# Если не запускается из-за повреждений, очищаем данные
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/17/main/*

# Создание базового бэкапа с нового Master (VM2)
sudo -u postgres bash -c "
export PGPASSWORD='123qwe123qwe'
pg_basebackup \
  -h 192.168.56.3 \
  -D /var/lib/postgresql/17/main \
  -U replicator \
  -v -P \
  -X stream \
  -R
"

# Запуск как Standby
sudo systemctl start postgresql
sudo systemctl status postgresql
```

### Блок 17: Проверка актуализации данных

```bash
# На VM1 - проверка, что данные синхронизированы
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb << 'EOF'
-- Проверка статуса (должен быть Standby)
SELECT 'VM1 STATUS: ' || pg_is_in_recovery() AS is_standby;

-- Проверка ВСЕХ данных (включая записанные во время сбоя)
SELECT 'RESTORED DATA ON VM1:' AS status;
SELECT * FROM users ORDER BY id;
SELECT * FROM orders ORDER BY id;

-- Должны увидеть:
-- 1. Данные до сбоя (before_crash)
-- 2. Данные после failover (after_failover, transaction_on_new_master, client_user)
EOF
```

### Блок 18: Возврат к исходной конфигурации

```bash
# Промоушн VM1 обратно в Master
sudo -u postgres /usr/lib/postgresql/17/bin/pg_ctl promote -D /var/lib/postgresql/17/main

# Добавление конфигурации Master на VM1
sudo tee -a /etc/postgresql/17/main/postgresql.conf > /dev/null << 'EOF'

# Master configuration for VM1
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
wal_keep_size = 256MB
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/17/archive/%f && cp %p /var/lib/postgresql/17/archive/%f'
log_replication_commands = on
EOF

# Создание директории для архивов
sudo -u postgres mkdir -p /var/lib/postgresql/17/archive

# Перезапуск для применения конфигурации
sudo systemctl restart postgresql
```

### Блок 19: Переключение VM2 обратно в Standby

```bash
# На VM2 - остановка и очистка
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/17/main/*

# Создание базового бэкапа с восстановленного Master (VM1)
sudo -u postgres bash -c "
export PGPASSWORD='123qwe123qwe'
pg_basebackup \
  -h 192.168.56.2 \
  -D /var/lib/postgresql/17/main \
  -U replicator \
  -v -P \
  -X stream \
  -R
"

# Настройка pg_hba.conf для Standby
sudo tee /etc/postgresql/17/main/pg_hba.conf > /dev/null << 'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.56.0/24         md5
EOF

# Запуск как Standby
sudo systemctl start postgresql
sudo systemctl status postgresql
```

### Блок 20: Финальная проверка восстановления

```bash
# Проверка Master (VM1)
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb << 'EOF'
-- Проверка статуса Master
SELECT 'VM1 FINAL STATUS: ' || NOT pg_is_in_recovery() AS is_master;

-- Проверка репликации
SELECT application_name, state, sync_state FROM pg_stat_replication;

-- Финальный тест записи
INSERT INTO users (name, email) VALUES ('final_test', 'final@test.com');
SELECT 'FINAL MASTER DATA:' AS status;
SELECT * FROM users ORDER BY id DESC LIMIT 5;
EOF
```

```bash
# Проверка Standby (VM2)
PGPASSWORD='123qwe123qwe' psql -U main1 -h 127.0.0.1 -d testdb << 'EOF'
-- Проверка статуса Standby
SELECT 'VM2 FINAL STATUS: ' || pg_is_in_recovery() AS is_standby;

-- Проверка синхронизации финального теста
SELECT * FROM users WHERE name = 'final_test';

-- Попытка записи (должна быть ошибка)
INSERT INTO users (name, email) VALUES ('should_fail_again', 'fail@again.com');
EOF
```

```bash
# Финальная проверка с клиента (MacOS)
PGPASSWORD='123qwe123qwe' psql -h 192.168.56.2 -U main1 -d testdb -c "
SELECT 'FINAL CLIENT TEST - MASTER:' AS status;
SELECT COUNT(*) AS total_users FROM users;
INSERT INTO users (name, email) VALUES ('client_final', 'client_final@test.com');
"

PGPASSWORD='123qwe123qwe' psql -h 192.168.56.3 -U main1 -d testdb -c "
SELECT 'FINAL CLIENT TEST - STANDBY:' AS status;
SELECT COUNT(*) AS total_users FROM users;
SELECT * FROM users WHERE name = 'client_final';
"
```

---

## Заключение

В результате выполнения лабораторной работы была успешно продемонстрирована отказоустойчивая система PostgreSQL:

1. ✅ **Настроена репликация Master + Hot Standby** между двумя виртуальными машинами
2. ✅ **Продемонстрирован сценарий failover** с ручным переключением ролей
3. ✅ **Показано сохранение данных** - все данные, записанные во время сбоя, сохранены
4. ✅ **Выполнено восстановление** исходной конфигурации VM1=Master, VM2=Standby
5. ✅ **Подтверждена работоспособность** системы после восстановления

### Ключевые моменты:

- **Время простоя системы**: минимальное - только время выполнения команды promote
- **Потеря данных**: отсутствует - все транзакции сохранены
- **Клиентские подключения**: могут быть переключены на новый Master без потери функциональности
- **Репликация**: работает в обоих направлениях при смене ролей
