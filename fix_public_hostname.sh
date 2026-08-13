#!/usr/bin/env bash
set -Eeuo pipefail

# fix_public_hostname.sh
# Fixes Frappe host_name without typing a clickable/markdown URL.
# Does not touch FortiGate/Elastix/CDR.

ROOT="/opt/frappe_crm"
SITE="crm.local"

say(){ echo -e "\n============================================================\n$1\n============================================================"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: sudo -i ثم ./fix_public_hostname.sh"
  exit 1
fi

say "1) Build clean public URL without markdown"
HOST_URL="$(printf 'http://%s.%s.%s.%s' 196 219 158 18)"
echo "HOST_URL=$HOST_URL"

say "2) Set Frappe host_name cleanly"
cd "$ROOT"
BACKEND="$(docker compose ps -q backend)"
if [[ -z "$BACKEND" ]]; then
  echo "backend container not found"
  exit 1
fi

docker exec "$BACKEND" bench --site "$SITE" set-config host_name "$HOST_URL"

# Force clean JSON in case it was previously stored as a markdown link.
docker exec "$BACKEND" python3 - <<'PY'
import json
from pathlib import Path
p = Path('/home/frappe/frappe-bench/sites/crm.local/site_config.json')
data = json.loads(p.read_text())
data['host_name'] = 'http://' + '.'.join(['196','219','158','18'])
p.write_text(json.dumps(data, indent=1, ensure_ascii=False) + '\n')
print('host_name forced:', data['host_name'])
PY

say "3) Clear cache and restart web services"
docker exec "$BACKEND" bench --site "$SITE" clear-cache || true
docker exec "$BACKEND" bench --site "$SITE" clear-website-cache || true
docker compose restart backend frontend websocket
sleep 8
BACKEND="$(docker compose ps -q backend)"

say "4) Verify site_config"
docker exec "$BACKEND" python3 - <<'PY'
import json
from pathlib import Path
p = Path('/home/frappe/frappe-bench/sites/crm.local/site_config.json')
data = json.loads(p.read_text())
print('host_name =', data.get('host_name'))
assert data.get('host_name') == 'http://' + '.'.join(['196','219','158','18'])
PY

say "5) Local HTTP checks"
curl -I --max-time 8 http://127.0.0.1/login || true
curl -I --max-time 8 -H "Host: 196.219.158.18" http://127.0.0.1/login || true

say "Done"
echo "Now test from 4G/mobile data: http://196.219.158.18/login"
