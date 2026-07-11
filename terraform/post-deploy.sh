#!/bin/bash
#──────────────────────────────────────────────────────────────
# Post-deploy fix script — run AFTER cloud-init completes.
# Fixes known issues with GitHub repo files vs local fixes.
#──────────────────────────────────────────────────────────────
set -euo pipefail

cd /home/ubuntu/develop/docker

echo "=== 1. Fix compose file (duplicate VITE_* vars) ==="
# The GitHub compose has VITE_* already; cloud-init sed adds dups
DCF=/home/ubuntu/develop/docker/docker-compose.prod.yml
# Find and remove duplicate VITE_* lines after the first block
DUPLICATE_LINES=$(grep -n "VITE_" "$DCF" | cut -d: -f1 | tail -n +7)
if [ -n "$DUPLICATE_LINES" ]; then
  # Delete duplicate lines from last occurrence backwards
  echo "$DUPLICATE_LINES" | sort -rn | while read line; do
    sed -i "${line}d" "$DCF"
  done
  echo "  Removed duplicate VITE_* lines"
fi

echo "=== 2. Fix sed formatting (remove trailing '}' that broke compose) ==="
# The sed patch for admin env vars leaves a trailing '}'
sed -i '/^}$/d' "$DCF"

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

echo "=== 7. Start databases ==="
docker compose -f "$DCF" --env-file .env.memory --profile postgres --profile mongodb up -d
echo "  Waiting for databases..."
sleep 15

echo "=== 8. Build and start backend (pre-built dist) ==="
docker compose -f "$DCF" --env-file .env.memory up -d --no-deps rxsoft-backend
sleep 10

echo "=== 9. Build and start identity (pre-built dist) ==="
docker compose -f "$DCF" --env-file .env.memory up -d --no-deps rxsoft-identity
sleep 10

echo "=== 10. Build and start admin ==="
docker compose -f "$DCF" --env-file .env.memory up -d --no-deps rxsoft-admin
sleep 10

echo "=== 11. Start mongo-init ==="
docker compose -f "$DCF" --env-file .env.memory up -d --no-deps mongo-init
sleep 5

echo "=== 12. Patch admin JS files ==="
docker exec rxsoft-admin sh -c '
  sed -i "s|https://rxsoft-backend.onrender.com/api|/api/backend|g" /usr/share/nginx/html/assets/*.js
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
