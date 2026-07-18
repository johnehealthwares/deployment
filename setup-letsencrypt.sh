#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# setup-letsencrypt.sh — Get Let's Encrypt certs via manual
# DNS challenge and configure nginx for HTTPS.
#
# Uses manual DNS-01 challenge (Namecheap) — you'll add TXT
# records in the Namecheap panel when prompted.
#
# Usage:
#   ./setup-letsencrypt.sh                    # fresh setup
#   ./setup-letsencrypt.sh --force            # force re-issue
#   ./setup-letsencrypt.sh --dry-run          # preview only
#   ./setup-letsencrypt.sh --renew            # renew existing
#
# After infra destroy: re-run with no flags.
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${YELLOW}ℹ${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
step() { echo -e "\n${BLUE}═══ $1 ═══${NC}"; }

# ── Parse args ──────────────────────────────────────────────
FORCE=false
DRY_RUN=false
RENEW=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --renew)   RENEW=true; shift ;;
    --help)    sed -n '3,14p' "$0"; exit 0 ;;
    *)         echo "Unknown: $1"; exit 1 ;;
  esac
done

SSH_KEY="terraform/ssh/id_rsa"
IP=$(cat .ec2-ip 2>/dev/null || terraform -chdir=terraform output -raw public_ip 2>/dev/null)
[ -z "$IP" ] && fail "Can't determine instance IP (no .ec2-ip, terraform output failed)"
SSH_BASE="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -i $SSH_KEY ubuntu@$IP"

DOMAIN="ehealthwares.com"
EMAIL="admin@ehealthwares.com"
NGINX_DIR="/home/ubuntu/develop/docker/nginx"
COMPOSE_FILE="docker/docker-compose.prod.yml"
SSL_CONF_SRC="docker/nginx/conf.d/ssl.conf"
SSL_CONF_DEST="$NGINX_DIR/conf.d/ssl.conf"
LETSENCRYPT_DIR="/etc/letsencrypt/live/$DOMAIN"
CERT_FILE="$LETSENCRYPT_DIR/fullchain.pem"

# ── Step 1: Check if cert already exists ──────────────────
step "1/5 — Check existing certificate"
if $DRY_RUN; then
  info "[DRY-RUN] Would check for existing cert at $CERT_FILE on $IP"
elif $SSH_BASE "sudo test -f $CERT_FILE" 2>/dev/null; then
  EXISTING_EXPIRY=$($SSH_BASE "sudo openssl x509 -enddate -noout -in $CERT_FILE 2>/dev/null | cut -d= -f2" 2>/dev/null || echo "unknown")
  info "Certificate exists (expires: $EXISTING_EXPIRY)"
  if [ "$FORCE" = false ] && [ "$RENEW" = false ]; then
    ok "Skipping certbot. Use --force to re-issue or --renew to renew."
    CERT_EXISTS=true
  else
    info "Forcing re-issue / renewal..."
    CERT_EXISTS=false
  fi
else
  info "No certificate found — will request new one"
  CERT_EXISTS=false
fi

# ── Step 2: Run certbot on instance ───────────────────────
step "2/5 — Obtain Let's Encrypt certificate"
CERTBOT_CMD="sudo certbot certonly --manual --preferred-challenges dns \
  -d '*.${DOMAIN}' -d '${DOMAIN}' -d 'damorex.com' \
  --agree-tos --email ${EMAIL} --no-eff-email \
  --manual-public-ip-logging-ok"

if [ "$RENEW" = true ]; then
  CERTBOT_CMD="sudo certbot renew --manual --preferred-challenges dns --no-random-sleep-on-renew"
fi

if [ "$DRY_RUN" = true ]; then
  info "[DRY-RUN] Would run on $IP:"
  echo "  ${CERTBOT_CMD}"
  info "Would then add TXT records in Namecheap panel:"
  echo "  _acme-challenge.${DOMAIN}  →  (value printed by certbot)"
  echo "  _acme-challenge.damorex.com  →  (value printed by certbot)"
elif [ "$CERT_EXISTS" = true ]; then
  ok "Certificate already valid — skipping certbot"
else
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │  Certbot will print TXT records to add in Namecheap.   │"
  echo "  │                                                         │"
  echo "  │  1. Open Namecheap → Domain List → ${DOMAIN} → Advanced DNS │"
  echo "  │  2. Add the TXT records certbot prints below            │"
  echo "  │  3. Wait 1-2 min for DNS propagation                    │"
  echo "  │  4. Press Enter to continue certbot verification        │"
  echo "  └─────────────────────────────────────────────────────────┘"
  echo ""
  read -p "  Ready? Press Enter to start certbot (or Ctrl+C to cancel)..."

  # Use ssh -t for interactive terminal
  ssh -t -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -i "$SSH_KEY" ubuntu@"$IP" "$CERTBOT_CMD" || {
    echo ""
    fail "Certbot failed. Check the output above for details."
  }
  ok "Certificate obtained successfully"
fi

if [ "$DRY_RUN" = true ]; then
  info "[DRY-RUN] Rest of setup skipped in dry-run mode"
  exit 0
fi

# ── Step 3: Verify cert exists on instance ────────────────
step "3/5 — Verify certificate files"
$SSH_BASE "sudo ls -la $LETSENCRYPT_DIR/fullchain.pem $LETSENCRYPT_DIR/privkey.pem" 2>/dev/null || \
  fail "Certificate files not found at $LETSENCRYPT_DIR"

# ── Step 4: Update docker-compose.prod.yml ───────────────
step "4/5 — Update docker-compose.prod.yml"
if grep -q '"443:443"' "$COMPOSE_FILE" 2>/dev/null; then
  ok "Port 443 already configured"
else
  sed -i '' 's/      - "80:80"/      - "80:80"\n      - "443:443"/' "$COMPOSE_FILE"
  ok "Added port 443 mapping"
fi

if grep -q '/etc/letsencrypt' "$COMPOSE_FILE" 2>/dev/null; then
  ok "Let's Encrypt volume mount already configured"
else
  sed -i '' 's|      - ./nginx/proxy_params.conf:/etc/nginx/proxy_params.conf:ro|      - ./nginx/proxy_params.conf:/etc/nginx/proxy_params.conf:ro\n      - /etc/letsencrypt:/etc/letsencrypt:ro\n      - ./nginx/conf.d/ssl.conf:/etc/nginx/conf.d/ssl.conf:ro|' "$COMPOSE_FILE"
  ok "Added Let's Encrypt and SSL config volume mounts"
fi

# ── Step 5: Deploy SSL config to instance + reload nginx ──
step "5/5 — Deploy SSL config and reload nginx"

if [ ! -f "$SSL_CONF_SRC" ]; then
  fail "SSL config not found at $SSL_CONF_SRC — create it first"
fi

echo "  Copying ssl.conf to instance..."
$SSH_BASE "sudo mkdir -p $NGINX_DIR/conf.d" 2>/dev/null
scp -q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
  -i "$SSH_KEY" "$SSL_CONF_SRC" ubuntu@"$IP":/tmp/ssl.conf
$SSH_BASE "sudo mv /tmp/ssl.conf $SSL_CONF_DEST" 2>&1
ok "SSL config copied to instance"

echo "  Copying into nginx container and reloading..."
$SSH_BASE "sudo docker cp $SSL_CONF_DEST rxsoft-admin:/etc/nginx/conf.d/ssl.conf && \
  if sudo docker exec rxsoft-admin nginx -t 2>&1; then \
    sudo docker exec rxsoft-admin nginx -s reload && echo 'Nginx reloaded'; \
  else \
    echo 'Nginx config error — fix and retry'; exit 1; \
  fi" 2>&1 || fail "Nginx config deployment failed"

# Also update the static nginx source files on the instance
$SSH_BASE "sudo cp $SSL_CONF_DEST $NGINX_DIR/conf.d/ssl.conf 2>/dev/null; sudo chown -R 1000:1000 $NGINX_DIR/conf.d/ 2>/dev/null" || true
ok "SSL config deployed to nginx source directory"

# ── Done ────────────────────────────────────────────────────
echo ""
echo "=== HTTPS setup complete ==="
echo ""
echo "  Certificate:  /etc/letsencrypt/live/$DOMAIN/"
echo "  Domains:      *.$DOMAIN, $DOMAIN, damorex.com"
echo ""
echo "  Verify now:"
echo "    curl -I https://rxsoft.$DOMAIN"
echo "    curl -I https://api.$DOMAIN"
echo "    curl -I https://www.$DOMAIN"
echo "    curl -I https://conversation.$DOMAIN"
echo "      (may fail — DNS needs CNAME/A records to $IP)"
echo ""
echo "  Renewal (every 60-90 days):"
echo "    ./setup-letsencrypt.sh --renew"
echo "    → Add TXT records in Namecheap when prompted"
echo ""
echo "  After infra destroy:"
echo "    provision-and-deploy.sh"
echo "    ./setup-letsencrypt.sh"
echo "    → Same manual DNS process"
echo ""
