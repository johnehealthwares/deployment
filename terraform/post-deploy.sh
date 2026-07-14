#!/bin/bash
#──────────────────────────────────────────────────────────────
# Post-deploy fix script — run AFTER cloud-init completes.
# Fixes known issues with GitHub repo files vs local fixes.
#──────────────────────────────────────────────────────────────
set -euo pipefail

cd /home/ubuntu/develop/docker

echo "=== 1. Check compose file valid ==="
DCF=/home/ubuntu/develop/docker/docker-compose.prod.yml
docker compose -f "$DCF" config --services > /dev/null 2>&1 || {
  echo "  WARNING: Compose file invalid — checking for known issues..."
  # Check for duplicate VITE_* keys (from old cloud-init sed patch)
  grep -n "VITE_" "$DCF" | cut -d: -f1 | sort | uniq -d | while read line; do
    echo "  Duplicate VITE_* at line $line — removing"
    sed -i "${line}d" "$DCF"
  done
}

echo "=== 3. Create missing nest-cli.json files ==="
for repo in healthcare-interoperability-switch common-admin; do
  if [ ! -f "/home/ubuntu/develop/$repo/nest-cli.json" ]; then
    cat > "/home/ubuntu/develop/$repo/nest-cli.json" << "EOF"
{
  "$schema": "https://json.schemastore.org/nest-cli",
  "collection": "@nestjs/schematics",
  "sourceRoot": "src",
  "compilerOptions": { "deleteOutDir": true }
}
EOF
    echo "  Created nest-cli.json for $repo"
  fi
done

echo "=== 4. Fix MongoDB keyfile ==="
mkdir -p /home/ubuntu/develop/docker/mongodb
if [ -f /home/ubuntu/develop/docker/mongodb/mongo-keyfile ]; then
  chown 999:999 /home/ubuntu/develop/docker/mongodb/mongo-keyfile 2>/dev/null || true
  chmod 400 /home/ubuntu/develop/docker/mongodb/mongo-keyfile
else
  openssl rand -base64 756 | tr -d \\n > /home/ubuntu/develop/docker/mongodb/mongo-keyfile
  chown 999:999 /home/ubuntu/develop/docker/mongodb/mongo-keyfile
  chmod 400 /home/ubuntu/develop/docker/mongodb/mongo-keyfile
fi
echo "  MongoDB keyfile fixed"

echo "=== 5. Add swap if missing ==="
if ! grep -q swapfile /etc/fstab 2>/dev/null; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "  2GB swap added"
fi

echo "=== 6. Copy nginx config to build context ==="
cp nginx-default.conf /home/ubuntu/develop/common-admin/ 2>/dev/null || true

echo "=== 6b. Create proxy_params.conf for volume mount ==="
mkdir -p /home/ubuntu/develop/docker/nginx
cat > /home/ubuntu/develop/docker/nginx/proxy_params.conf <<'PROXY'
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_connect_timeout 60s;
proxy_read_timeout 60s;
proxy_send_timeout 60s;
client_max_body_size 50m;
PROXY

echo "=== 7. Start databases ==="
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
export AWS_ACCOUNT_ID AWS_REGION

docker compose -f "$DCF" --env-file .env.memory --profile postgres --profile mongodb up -d
echo "  Waiting for databases..."
sleep 15

echo "=== 8. Pull and start remaining services ==="
for service in rxsoft-backend rxsoft-identity rxsoft-admin ehealthwares; do
  echo "  Pulling $service..."
  docker compose -f "$DCF" --env-file .env.memory pull "$service" 2>&1 | tail -1
  docker compose -f "$DCF" --env-file .env.memory up -d --no-build --no-deps "$service"
  sleep 10
done

echo "=== 12. Start mongo-init ==="
docker compose -f "$DCF" --env-file .env.memory up -d --no-deps mongo-init
sleep 5

echo "=== 13. Patch admin JS files ==="
docker exec rxsoft-admin sh -c '
  sed -i "s|https://rxsoft-backend.onrender.com/api|/api|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:3011/api/v1|/api/healthcare-concepts/api/v1|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:8091|/api/lis|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:3000/api/v1|/api/coding/api/v1|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:8080/api|/api/conversation|g" /usr/share/nginx/html/assets/*.js
' 2>/dev/null
echo "  Admin JS patched"

echo ""
echo "============================================"
echo "Post-deploy fixes complete!"
echo "============================================"
docker ps --format "table {{.Names}}\t{{.Status}}"
