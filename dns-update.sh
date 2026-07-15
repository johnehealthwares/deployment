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

SUBDOMAINS=$(echo "$ENV_BLOCK" | awk '
  /subdomains:/ {found=1; next}
  found && /^    - / {sub(/^    - /,""); print}
  found && /^  [a-z]/ && !/subdomains/ {exit}
')

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

# ── Update DDNS ──────────────────────────────────────────────
if [ "$SKIP_DNS" = false ] && [ -n "$DDNS_HASH" ]; then
  for host in $SUBDOMAINS; do
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

  # Check which containers are running on the server (to avoid direct proxy_pass failures)
  RUNNING_CONTAINERS=""
  if ! $DRY_RUN; then
    RUNNING_CONTAINERS=$(ssh -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
      -i "$SSH_KEY" ubuntu@"$IP" "sudo docker ps --format '{{.Names}}' 2>/dev/null || true" 2>/dev/null || true)
  fi
  is_running() { echo "$RUNNING_CONTAINERS" | grep -qx "$1"; }

  # Template function: writes a location block if upstream is running, or a comment otherwise
  proxy_route() {
    local location="$1" upstream="$2" container="$3"
    if [ -z "$RUNNING_CONTAINERS" ] || is_running "$container"; then
      echo "    location $location { proxy_pass $upstream; include /etc/nginx/proxy_params.conf; }"
    else
      echo "    # $location → $upstream (skipped — $container not running)"
    fi
  }

  # ── Build route blocks ──────────────────────────────────────
  RXSOFT_ROUTES=$(
    proxy_route "/api/identity/"     "http://rxsoft-identity:8092/"                 "rxsoft-identity"
    proxy_route "/api/lis/"          "http://rxsoft-lis-backend:8091/"              "rxsoft-lis-backend"
    proxy_route "/api/conversation/" "http://rxsoft-conversation-engine:8090/"      "rxsoft-conversation-engine"
    proxy_route "/api/coding/"       "http://healthcare-interop:3000/"              "rxsoft-healthcare-interop"
    proxy_route "/api/healthcare-concepts/" "http://rxsoft-healthcare-concepts:3011/"  "rxsoft-healthcare-concepts"
  )
  API_ROUTES=$(
    proxy_route "/identity/"     "http://rxsoft-identity:8092/"                 "rxsoft-identity"
    proxy_route "/lis/"          "http://rxsoft-lis-backend:8091/"              "rxsoft-lis-backend"
    proxy_route "/conversation/" "http://rxsoft-conversation-engine:8090/"      "rxsoft-conversation-engine"
    proxy_route "/coding/"       "http://healthcare-interop:3000/"              "rxsoft-healthcare-interop"
    proxy_route "/healthcare-concepts/" "http://rxsoft-healthcare-concepts:3011/"  "rxsoft-healthcare-concepts"
  )

  ANY_RUNNING=$(echo "$RUNNING_CONTAINERS" | grep -c . || true)
  if [ "$ANY_RUNNING" -eq 0 ] && [ "$DRY_RUN" = false ]; then
    # If we couldn't check, assume worst-case: only rxsoft-backend and rxsoft-admin are running
    RXSOFT_ROUTES=""
    API_ROUTES=""
  fi

  # ── Generate rxsoft.conf (admin SPA subdomains) ─────────────
  cat > /tmp/rxsoft.conf <<NGINX
server {
    listen 80;
    server_name rxsoft.$DOMAIN damorex.$DOMAIN apm.$DOMAIN;
    root /usr/share/nginx/html;
    index index.html;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_comp_level 6;

${RXSOFT_ROUTES}
    location /api/ { proxy_pass http://rxsoft-backend:8080/api/; include /etc/nginx/proxy_params.conf; }

    location / { try_files \$uri \$uri/ /index.html; }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ { expires 1y; add_header Cache-Control "public, immutable"; }
}
NGINX

  # ── Generate api.conf (api.ehealthwares.com) ────────────────
  cat > /tmp/api.conf <<NGINX
server {
    listen 80;
    server_name api.$DOMAIN;
    gzip on;
    gzip_types application/json;
    gzip_comp_level 6;

${API_ROUTES}
    location / { proxy_pass http://rxsoft-backend:8080/api/; include /etc/nginx/proxy_params.conf; }
}
NGINX

  # ── Generate www.conf (www.ehealthwares.com / root) ─────────
  # Only include if rxsoft-ehealthwares is running (or can't check)
  if [ -z "$RUNNING_CONTAINERS" ] || is_running "rxsoft-ehealthwares"; then
    cat > /tmp/www.conf <<NGINX
server {
    listen 80;
    server_name www.$DOMAIN $DOMAIN;

    location / {
        proxy_pass http://rxsoft-ehealthwares:3000;
        include /etc/nginx/proxy_params.conf;
    }
}
NGINX
  else
    echo "# rxsoft-ehealthwares not running — skipping www.conf" > /tmp/www.conf
  fi

  # ── Generate websocket.conf (conversation.ehealthwares.com) ─
  if [ -z "$RUNNING_CONTAINERS" ] || is_running "rxsoft-conversation-engine"; then
    cat > /tmp/websocket.conf <<NGINX
server {
    listen 80;
    server_name conversation.$DOMAIN;

    location / {
        proxy_pass http://rxsoft-conversation-engine:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        include /etc/nginx/proxy_params.conf;
    }
}
NGINX
  else
    echo "# rxsoft-conversation-engine not running — skipping websocket.conf" > /tmp/websocket.conf
  fi

  ok "Nginx config generated"
  echo ""
  echo "--- rxsoft.conf ---"
  cat /tmp/rxsoft.conf
  echo ""
  echo "--- api.conf ---"
  cat /tmp/api.conf
  echo ""
  echo "--- www.conf ---"
  cat /tmp/www.conf
  echo ""
  echo "--- websocket.conf ---"
  cat /tmp/websocket.conf
  echo ""

  if $DRY_RUN; then
    info "[DRY-RUN] Would deploy to server and reload nginx"
  else
    info "Deploying nginx config to server..."
    ssh -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY" ubuntu@"$IP" "mkdir -p /home/ubuntu/develop/docker/nginx" 2>/dev/null || true
    scp -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY" docker/nginx/proxy_params.conf /tmp/rxsoft.conf /tmp/api.conf /tmp/www.conf /tmp/websocket.conf \
        ubuntu@"$IP":/home/ubuntu/develop/docker/nginx/
    ssh -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY" ubuntu@"$IP" \
         "sudo docker cp /home/ubuntu/develop/docker/nginx/rxsoft.conf rxsoft-admin:/etc/nginx/conf.d/ && \
         sudo docker cp /home/ubuntu/develop/docker/nginx/api.conf rxsoft-admin:/etc/nginx/conf.d/ && \
         sudo docker cp /home/ubuntu/develop/docker/nginx/www.conf rxsoft-admin:/etc/nginx/conf.d/ && \
         sudo docker cp /home/ubuntu/develop/docker/nginx/websocket.conf rxsoft-admin:/etc/nginx/conf.d/ && \
         if sudo docker exec rxsoft-admin nginx -t 2>&1; then \
           sudo docker exec rxsoft-admin nginx -s reload && echo 'Nginx reloaded'; \
         else \
           echo 'Nginx config error — fix and retry'; exit 1; \
         fi" 2>&1
    ok "Nginx config deployed"
  fi
fi

# ── Verification ─────────────────────────────────────────────
echo ""
echo "=== Verification ==="
for name in rxsoft api www conversation; do
  C=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://$IP/" 2>/dev/null || echo "fail")
  ok "${name}.${DOMAIN} → (${C})"
done
C=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://$IP/api/website/homepage" 2>/dev/null || echo "fail")
ok "Internal /api/website/homepage → ${C}"

echo ""
echo "Done. Wait for DNS propagation (TTL=60), then verify:"
echo "  curl http://rxsoft.${DOMAIN}"
echo "  curl http://api.${DOMAIN}/website/homepage"
echo "  curl http://damorex.${DOMAIN}"
echo "  curl http://apm.${DOMAIN}"
echo "  curl http://www.${DOMAIN}"
echo "  curl http://${DOMAIN}"
echo "  curl http://conversation.${DOMAIN}"
