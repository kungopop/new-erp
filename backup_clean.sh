#!/usr/bin/env bash
set -Eeuo pipefail

# backup_clean.sh
# Clean stable backup for Roshdy ERP/Frappe Docker system before next feature.
# It backs up: restaurant_ops app source, docker compose config, site_config, Frappe DB/files backup,
# plus health-check reports for Elastix/CDR/AMI, queue, call report, and important pages.
# It DOES NOT modify code, DB data, Elastix, AMI, CDR, FortiGate, or Docker config.

SITE="crm.local"
ROOT="/opt/frappe_crm"
APP_DIR="$ROOT/apps/restaurant_ops"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_NAME="CLEAN_STABLE_BEFORE_NEXT_FEATURE_$TS"
BACKUP_DIR="$ROOT/backups/$BACKUP_NAME"
ARCHIVE="$ROOT/backups/$BACKUP_NAME.tar.gz"

say(){ echo -e "\n============================================================\n$1\n============================================================"; }
run_capture(){
  local title="$1"; shift
  local file="$1"; shift
  echo "--- $title ---" | tee -a "$BACKUP_DIR/backup_run.log"
  ( "$@" ) > "$file" 2>&1 || true
  cat "$file" | tail -n 80 | tee -a "$BACKUP_DIR/backup_run.log" || true
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "❌ شغّل كـ root: sudo -i ثم bash backup_clean.sh"
  exit 1
fi

say "1) تجهيز Backup Folder نظيف"
cd "$ROOT"
BACKEND="$(docker compose ps -q backend || true)"
if [[ -z "$BACKEND" ]]; then
  echo "❌ لم أجد backend container. شغّل: cd /opt/frappe_crm && docker compose up -d"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
{
  echo "Backup Name: $BACKUP_NAME"
  echo "Created At: $(date -Is)"
  echo "Root: $ROOT"
  echo "Site: $SITE"
  echo "Backend Container: $BACKEND"
  echo "Purpose: clean stable point before next feature"
} | tee "$BACKUP_DIR/MANIFEST.txt"

echo "✅ Backup folder: $BACKUP_DIR"

say "2) Snapshot لحالة Docker والملفات المهمة"
run_capture "docker compose ps" "$BACKUP_DIR/docker_compose_ps.txt" docker compose ps
run_capture "docker compose config" "$BACKUP_DIR/docker_compose_config.yml" docker compose config
run_capture "root folder listing" "$BACKUP_DIR/root_listing.txt" bash -lc "ls -lah '$ROOT'"
run_capture "backups listing" "$BACKUP_DIR/backups_listing.txt" bash -lc "ls -lah '$ROOT/backups' | tail -n 80"

# Copy compose/env files if present
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml .env; do
  if [[ -f "$ROOT/$f" ]]; then
    cp -a "$ROOT/$f" "$BACKUP_DIR/$f"
  fi
done

# Site config contains secrets; saved locally for restore only.
docker exec "$BACKEND" bash -lc "cat /home/frappe/frappe-bench/sites/$SITE/site_config.json" > "$BACKUP_DIR/site_config.json" 2>/dev/null || true

docker exec "$BACKEND" bash -lc "bench version" > "$BACKUP_DIR/bench_version.txt" 2>&1 || true

say "3) Backup سورس تطبيق restaurant_ops"
if [[ -d "$APP_DIR" ]]; then
  tar \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.git' \
    --exclude='.mypy_cache' \
    --exclude='.pytest_cache' \
    -czf "$BACKUP_DIR/restaurant_ops_app_source.tar.gz" \
    -C "$ROOT/apps" restaurant_ops
  ls -lh "$BACKUP_DIR/restaurant_ops_app_source.tar.gz" | tee -a "$BACKUP_DIR/backup_run.log"
else
  echo "⚠️ لم أجد $APP_DIR" | tee -a "$BACKUP_DIR/backup_run.log"
fi

say "4) Frappe bench backup للـ DB والملفات"
# This creates DB/private/public files backup inside the backend container/site backups folder.
docker exec "$BACKEND" bench --site "$SITE" backup --with-files > "$BACKUP_DIR/bench_backup_output.txt" 2>&1 || {
  echo "⚠️ bench backup returned non-zero. Output:" | tee -a "$BACKUP_DIR/backup_run.log"
  cat "$BACKUP_DIR/bench_backup_output.txt" | tee -a "$BACKUP_DIR/backup_run.log"
}
cat "$BACKUP_DIR/bench_backup_output.txt" | tail -n 100 | tee -a "$BACKUP_DIR/backup_run.log" || true

# Copy latest bench backup files from container into this stable backup directory.
docker exec "$BACKEND" bash -lc "
set -e
B='/home/frappe/frappe-bench/sites/$SITE/private/backups'
TMP='/tmp/roshdy_clean_backup_latest'
rm -rf \"\$TMP\" /tmp/roshdy_clean_backup_latest.tar.gz
mkdir -p \"\$TMP\"
if [ -d \"\$B\" ]; then
  find \"\$B\" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -nr | head -n 12 | cut -d' ' -f2- | while IFS= read -r f; do
    [ -f \"\$f\" ] && cp -a \"\$f\" \"\$TMP/\"
  done
fi
tar -czf /tmp/roshdy_clean_backup_latest.tar.gz -C /tmp roshdy_clean_backup_latest
ls -lah /tmp/roshdy_clean_backup_latest.tar.gz
" > "$BACKUP_DIR/container_backup_pack_output.txt" 2>&1 || true

docker cp "$BACKEND:/tmp/roshdy_clean_backup_latest.tar.gz" "$BACKUP_DIR/frappe_bench_db_and_files_latest.tar.gz" >/dev/null 2>&1 || true
ls -lh "$BACKUP_DIR/frappe_bench_db_and_files_latest.tar.gz" 2>/dev/null | tee -a "$BACKUP_DIR/backup_run.log" || true

say "5) Export معلومات تشغيل مهمة قبل التطوير الجديد"
# Current active extension sessions
run_capture "active extension sessions" "$BACKUP_DIR/active_extension_sessions.txt" \
  docker exec "$BACKEND" bench --site "$SITE" execute frappe.db.sql --args '["select extension,user,session_status,active,started_at,released_at from `tabExtension Session` where session_status=\"active\" order by creation desc limit 50"]'

# Host name check
run_capture "host_name config" "$BACKUP_DIR/host_name_config.txt" \
  docker exec "$BACKEND" bash -lc "cat /home/frappe/frappe-bench/sites/$SITE/site_config.json | grep -E '\"host_name\"|\"db_name\"' || true"

# Agent notices status
run_capture "agent notices API" "$BACKUP_DIR/agent_notices_status.json" \
  docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.agent_notice_api.get_active_notices

# Important pages status
{
  echo "Important pages status at $(date -Is)"
  for page in login admin-desk agent-desk select-extension my-break sales-entry sales-report call-report hr-ops agent-notices quality-desk settings roshdy-logout; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/$page" || true)"
    echo "$page => $code"
  done
} | tee "$BACKUP_DIR/pages_status.txt"

say "6) Health Check: Elastix/CDR/AMI + Queue + Call Report"
run_capture "asterisk full diagnostics" "$BACKUP_DIR/health_asterisk_diagnostics.json" \
  docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.asterisk_bridge.run_full_system_diagnostics

run_capture "queue status" "$BACKUP_DIR/health_queue_status.json" \
  docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.queue_api.get_queue_status

run_capture "calls report admin sample" "$BACKUP_DIR/health_calls_report_admin.json" \
  docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.report_api.get_calls_report --kwargs '{"page":1,"page_size":5,"view_mode":"admin"}'

say "7) كتابة Restore Notes"
cat > "$BACKUP_DIR/RESTORE_NOTES.txt" <<EOF
ROSHDY CLEAN STABLE BACKUP
==========================
Name: $BACKUP_NAME
Created: $(date -Is)
Path: $BACKUP_DIR
Archive: $ARCHIVE

Contains:
1) restaurant_ops_app_source.tar.gz
   - Custom application source snapshot.
2) frappe_bench_db_and_files_latest.tar.gz
   - Latest Frappe bench backup files copied from container.
3) docker compose files/config/status.
4) site_config.json
   - Contains sensitive local restore data; keep private.
5) health check outputs:
   - health_asterisk_diagnostics.json
   - health_queue_status.json
   - health_calls_report_admin.json
6) pages_status.txt

Restore idea if needed:
- Stop app services carefully.
- Restore app source from restaurant_ops_app_source.tar.gz to /opt/frappe_crm/apps/restaurant_ops.
- Restore Frappe DB/files using bench restore from the files inside frappe_bench_db_and_files_latest.tar.gz.
- Clear cache and restart containers.

Important:
This backup script did NOT modify Elastix/CDR/AMI/FortiGate.
EOF

say "8) إنشاء أرشيف مضغوط للباك أب كله + Checksum"
# Create final tar.gz archive next to the folder.
tar -czf "$ARCHIVE" -C "$ROOT/backups" "$BACKUP_NAME"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

ls -lh "$ARCHIVE" "$ARCHIVE.sha256" | tee -a "$BACKUP_DIR/backup_run.log"

say "✅ Clean Stable Backup Done يا زعيم"
echo "Backup folder: $BACKUP_DIR"
echo "Backup archive: $ARCHIVE"
echo "Checksum: $ARCHIVE.sha256"
echo "ابعتلي آخر جزء من اللوج لو حابب أراجعه قبل ما نبدأ الميزة الجديدة."
