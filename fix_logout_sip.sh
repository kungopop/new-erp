#!/usr/bin/env bash
set -euo pipefail

# fix_logout_sip.sh
# Purpose: On agent logout, release the active SIP extension automatically.
# Safe: takes backup first, does not touch Elastix/CDR/AMI settings.

SITE="crm.local"
ROOT="/opt/frappe_crm"
APP_DIR="$ROOT/apps/restaurant_ops/restaurant_ops"
WWW_DIR="$APP_DIR/www"
API_DIR="$APP_DIR/api"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$ROOT/backups/FIX_LOGOUT_RELEASE_SIP_BEFORE_$TS"

say(){ echo -e "\n============================================================\n$1\n============================================================"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "❌ شغّل السكريبت كـ root: sudo -i ثم bash fix_logout_sip.sh"
  exit 1
fi

say "1) تجهيز Backup آمن قبل تعديل Logout/SIP"
cd "$ROOT"
BACKEND="$(docker compose ps -q backend || true)"
if [[ -z "$BACKEND" ]]; then
  echo "❌ لم أجد backend container. شغّل: cd /opt/frappe_crm && docker compose up -d"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
for f in \
  "$API_DIR/session_api.py" \
  "$API_DIR/sip_api.py" \
  "$API_DIR/session_events.py" \
  "$APP_DIR/hooks.py" \
  "$WWW_DIR/roshdy-logout.py" \
  "$WWW_DIR/roshdy-logout.html" \
  "$WWW_DIR/agent-desk.html" \
  "$WWW_DIR/my-break.html" \
  "$WWW_DIR/sales-entry.html" \
  "$WWW_DIR/select-extension.html"
do
  [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak" || true
done

echo "✅ Backup: $BACKUP_DIR"

say "2) كتابة Session API قوي يحرر التحويلة قبل الخروج"
cat > "$API_DIR/session_api.py" <<'PY'
import frappe
from frappe.utils import now_datetime


def _has_field(doctype: str, fieldname: str) -> bool:
    try:
        return frappe.get_meta(doctype).has_field(fieldname)
    except Exception:
        return False


def _sip_doc_names(extension: str) -> list[str]:
    """Return possible SIP Extension doc names for an extension number."""
    out = []
    ext = str(extension or "").strip()
    if not ext:
        return out
    try:
        if frappe.db.exists("SIP Extension", ext):
            out.append(ext)
    except Exception:
        pass
    try:
        name = frappe.db.get_value("SIP Extension", {"extension_number": ext}, "name")
        if name and name not in out:
            out.append(name)
    except Exception:
        pass
    return out


def _free_sip_extension(extension: str, user: str | None = None) -> None:
    """Mark SIP Extension as Free, but avoid clearing another user's newly selected extension."""
    for name in _sip_doc_names(extension):
        try:
            current_user = None
            if _has_field("SIP Extension", "current_user"):
                current_user = frappe.db.get_value("SIP Extension", name, "current_user")
            # Safety: if another user already owns it, do not clear it.
            if current_user and user and current_user != user:
                continue
            values = {}
            if _has_field("SIP Extension", "status"):
                values["status"] = "Free"
            if _has_field("SIP Extension", "current_user"):
                values["current_user"] = None
            if values:
                frappe.db.set_value("SIP Extension", name, values, update_modified=True)
        except Exception:
            pass


def _release_for_user(user: str) -> dict:
    """Release all active/unreleased extension sessions for a user."""
    if not user or user == "Guest":
        return {"success": True, "message": "Guest/no user", "released": []}

    released = []
    errors = []
    now = now_datetime()

    # Use SQL because some old rows may have active=1 but session_status not exactly active.
    try:
        rows = frappe.db.sql(
            """
            SELECT name, extension
            FROM `tabExtension Session`
            WHERE user=%s
              AND (
                    IFNULL(session_status, '')='active'
                    OR IFNULL(active, 0)=1
                    OR released_at IS NULL
                  )
            ORDER BY creation DESC
            LIMIT 100
            """,
            (user,),
            as_dict=True,
        )
    except Exception:
        rows = frappe.get_all(
            "Extension Session",
            filters={"user": user, "session_status": "active"},
            fields=["name", "extension"],
            limit_page_length=100,
        )

    for row in rows:
        try:
            values = {}
            if _has_field("Extension Session", "session_status"):
                values["session_status"] = "released"
            if _has_field("Extension Session", "active"):
                values["active"] = 0
            if _has_field("Extension Session", "released_at"):
                values["released_at"] = now
            if values:
                frappe.db.set_value("Extension Session", row.name, values, update_modified=True)
            _free_sip_extension(row.extension, user=user)
            released.append(str(row.extension))
        except Exception as e:
            errors.append({"session": row.get("name"), "extension": row.get("extension"), "error": str(e)})

    frappe.db.commit()
    return {"success": len(errors) == 0, "user": user, "released": released, "errors": errors}


@frappe.whitelist(allow_guest=False)
def release_my_extension_only() -> dict:
    try:
        return _release_for_user(frappe.session.user)
    except Exception as e:
        frappe.db.rollback()
        return {"success": False, "message": str(e), "released": []}


@frappe.whitelist(allow_guest=False)
def release_extension_and_logout() -> dict:
    """Atomic browser logout endpoint: release SIP first, then logout Frappe session."""
    user = frappe.session.user
    result = {"success": True, "user": user, "release": {}}
    try:
        result["release"] = _release_for_user(user)
    except Exception as e:
        result["release"] = {"success": False, "message": str(e), "released": []}
    try:
        if hasattr(frappe.local, "login_manager") and frappe.local.login_manager:
            frappe.local.login_manager.logout()
        elif hasattr(frappe.local, "session_obj") and frappe.local.session_obj:
            frappe.local.session_obj.logout()
    except Exception as e:
        result["logout_error"] = str(e)
    return result


@frappe.whitelist(allow_guest=False)
def debug_my_extension_sessions() -> dict:
    """Small helper for testing the current logged-in user's SIP state."""
    user = frappe.session.user
    rows = frappe.db.sql(
        """
        SELECT name, user, extension, session_status, active, started_at, released_at, modified
        FROM `tabExtension Session`
        WHERE user=%s
        ORDER BY creation DESC
        LIMIT 10
        """,
        (user,),
        as_dict=True,
    )
    return {"success": True, "user": user, "rows": rows}
PY

say "3) إضافة Logout Hook احتياطي لأي خروج من Frappe"
cat > "$API_DIR/session_events.py" <<'PY'
import frappe


def on_logout(login_manager=None):
    """Frappe hook: release SIP extension whenever a logged-in user logs out."""
    try:
        user = None
        if login_manager is not None:
            user = getattr(login_manager, "user", None)
        user = user or getattr(frappe.session, "user", None)
        if user and user != "Guest":
            from restaurant_ops.api.session_api import _release_for_user
            _release_for_user(user)
    except Exception:
        try:
            frappe.db.rollback()
        except Exception:
            pass
PY

python3 - <<'PY'
from pathlib import Path
hooks = Path('/opt/frappe_crm/apps/restaurant_ops/restaurant_ops/hooks.py')
s = hooks.read_text() if hooks.exists() else ''
line = 'on_logout = "restaurant_ops.api.session_events.on_logout"'
if 'restaurant_ops.api.session_events.on_logout' not in s:
    s = s.rstrip() + '\n\n# ROSHDY: release agent SIP extension on any Frappe logout\n' + line + '\n'
    hooks.write_text(s)
    print('✅ hooks.py patched with on_logout')
else:
    print('ℹ️ hooks.py already has logout hook')
PY

say "4) إعادة كتابة صفحة /roshdy-logout: تحرير التحويلة ثم خروج"
cat > "$WWW_DIR/roshdy-logout.py" <<'PY'
import frappe
from restaurant_ops.api.session_api import _release_for_user

no_cache = 1

def get_context(context):
    context.no_cache = 1
    # First safety net: page render itself releases extension before JS logout.
    try:
        _release_for_user(frappe.session.user)
    except Exception:
        pass
    return context
PY

cat > "$WWW_DIR/roshdy-logout.html" <<'HTML'
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>تسجيل الخروج</title>
  <style>
    *{box-sizing:border-box;font-family:'Segoe UI',Tahoma,Arial}
    body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#eef2f7;color:#222;direction:rtl}
    .box{background:#fff;border:1px solid #dbe3ea;border-radius:18px;box-shadow:0 10px 30px #0001;padding:35px;max-width:520px;width:92%;text-align:center}
    .spin{width:44px;height:44px;border:5px solid #e5e7eb;border-top-color:#1F4E79;border-radius:50%;margin:0 auto 18px;animation:r 1s linear infinite}@keyframes r{to{transform:rotate(360deg)}}
    h2{color:#1F4E79;margin:0 0 12px}.muted{color:#667085}.ok{color:#16a34a;font-weight:700}.bad{color:#dc2626;font-weight:700}
  </style>
</head>
<body>
  <div class="box">
    <div class="spin"></div>
    <h2>جاري تحرير التحويلة وتسجيل الخروج...</h2>
    <p id="msg" class="muted">من فضلك انتظر ثواني.</p>
  </div>
<script>
(function(){
function M(parts){return parts.join('')}
async function call(method){
  try{
    var r = await fetch('/api/method/' + method, {method:'GET', credentials:'same-origin', cache:'no-store'});
    try{return await r.json()}catch(e){return {}}
  }catch(e){return {error:String(e)}}
}
async function run(){
  var msg=document.getElementById('msg');
  var releaseOnly = M(['restaurant','_ops.api.session','_api.release_my_extension_only']);
  var releaseAndLogout = M(['restaurant','_ops.api.session','_api.release_extension_and_logout']);

  // release twice intentionally: first explicit release, second endpoint releases+logs out.
  try{
    msg.textContent='جاري تحرير التحويلة من السيستم...';
    await call(releaseOnly);
  }catch(e){}

  try{
    msg.textContent='تم تحرير التحويلة، جاري إنهاء الجلسة...';
    await call(releaseAndLogout);
  }catch(e){}

  try{
    await fetch('/api/method/logout', {method:'GET', credentials:'same-origin', cache:'no-store'});
  }catch(e){}

  msg.className='ok';
  msg.textContent='تم تسجيل الخروج. عند الدخول مرة أخرى لازم تختار تحويلة من جديد.';
  setTimeout(function(){ location.replace('/login'); }, 500);
}
run();
setTimeout(function(){ location.replace('/login'); }, 5000);
})();
</script>
</body>
</html>
HTML

say "5) تركيب Interceptor في صفحات الإيجنت عشان أي زر خروج يحرر SIP الأول"
python3 - <<'PY'
from pathlib import Path
import re
root = Path('/opt/frappe_crm/apps/restaurant_ops/restaurant_ops/www')
pages = ['agent-desk.html', 'my-break.html', 'sales-entry.html', 'select-extension.html']

script = r'''
<script id="roshdy-safe-logout-script">
(function(){
if(window.__roshdySafeLogoutInstalled) return; window.__roshdySafeLogoutInstalled=true;
function M(parts){return parts.join('')}
window.roshdySafeLogout = async function(){
  try{
    await fetch('/api/method/'+M(['restaurant','_ops.api.session','_api.release_my_extension_only']), {method:'GET',credentials:'same-origin',cache:'no-store'});
  }catch(e){}
  try{
    await fetch('/api/method/'+M(['restaurant','_ops.api.session','_api.release_extension_and_logout']), {method:'GET',credentials:'same-origin',cache:'no-store'});
  }catch(e){}
  try{ await fetch('/api/method/logout', {method:'GET',credentials:'same-origin',cache:'no-store'}); }catch(e){}
  location.replace('/login');
};
document.addEventListener('click', function(ev){
  var el = ev.target && ev.target.closest ? ev.target.closest('a,button') : null;
  if(!el) return;
  var href = el.getAttribute('href') || '';
  var onclick = el.getAttribute('onclick') || '';
  var txt = (el.textContent || '').replace(/\s+/g,' ').trim();
  var isLogout = href.indexOf('/roshdy-logout')>=0 || href.indexOf('/api/method/logout')>=0 || onclick.indexOf('/api/method/logout')>=0 || txt==='خروج' || txt.indexOf('تسجيل خروج')>=0;
  if(isLogout){ ev.preventDefault(); ev.stopPropagation(); window.roshdySafeLogout(); }
}, true);
})();
</script>
'''

for name in pages:
    p = root / name
    if not p.exists():
        print('⚠️ missing', name)
        continue
    s = p.read_text()
    # remove old copy
    s = re.sub(r'<script\s+id=["\']roshdy-safe-logout-script["\'][\s\S]*?</script>\s*', '', s, flags=re.I)
    # normalize obvious logout hrefs to our page too
    s = s.replace("href=\"/api/method/logout\"", "href=\"/roshdy-logout\"")
    s = s.replace("href='/api/method/logout'", "href='/roshdy-logout'")
    if '</body>' in s:
        s = s.replace('</body>', script + '\n</body>', 1)
    else:
        s += '\n' + script
    p.write_text(s)
    print('✅ patched', name)
PY

say "6) مسح cache/restart للخدمات فقط"
docker exec "$BACKEND" bash -lc "find /home/frappe/frappe-bench/apps/restaurant_ops -name '*.pyc' -delete; find /home/frappe/frappe-bench/apps/restaurant_ops -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true"
docker exec "$BACKEND" bench --site "$SITE" clear-cache || true
docker exec "$BACKEND" bench --site "$SITE" clear-website-cache || true
docker compose restart backend frontend websocket queue-short queue-long scheduler

say "7) Validation: import/API/pages/current active sessions"
BACKEND="$(docker compose ps -q backend)"
sleep 8

echo "--- Import test / release for fake user, should return success with no released ---"
docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.session_api._release_for_user --args '["__no_such_user__"]' || true

echo "--- Current active Extension Sessions (for visibility only) ---"
docker exec "$BACKEND" bench --site "$SITE" execute frappe.db.sql --args '["select extension,user,session_status,active,started_at,released_at from `tabExtension Session` where session_status=\"active\" order by creation desc limit 20"]' || true

echo "--- Page HTTP status ---"
for page in roshdy-logout agent-desk my-break sales-entry select-extension; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/$page" || true)"
  echo "$page => $code"
done

say "8) Health Check مهم: Elastix/CDR/AMI + Queue + Call Report"
echo "--- Asterisk/Elastix diagnostics ---"
docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.asterisk_bridge.run_full_system_diagnostics || true

echo "--- Queue status ---"
docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.queue_api.get_queue_status || true

echo "--- Calls report admin sample ---"
docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.report_api.get_calls_report --kwargs '{"page":1,"page_size":5,"view_mode":"admin"}' || true

say "✅ Done"
echo "اختبار سريع: ادخل كإيجنت، اختار تحويلة، اضغط خروج. بعد login تاني لازم يوديك /select-extension وميرجعش لنفس التحويلة تلقائي."
echo "Backup: $BACKUP_DIR"
