#!/usr/bin/env bash
set -Eeuo pipefail

# check_static_ip_erp.sh
# Safe diagnostics only: checks ERP local service, Docker, host IP, public host_name, and Elastix health.
# Does NOT change anything.

ROOT="/opt/frappe_crm"
SITE="crm.local"
EXPECTED_LAN_IP="10.11.1.66"
EXPECTED_PUBLIC_URL="http://196.219.158.18"

say(){ echo -e "\n============================================================\n$1\n============================================================"; }
run(){ echo -e "\n--- $* ---"; "$@" || true; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "❌ Run as root: sudo -i ثم ./check_static_ip_erp.sh"
  exit 1
fi

say "1) Server network identity"
run hostname -I
run ip -br addr
run ip route

echo "Expected LAN IP: $EXPECTED_LAN_IP"
if hostname -I | tr ' ' '\n' | grep -qx "$EXPECTED_LAN_IP"; then
  echo "✅ Server still has expected LAN IP $EXPECTED_LAN_IP"
else
  echo "❌ Server does NOT show expected LAN IP $EXPECTED_LAN_IP"
fi

say "2) Docker / ERP status"
if [[ ! -d "$ROOT" ]]; then
  echo "❌ $ROOT not found"
  exit 0
fi
cd "$ROOT"
run docker compose ps
BACKEND="$(docker compose ps -q backend || true)"
FRONTEND="$(docker compose ps -q frontend || true)"
echo "BACKEND=$BACKEND"
echo "FRONTEND=$FRONTEND"

say "3) Port 80 listener"
run ss -ltnp
if ss -ltnp | grep -q ':80 '; then
  echo "✅ Something is listening on port 80"
else
  echo "❌ Nothing is listening on port 80"
fi

say "4) Local HTTP tests"
run curl -I --max-time 8 http://127.0.0.1/login
run curl -I --max-time 8 http://127.0.0.1/
run curl -I --max-time 8 "http://$EXPECTED_LAN_IP/login"

say "5) Site config host_name"
if [[ -n "$BACKEND" ]]; then
  run docker exec "$BACKEND" bash -lc "cat /home/frappe/frappe-bench/sites/$SITE/site_config.json | grep -E '\"host_name\"|\"db_name\"|\"developer_mode\"' || true"
  echo "Expected public host_name normally: $EXPECTED_PUBLIC_URL"
fi

say "6) Basic app pages from localhost"
for page in login admin-desk agent-desk quality-desk call-report social-inbox social-settings; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1/$page" || true)"
  echo "$page => $code"
done

say "7) Firewall on Ubuntu if any"
run ufw status verbose
run iptables -S

say "8) Elastix/CDR/AMI health check - to prove PBX link is not the issue"
if [[ -n "$BACKEND" ]]; then
  run docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.asterisk_bridge.run_full_system_diagnostics
  run docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.queue_api.get_queue_status
  run docker exec "$BACKEND" bench --site "$SITE" execute restaurant_ops.api.report_api.get_calls_report --kwargs '{"page":1,"page_size":3,"view_mode":"admin"}'
fi

say "✅ Done"
echo "If local curl is OK but public IP is not working, the problem is FortiGate/VIP/Policy/NAT/ISP path, not ERP."
echo "If local curl fails, fix Docker/ERP/server IP first."
