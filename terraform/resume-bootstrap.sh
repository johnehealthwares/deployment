#!/bin/bash
set -e

echo "=== Write backup config ==="
cat > /home/ubuntu/develop/docker/.env.backup <<'ENVEOF'
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=admin123
MONGO_INITDB_DATABASE=rxsoft
S3_BUCKET=rxsoft-postgres-backups-prod
AWS_REGION=eu-west-1
ENVEOF

echo "=== Memory limits ==="
echo "# Auto-generated" > /home/ubuntu/develop/docker/.env.memory
echo "MEM_MONGODB=286m" >> /home/ubuntu/develop/docker/.env.memory
echo "MEM_RXSOFT_BACKEND=286m" >> /home/ubuntu/develop/docker/.env.memory
echo "MEM_POSTGRES=286m" >> /home/ubuntu/develop/docker/.env.memory
echo "MEM_MONGO_INIT=38m" >> /home/ubuntu/develop/docker/.env.memory
echo "MEM_RXSOFT_ADMIN=76m" >> /home/ubuntu/develop/docker/.env.memory

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
openssl rand -base64 756 > /home/ubuntu/develop/docker/mongodb/mongo-keyfile
chmod 400 /home/ubuntu/develop/docker/mongodb/mongo-keyfile

echo "=== Patch docker-compose.prod.yml ==="
DCF=/home/ubuntu/develop/docker/docker-compose.prod.yml
sed -i '/postgres_data:\/var\/lib\/postgresql\/data/a\      - .\/postgres-init:\/docker-entrypoint-initdb.d' "$DCF"
sed -i 's|test: \["CMD", "wget", "--spider", "-q", "http://localhost:8080/"\]|test: ["CMD", "node", "-e", "require('\''http'\'').get('\''http://localhost:8080/'\'',r=>process.exit(0)).on('\''error'\'',e=>process.exit(1))"]|' "$DCF"
sed -i 's|test: \["CMD", "wget", "--spider", "-q", "http://localhost:8092/"\]|test: ["CMD", "node", "-e", "require('\''http'\'').get('\''http://localhost:8092/'\'',r=>process.exit(0)).on('\''error'\'',e=>process.exit(1))"]|' "$DCF"
sed -i '/container_name: rxsoft-admin/,/healthcheck:/{ /^    environment:/a\      VITE_RXSOFT_API_URL: /api/backend\n      VITE_IDENTITY_API_URL: /api/identity\n      VITE_LIS_API_URL: /api/lis\n      VITE_CONVERSATION_API_URL: /api/conversation\n      VITE_COMMUNICATION_API_URL: /api/communication\n      VITE_CODING_CONCEPT_API_URL: /api/coding
}' "$DCF"

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
docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml --env-file /home/ubuntu/develop/docker/.env.memory --profile postgres --profile mongodb --profile rxsoft-backend --profile rxsoft-identity --profile rxsoft-admin up -d

echo ""
echo "============================================"
echo "Bootstrap complete!"
echo "============================================"
