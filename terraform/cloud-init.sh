#!/bin/bash
set -e

exec > >(tee /var/log/cloud-init.log) 2>&1

echo "=== System update ==="
apt update -qq
DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq
apt install -y -qq docker.io docker-compose-v2 git curl
snap install aws-cli --classic 2>/dev/null

echo "=== Swap ==="
if ! grep -q swapfile /etc/fstab 2>/dev/null; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "=== Start Docker ==="
systemctl enable docker
systemctl start docker
for i in $(seq 1 10); do docker info >/dev/null 2>&1 && break; echo "Waiting for Docker... ($i)"; sleep 2; done

echo "=== Clone repos ==="
mkdir -p /home/ubuntu/develop
cd /home/ubuntu/develop
for repo in rxsoft-backend rxsoft-lis-backend common-admin common-healthcare-resources healthcare-interoperability-switch conversation-engine identity; do
  rm -rf "$repo"
  git clone --depth 1 "https://github.com/johnehealthwares/${repo}.git"
done
chown -R ubuntu:ubuntu /home/ubuntu/develop

echo "=== Clone deployment repo ==="
rm -rf /home/ubuntu/develop/docker
git clone --depth 1 https://github.com/johnehealthwares/docker.git /home/ubuntu/develop/docker
chown -R ubuntu:ubuntu /home/ubuntu/develop/docker

echo "=== Write backup config ==="
cat <<'ENVEOF' > /home/ubuntu/develop/docker/.env.backup
__BACKUP_ENV__
ENVEOF

echo "=== Memory limits ==="
declare -A SERVICE_MEMORY
while IFS='=' read -r key value; do
  SERVICE_MEMORY[$key]=$value
done < <(cat <<'MAPEOF'
__SERVICE_MEMORY__
MAPEOF
)
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "# Auto-generated" > /home/ubuntu/develop/docker/.env.memory
for svc in "${!SERVICE_MEMORY[@]}"; do
  pct=${SERVICE_MEMORY[$svc]}
  if [ "$pct" -gt 0 ] 2>/dev/null; then
    var="MEM_$(echo "$svc" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
    echo "${var}=$(( TOTAL_MEM_MB * pct / 100 ))m" >> /home/ubuntu/develop/docker/.env.memory
  fi
done

echo "=== Create init scripts ==="
mkdir -p /home/ubuntu/develop/docker/postgres-init
cat > /home/ubuntu/develop/docker/postgres-init/01-create-dbs.sh <<'SCRIPT'
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
  CREATE DATABASE rxsoft;
  CREATE DATABASE lis;
  CREATE DATABASE identity;
EOSQL
SCRIPT
chmod +x /home/ubuntu/develop/docker/postgres-init/01-create-dbs.sh

mkdir -p /home/ubuntu/develop/docker/mongo-init
cat > /home/ubuntu/develop/docker/mongo-init/init.sh <<'SCRIPT'
#!/bin/bash
set -e
echo "Waiting for MongoDB..."
for i in $(seq 1 30); do
  if mongosh --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then echo "MongoDB ready"; break; fi
  echo "Waiting... ($i)"; sleep 2
done
mongosh --quiet --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"localhost:27017"}]})' 2>/dev/null || true
mongosh admin --quiet --eval 'if(!db.getUser("admin")){db.createUser({user:"admin",pwd:"admin123",roles:[{role:"root",db:"admin"}]})}' 2>/dev/null || true
echo "MongoDB init done"
SCRIPT
chmod +x /home/ubuntu/develop/docker/mongo-init/init.sh

echo "=== MongoDB keyfile ==="
mkdir -p /home/ubuntu/develop/docker/mongodb
openssl rand -base64 756 | tr -d \\n > /home/ubuntu/develop/docker/mongodb/mongo-keyfile
chown 999:999 /home/ubuntu/develop/docker/mongodb/mongo-keyfile
chmod 400 /home/ubuntu/develop/docker/mongodb/mongo-keyfile

echo "=== Patch docker-compose.prod.yml ==="
DCF=/home/ubuntu/develop/docker/docker-compose.prod.yml
# Add postgres-init volume mount
sed -i '/postgres_data:\/var\/lib\/postgresql\/data/a\      - .\/postgres-init:\/docker-entrypoint-initdb.d' "$DCF"
# Fix backend/identity healthcheck (wget --spider is fragile)
sed -i 's|test: \["CMD", "wget", "--spider", "-q", "http://localhost:8080/"\]|test: ["CMD", "node", "-e", "require('\''http'\'').get('\''http://localhost:8080/'\'',r=>process.exit(0)).on('\''error'\'',e=>process.exit(1))"]|' "$DCF"
sed -i 's|test: \["CMD", "wget", "--spider", "-q", "http://localhost:8092/"\]|test: ["CMD", "node", "-e", "require('\''http'\'').get('\''http://localhost:8092/'\'',r=>process.exit(0)).on('\''error'\'',e=>process.exit(1))"]|' "$DCF"
# NOTE: VITE_* env vars are already in the GitHub compose file —
# no sed patch needed. Adding them would cause duplicate key errors.

echo "=== Write nginx-default.conf ==="
cat > /home/ubuntu/develop/docker/nginx-default.conf <<'NGINX'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    resolver 127.0.0.11 valid=30s;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_comp_level 6;

    location /api/backend/ { proxy_pass http://rxsoft-backend:8080/api/; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/identity/ { proxy_pass http://rxsoft-identity:8092/; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/lis/ { set $lis_upstream http://rxsoft-lis-backend:8091/; proxy_pass $lis_upstream; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/conversation/ { set $conv_upstream http://rxsoft-conversation-engine:8090/; proxy_pass $conv_upstream; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/communication/ { proxy_pass http://rxsoft-backend:8080/; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/coding/ { set $coding_upstream http://healthcare-interop:3000/; proxy_pass $coding_upstream; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /api/healthcare-concepts/ { set $hc_upstream http://rxsoft-healthcare-concepts:3011/; proxy_pass $hc_upstream; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location / { try_files $uri $uri/ /index.html; }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ { expires 1y; add_header Cache-Control "public, immutable"; }
}
NGINX

echo "=== Create Dockerfile.rxsoft-lis-backend ==="
cat > /home/ubuntu/develop/docker/Dockerfile.rxsoft-lis-backend <<'DFILE'
FROM node:22-slim AS build
WORKDIR /app
RUN npm config set fetch-timeout 300000
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json nest-cli.json ./
COPY src ./src
RUN npm run build
FROM node:22-slim AS production
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY package.json ./
EXPOSE 8091
CMD ["node", "dist/main"]
DFILE

echo "=== Start services ==="
DEPLOY_MODE=prod
COMPOSE_FILE="/home/ubuntu/develop/docker/docker-compose.prod.yml"
# Build one image at a time to avoid OOM on t3.small (2GB RAM)
export COMPOSE_PARALLEL_LIMIT=1
docker compose -f "$COMPOSE_FILE" --env-file /home/ubuntu/develop/docker/.env.memory __PROFILE_FLAGS__ up -d --wait 2>/dev/null || \
docker compose -f "$COMPOSE_FILE" --env-file /home/ubuntu/develop/docker/.env.memory __PROFILE_FLAGS__ up -d

echo ""
echo "============================================"
echo "Bootstrap complete!"
echo "============================================"
