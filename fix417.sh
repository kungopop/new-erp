#!/usr/bin/env bash
set -euo pipefail

# fix417.sh
# Emergency rollback for 417 on agent pages after logout JS injection.
# Restores ONLY the 4 agent HTML pages from the backup created before fix_logout_sip.
# Keeps the improved session_api + roshdy-logout page, so logout can still release SIP.

SITE="crm.local"
ROOT="/opt/frappe_crm"
WWW="$ROOT/apps/restaurant_ops/restaurant_ops/www"
TS="$(date +%Y%m%d_%H%M%S)"
SAFETY="$ROOT/backups/BEFORE_FIX417_RESTORE_$TS"

say(){ echo -e "\n============================================================\n$1\n============================================================"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "❌ شغل كـ root: sudo -i ثم bash fix417.sh"
  exit 1
fi

say "1) تحديد أحدث Backup قبل مشكلة 417"
cd "$ROOT"
BACKEND="$(docker compose ps -q backend || true)"
if [[ -z "$BACKEND" ]]; then
  echo "❌ backend container مش موجود. شغل: cd /opt/frappe_crm && docker compose up -d"
  exit 1
fi

BK="$(ls -dt "$ROOT"/backups/FIX_LOGOUT_RELEASE_SIP_BEFORE_* 2>/dev/null | head -n 1 || true)"
if [[ -z "$BK" || ! -d "$BK" ]]; then
  echo "❌ ملقتش Backup باسم FIX_LOGOUT_RELEASE_SIP_BEFORE_*"
  echo "اعرض الباكابات بالأمر: ls -lah /opt/frappe_crm/backups"
  exit 1
fi

echo "✅ هستخدم الباك أب: $BK"

say "2) Backup سريع للوضع الحالي قبل الرجوع"
mkdir -p "$SAFETY"
for p in agent-desk.html my-break.html sales-entry.html select-extension.html; do
  [[ -f "$WWW/$p" ]] && cp -a "$WWW/$p" "$SAFETY/$p.current" || true
done
echo "✅ Safety backup: $SAFETY"

say "3) Restore صفحات الإيجنت فقط من الباك أب الآمن"
for p in agent-desk.html my-break.html sales-entry.html select-extension.html; do
  if [[ -f "$BK/$p.bak" ]]; then
    cp -a "$BK/$p.bak" "$WWW/$p"
    echo "✅ restored $p"
  else
    echo "⚠️ missing $BK/$p.bak"
  fi
done

say "4) إزالة أي بقايا للـ safe logout script لو موجودة"
python3 - <<'PY'
from pathlib import Path
import re
root = Path('/opt/frappe_crm/apps/restaurant_ops/restaurant_ops/www')
for name in ['agent-desk.html','my-break.html','sales-entry.html','select-extension.html']:
    p = root / name
    if not p.exists():
        continue
    s = p.read_text()
    before = s
    s = re.sub(r'<script\s+id=["\']roshdy-safe-logout-script["\'][\s\S]*?</script>\s*', '', s, flags=re.I)
    if s != before:
        p.write_text(s)
        print('cleaned', name)
PY

say "5) Clear cache + restart خدمات التطبيق فقط"
docker exec "$BACKEND" bash -lc "find /home/frappe/frappe-bench/apps/restaurant_ops -name '*.pyc' -delete; find /home/frappe/frappe-bench/apps/restaurant_ops -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true"
docker exec "$BACKEND" bench --site "$SITE" clear-cache || true
docker exec "$BACKEND" bench --site "$SITE" clear-website-cache || true
docker compose restart backend frontend websocket queue-short queue-long scheduler

say "6) اختبار الصفحات"
BACKEND="$(docker compose ps -q backend)"
sleep 8
BAD=0
for page in agent-desk my-break sales-entry select-extension roshdy-logout; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/$page" || true)"
  echo "$page => $code"
  [[ "$code" == "200" ]] || BAD=1
done

if [[ "$BAD" == "1" ]]; then
  echo "⚠️ لسه في صفحة مش 200. آخر أخطاء backend:"
  docker compose logs --tail=250 backend | grep -Ei "TemplateSyntaxError|jinja|Traceback|agent-desk|my-break|sales-entry|select-extension|417" -A4 -B4 || true
fi

say "7) عرض الجلسات النشطة الحالية فقط بدون تغيير"
docker exec "$BACKEND" bench --site "$SITE" execute frappe.db.sql --args '["select extension,user,session_status,active,started_at,released_at from `tabExtension Session` where session_status=\"active\" order by creation desc limit 20"]' || true

say "8) Health Check: Elastix/CDR/AMI + Queue + Call Report"
echo "--- Asterisk/Elastix diagnostics ---"
docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.asterisk_bridge.run_full_system_diagnostics || true

echo "--- Queue status ---"
docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.queue_api.get_queue_status || true

echo "--- Calls report admin sample ---"
docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.report_api.get_calls_report --kwargs '{"page":1,"page_size":5,"view_mode":"admin"}' || true

say "✅ Done"
echo "لو الصفحات رجعت 200: اعمل Ctrl+F5 وجرب /select-extension."
echo "إصلاح تحرير SIP نفسه مازال موجود في /roshdy-logout و session_api، احنا رجعنا HTML بس عشان 417."
echo "لو عايز تحرر 1030 المعلقة يدويًا بعد الرجوع، شغل الأمر اللي هبعتهولك في الشات."
