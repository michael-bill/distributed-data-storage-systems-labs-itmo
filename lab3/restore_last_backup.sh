# ~/restore_last_backup.sh

#!/bin/bash

set -e # Прерывать выполнение при любой ошибке

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
# Поставим откорректированный postgresql.conf (в нем нет настроек для копирования вала, которые нужны только на основном сервере)
cat "$PGDATA_PATH/postgresql.conf.copy" > "$PGDATA_PATH/postgresql.conf"
pg_ctl -D "$PGDATA_PATH" -l "$LOG_FILE" start

sleep 5 # Даем серверу время на запуск

# 6. Проверка статуса
pg_ctl -D "$PGDATA_PATH" status

echo "--- Restoration process finished successfully ---"
