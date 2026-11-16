#!/bin/bash
# macOS Catalina / Bash 3.2. Run as root through the supplied LaunchDaemon.
set -u
set -o pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/var/root
unset MYSQL_PWD MYSQL_TEST_LOGIN_FILE
MYSQL_BIN=/usr/local/mysql/bin
BASE=/usr/local/backups/mysql
LOGIN_PATH=boulogne-backup
LOCK="$BASE/.backup.lock"
TMP=
STATUS=0

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo 'Run as root; credentials belong to /var/root.' >&2; exit 1
fi
/bin/mkdir -p "$BASE/logs" || exit 1
LOG="$BASE/logs/backup_$(/bin/date +%Y-%m-%d).log"
exec >>"$LOG" 2>&1
log() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
if ! /bin/mkdir "$LOCK" 2>/dev/null; then
    log 'ERROR: lock exists; another run is active or a stale lock needs inspection.'; exit 1
fi
cleanup() {
    [ -z "$TMP" ] || /bin/rm -f "$TMP"
    /bin/rm -f "$LOCK/pid"
    /bin/rmdir "$LOCK" 2>/dev/null || :
}
trap cleanup EXIT
trap 'log "ERROR: interrupted"; exit 1' HUP INT TERM
printf '%s\n' "$$" > "$LOCK/pid"
log 'START boulogne: stream and bloom'
for tool in mysql mysqldump; do
    if [ ! -x "$MYSQL_BIN/$tool" ]; then
        log "ERROR: missing $MYSQL_BIN/$tool; edit MYSQL_BIN in script."; exit 1
    fi
done
STAMP=$(/bin/date +%Y-%m-%d_%H%M%S)_$$
for DB in stream bloom; do
    DIR="$BASE/$DB"
    if ! /bin/mkdir -p "$DIR"; then
        log "ERROR $DB: cannot create output directory"; STATUS=1; continue
    fi
    # Refuse a misleading consistent backup of nontransactional tables.
    if ! ENGINES=$("$MYSQL_BIN/mysql" --no-defaults --login-path="$LOGIN_PATH" \
        --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=15 \
        --batch --skip-column-names --execute="SELECT CONCAT(TABLE_NAME, ':', COALESCE(ENGINE,'NULL')) FROM information_schema.tables WHERE table_schema='$DB' AND TABLE_TYPE='BASE TABLE' AND COALESCE(ENGINE,'') <> 'InnoDB';"); then
        log "ERROR $DB: engine preflight failed"; STATUS=1; continue
    fi
    if [ -n "$ENGINES" ]; then
        log "ERROR $DB: non-InnoDB tables require a planned locked backup: $ENGINES"
        STATUS=1; continue
    fi
    TMP=$(/usr/bin/mktemp "$DIR/.${DB}_${STAMP}.partial.XXXXXX") || {
        log "ERROR $DB: cannot create temporary file"; STATUS=1; TMP=; continue;
    }
    FINAL="$DIR/${DB}_${STAMP}.sql.gz"
    log "BEGIN $DB"
    if "$MYSQL_BIN/mysqldump" --no-defaults --login-path="$LOGIN_PATH" \
        --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=15 \
        --single-transaction --quick --skip-lock-tables --no-tablespaces \
        --set-gtid-purged=OFF --column-statistics=0 --default-character-set=utf8mb4 \
        --hex-blob --routines --triggers --events --databases "$DB" \
        | /usr/bin/gzip -c > "$TMP"; then
        if [ -s "$TMP" ] && /usr/bin/gzip -t "$TMP" && /bin/mv "$TMP" "$FINAL"; then
            TMP=
            log "SUCCESS $DB: $FINAL"
            # BSD find: +29 means at least 30 completed 24-hour periods old.
            # Only prune this database after its new dump was published.
            if ! /usr/bin/find "$DIR" -type f -name "${DB}_*.sql.gz" -mtime +29 -exec /bin/rm -f {} \;; then
                log "ERROR $DB: retention failed"; STATUS=1
            fi
        else
            log "ERROR $DB: validation or publication failed"; STATUS=1
        fi
    else
        log "ERROR $DB: mysqldump or gzip failed"; STATUS=1
    fi
    if [ -n "$TMP" ]; then /bin/rm -f "$TMP"; TMP=; fi
done
if ! /usr/bin/find "$BASE/logs" -type f -name 'backup_????-??-??.log' -mtime +29 -exec /bin/rm -f {} \;; then
    log 'ERROR: log retention failed'; STATUS=1
fi
log "END status=$STATUS (0=both successful; 1=one or more errors)"
exit "$STATUS"
