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
