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
host    all             all             0.0.0.0/0               md5
host    replication     replicator      0.0.0.0/0               md5
EOF

# Перезапуск PostgreSQL
sudo systemctl restart postgresql
sudo systemctl status postgresql
```

#### Блок 4: Создание тестовых данных

```sql
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
insert into users (name, email) values 
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com');

insert into orders (user_id, product, amount) values 
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
sudo rm -rf /var/lib/postgresql/17/main
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
host    all             all             0.0.0.0/0               md5
EOF

+ listen_addresses = '*' в postgresql.conf

# Запуск Standby
sudo systemctl start postgresql
sudo systemctl status postgresql
```

### Проверка репликации

#### Блок 7: Проверка на Master

```sql
-- Статус репликации на Master (VM1)
select application_name, state, sync_state fro pg_stat_replication;
-- Тест записи
insert into users (name, email) values ('test_user', 'test@example.com');
EOF
```

#### Блок 8: Проверка на Standby

```sql
-- Проверка на Standby (VM2)

-- Проверка режима Standby
select pg_is_in_recovery();

-- Проверка данных (включая новые)
select * from users where name = 'test_user';

-- Попытка записи (должна быть ошибка)
insert into users (name, email) values ('should_fail', 'fail@example.com');
EOF
```

#### Блок 9: Проверка с клиента (MacOS)

Аналогично

---

## Этап 2. Симуляция и обработка сбоя

### 2.1 Подготовка - демонстрация работы

#### Блок 10: Несколько клиентских подключений

Аналогично

### 2.2 Сбой - симуляция программной ошибки

#### Блок 11: Симуляция сбоя на Master (VM1)

```bash
# На VM1 - убиваем все процессы PostgreSQL
sudo pkill -9 postgres
```

```sql
-- На VM1 в терминальной сессии проверяем стаутс (соединение должно быть разорвано)
select 1;
```

### 2.3 Обработка сбоя

#### Блок 12: Проверка логов

```bash
# На VM2 - проверка логов Standby
sudo cat /var/log/postgresql/postgresql-17-main.log

# На VM1 - проверка логов Master (после сбоя)
sudo cat /var/log/postgresql/postgresql-17-main.log
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

```sql
-- Проверка статуса нового Master (VM2)
-- Проверка статуса
select pg_is_in_recovery();

-- Проверка данных
select * from users by id decs;
select * from orders by id decs;

-- Тест записи в новый Master
insert into users (name, email) values ('after_failover', 'after@failover.com');
insert into orders (user_id, product, amount) values (2, 'failover_product', 777.77);

select * from users by id decs;
select * from orders by id decs;
```

#### Блок 15: Проверка с клиента

```sql
select * from users by id decs;
select * from orders by id decs;
```

---

## Восстановление

### Блок 16: Восстановление основного узла (VM1)

```bash
# Если не запускается из-за повреждений, очищаем данные
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/17/main

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

```sql
-- psql на VM1
select * from users by id decs;
select * from orders by id decs;
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
sudo rm -rf /var/lib/postgresql/17/main

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

```sql
-- Проверка Master (VM1)
-- Проверка статуса Master
select pg_is_in_recovery();

-- Проверка репликации
select application_name, state, sync_state FROM pg_stat_replication;

-- Финальный тест записи
insert into users (name, email) values ('final_test', 'final@test.com');
select * from users by id decs;
```

```sql
-- Проверка статуса Standby
select pg_is_in_recovery();

-- Проверка синхронизации финального теста
select * from users by id decs;

-- Попытка записи (должна быть ошибка)
insert into users (name, email) values ('should_fail_again', 'fail@again.com');
```
