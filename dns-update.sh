#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# RxSoft DNS + Nginx Updater
# Updates Namecheap DDNS records and deploys nginx config
# after terraform creates/replaces the EC2 instance.
#
# Usage:
#   ./dns-update.sh                          # default: --env prod
#   ./dns-update.sh --env prod               # production
#   ./dns-update.sh --env prod --dry-run     # preview only
#   ./dns-update.sh --env prod --skip-dns    # nginx config only
#   ./dns-update.sh --help                   # this message
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

# ── Parse args ──────────────────────────────────────────────
ENV="prod"
DRY_RUN=false
SKIP_DNS=false
SKIP_NGINX=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)       ENV="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --skip-dns)  SKIP_DNS=true; shift ;;
    --skip-nginx) SKIP_NGINX=true; shift ;;
    --help)      sed -n '3,16p' "$0"; exit 0 ;;
    *)           echo "Unknown: $1"; exit 1 ;;
  esac
done

SSH_KEY="terraform/ssh/id_rsa"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${YELLOW}ℹ${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }

# ── Load config ──────────────────────────────────────────────
[ ! -f dns-config.yml ] && fail "dns-config.yml not found"

DOMAIN=$(grep -E "^domain:" dns-config.yml | head -1 | sed 's/.*: //' | tr -d '"')
DDNS_URL=$(grep -E "^ddns_url:" dns-config.yml | head -1 | sed 's/.*: //' | tr -d '"')

ENV_BLOCK=$(awk -v env="$ENV" '
  $0 ~ "^  "env":" {found=1; next}
  found && /^  [a-z]/ && !/^  '"$ENV"':/ {exit}
  found {print}
' dns-config.yml)

IP_SOURCE=$(echo "$ENV_BLOCK" | grep -E "ip_source:" | sed 's/.*: //' | tr -d '" ')

FRONTEND_NAMES=$(echo "$ENV_BLOCK" | awk '/frontend:/{f=1;next} f && /server_names:/{gsub(/[\[\],]/,""); for(i=2;i<=NF;i++) print $i; exit}')
API_NAMES=$(echo "$ENV_BLOCK" | awk '/api:/{f=1;next} f && /server_names:/{gsub(/[\[\],]/,""); for(i=2;i<=NF;i++) print $i; exit}')

# ── DDNS hash ────────────────────────────────────────────────
DDNS_HASH=""
[ -f .env.ddns ] && source .env.ddns
[ -z "${DDNS_HASH:-}" ] && info "DDNS_HASH not set — DNS updates skipped"

# ── Get IP ───────────────────────────────────────────────────
IP=""
case "$IP_SOURCE" in
  terraform)
    IP_FILE=".ec2-ip"
    if [ -f "$IP_FILE" ]; then
      IP=$(cat "$IP_FILE")
    else
      IP=$(terraform -chdir=terraform output -raw public_ip 2>/dev/null || true)
      [ -n "$IP" ] && echo "$IP" > "$IP_FILE"
    fi
    ;;
  file)     IP=$(cat ".ec2-ip" 2>/dev/null) || fail ".ec2-ip not found" ;;
  literal:*) IP="${IP_SOURCE#literal:}" ;;
esac

[ -z "$IP" ] && fail "Could not determine IP. Run terraform apply first."
ok "IP: $IP (source: $IP_SOURCE)"

# ── Verify reachable ─────────────────────────────────────────
info "Verifying instance..."
curl -sS --max-time 5 "http://$IP/" > /dev/null 2>&1 || fail "Cannot reach $IP"
ok "Instance reachable at http://$IP/"

# ── Collect unique subdomains ────────────────────────────────
SUBDOMAINS=("@")
for n in $FRONTEND_NAMES; do
  [ "$n" = "rxsoft" ] && continue
  SUBDOMAINS+=("$n")
done
for n in $API_NAMES; do
  seen=false
  for s in "${SUBDOMAINS[@]}"; do [ "$s" = "$n" ] && seen=true; done
  $seen || SUBDOMAINS+=("$n")
done

# ── Update DDNS ──────────────────────────────────────────────
if [ "$SKIP_DNS" = false ] && [ -n "$DDNS_HASH" ]; then
  for host in "${SUBDOMAINS[@]}"; do
    URL="${DDNS_URL}?host=${host}&domain=${DOMAIN}&password=${DDNS_HASH}&ip=${IP}"
    if $DRY_RUN; then
      info "[DRY-RUN] Would update: ${host}.${DOMAIN} → ${IP}"
    else
      RESP=$(curl -sS --max-time 10 "$URL" 2>&1) || true
      if echo "$RESP" | grep -q "<ErrCount>0" 2>/dev/null; then
        ok "DDNS updated: ${host}.${DOMAIN} → ${IP}"
      else
        ERR=$(echo "$RESP" | grep -o 'Err1[^<]*' | head -1 | sed 's/Err1//' | tr -d '>; ')
        info "DDNS skipped for ${host}: ${ERR:-missing A record in Namecheap panel}"
      fi
    fi
  done
else
  info "DNS updates skipped"
fi

# ── Nginx config ─────────────────────────────────────────────
if [ "$SKIP_NGINX" = false ]; then
  info "Generating nginx config..."

  FE_NAMES=""
  for n in $FRONTEND_NAMES; do FE_NAMES="${FE_NAMES}${n}.${DOMAIN} "; done
  API_SERVERS=""
  for n in $API_NAMES; do API_SERVERS="${API_SERVERS}${n}.${DOMAIN} "; done

  # Proxy routes (same for both blocks, just different paths)
  PROXY_ROUTES=$(cat <<'PROXY'
    location /api/backend/ { proxy_pass http://rxsoft-backend:8080/api/; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/identity/ { proxy_pass http://rxsoft-identity:8092/; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/lis/ { set $u_lis http://rxsoft-lis-backend:8091/; proxy_pass $u_lis; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/conversation/ { set $u_conv http://rxsoft-conversation-engine:8090/; proxy_pass $u_conv; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/communication/ { proxy_pass http://rxsoft-backend:8080/; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/coding/ { set $u_coding http://healthcare-interop:3000/; proxy_pass $u_coding; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/healthcare-concepts/ { set $u_concepts http://rxsoft-healthcare-concepts:3011/; proxy_pass $u_concepts; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
PROXY
)
  API_ROUTES=$(echo "$PROXY_ROUTES" | sed 's|/api/|/|g')

  # Write frontend config
  # NOTE: Must be marked default_server so it catches unmatched hostnames
  # when api.conf is also loaded (alphabetical order would make api.conf default)
  cat > /tmp/rxsoft.conf <<NGINX
server {
    listen 80 default_server;
    server_name ${FE_NAMES% };
    root /usr/share/nginx/html;
    index index.html;
    resolver 127.0.0.11 valid=30s;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_comp_level 6;
${PROXY_ROUTES}
    location / { try_files \$uri \$uri/ /index.html; }
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ { expires 1y; add_header Cache-Control "public, immutable"; }
}
NGINX

  # Write API config
  cat > /tmp/api.conf <<NGINX
server {
    listen 80;
    server_name ${API_SERVERS% };
    resolver 127.0.0.11 valid=30s;
    gzip on;
    gzip_types application/json;
    gzip_comp_level 6;
${API_ROUTES}
}
NGINX

  ok "Nginx config generated"
  echo ""
  echo "--- rxsoft.conf ---"
  cat /tmp/rxsoft.conf
  echo ""
  echo "--- api.conf ---"
  cat /tmp/api.conf
  echo ""

  if $DRY_RUN; then
    info "[DRY-RUN] Would deploy to server and reload nginx"
  else
    info "Deploying nginx config to server..."
    ssh -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY" ubuntu@"$IP" "mkdir -p /home/ubuntu/develop/docker/nginx" 2>/dev/null || true
    scp -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY" /tmp/rxsoft.conf /tmp/api.conf ubuntu@"$IP":/home/ubuntu/develop/docker/nginx/
    ssh -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY" ubuntu@"$IP" \
        "sudo docker cp /home/ubuntu/develop/docker/nginx/rxsoft.conf rxsoft-admin:/etc/nginx/conf.d/ && \
         sudo docker cp /home/ubuntu/develop/docker/nginx/api.conf rxsoft-admin:/etc/nginx/conf.d/ && \
         sudo docker exec rxsoft-admin nginx -s reload" 2>&1
    ok "Nginx config deployed and reloaded"
  fi
fi

# ── Verification ─────────────────────────────────────────────
echo ""
echo "=== Verification ==="
for n in $FRONTEND_NAMES; do
  C=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://$IP/" 2>/dev/null || echo "fail")
  ok "${n}.${DOMAIN} → frontend (${C})"
done
for n in $API_NAMES; do
  C=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://$IP/" 2>/dev/null || echo "fail")
  ok "${n}.${DOMAIN} → API gateway (${C})"
done

C=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://$IP/api/backend/website/homepage" 2>/dev/null || echo "fail")
ok "Internal /api/backend/website/homepage → ${C}"

echo ""
echo "Done. Wait for DNS propagation (TTL=60), then verify:"
echo "  curl http://rxsoft.${DOMAIN}"
echo "  curl http://api.${DOMAIN}/backend/website/homepage"
echo "  curl http://damorex.${DOMAIN}"
echo "  curl http://apm.${DOMAIN}"
echo "  curl http://conversation.${DOMAIN}"
