# RxSoft EC2 Troubleshooting Cheatsheet

All commands run from `deployment/` unless prefixed with `ssh`.

## SSH

```bash
# Interactive shell (uses terraform output to get IP)
./ssh.sh

# Run one command
./ssh.sh sudo docker ps

# Direct SSH (if you know the IP)
ssh -i terraform/ssh/id_rsa ubuntu@<IP>
```

## Exec Into Containers

```bash
# Backend (NestJS) — browse API, check DB connection
./ssh.sh sudo docker exec -it rxsoft-backend sh

# Identity (NestJS) — check auth, tokens
./ssh.sh sudo docker exec -it rxsoft-identity sh

# Admin (nginx + React) — check nginx config, static files
./ssh.sh sudo docker exec -it rxsoft-admin sh

# PostgreSQL — run SQL queries
./ssh.sh sudo docker exec -it rxsoft-postgres psql -U postgres

# MongoDB — run mongo queries
./ssh.sh sudo docker exec -it rxsoft-mongodb mongosh -u admin -p admin123 --authenticationDatabase admin

# Adminer (web DB admin tool) — if running
./ssh.sh sudo docker exec -it rxsoft-adminer sh

# Mongo Express (web Mongo admin tool) — if running
./ssh.sh sudo docker exec -it rxsoft-mongo-express sh
```

## Nginx Config

```bash
# View all nginx configs in the admin container
./ssh.sh sudo docker exec rxsoft-admin ls /etc/nginx/conf.d/
./ssh.sh sudo docker exec rxsoft-admin cat /etc/nginx/conf.d/default.conf
./ssh.sh sudo docker exec rxsoft-admin cat /etc/nginx/conf.d/rxsoft.conf
./ssh.sh sudo docker exec rxsoft-admin cat /etc/nginx/conf.d/api.conf
./ssh.sh sudo docker exec rxsoft-admin cat /etc/nginx/conf.d/www.conf

# View the full loaded config (all files merged, no includes)
./ssh.sh sudo docker exec rxsoft-admin nginx -T

# Grep for a specific server_name in loaded config
./ssh.sh sudo docker exec rxsoft-admin nginx -T 2>&1 | grep -A10 'server_name.*damorex'

# Test config validity
./ssh.sh sudo docker exec rxsoft-admin nginx -t

# Reload config (after changes)
./ssh.sh sudo docker exec rxsoft-admin nginx -s reload

# View nginx error log
./ssh.sh sudo docker exec rxsoft-admin cat /var/log/nginx/error.log

# SCP local configs to server
scp -i terraform/ssh/id_rsa docker/nginx-default.conf ubuntu@<IP>:/home/ubuntu/develop/docker/
```

## List Container Environment Variables

```bash
# All services
./ssh.sh sudo docker exec rxsoft-backend env | sort
./ssh.sh sudo docker exec rxsoft-identity env | sort
./ssh.sh sudo docker exec rxsoft-admin env | sort
./ssh.sh sudo docker exec rxsoft-postgres env | sort
./ssh.sh sudo docker exec rxsoft-mongodb env | sort
./ssh.sh sudo docker exec rxsoft-conversation-engine env | sort

# Single variable lookup
./ssh.sh sudo docker exec rxsoft-backend printenv DB_HOST JWT_ACCESS_SECRET

# Via docker inspect (raw format, one per line)
./ssh.sh sudo docker inspect rxsoft-backend --format '{{range .Config.Env}}{{println .}}{{end}}'
./ssh.sh sudo docker inspect rxsoft-identity --format '{{range .Config.Env}}{{println .}}{{end}}'
./ssh.sh sudo docker inspect rxsoft-admin --format '{{range .Config.Env}}{{println .}}{{end}}'
```

## Containers

```bash
# List all containers
./ssh.sh sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Tail logs
./ssh.sh sudo docker logs rxsoft-backend --tail 20
./ssh.sh sudo docker logs rxsoft-identity --tail 20
./ssh.sh sudo docker logs rxsoft-mongodb --tail 20
./ssh.sh sudo docker logs rxsoft-postgres --tail 20
./ssh.sh sudo docker logs rxsoft-admin --tail 20
./ssh.sh sudo docker logs rxsoft-ehealthwares --tail 20
./ssh.sh sudo docker logs rxsoft-adminer --tail 20
./ssh.sh sudo docker logs rxsoft-mongo-express --tail 20

# Restart single service (--force-recreate picks up .env file changes)
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml --env-file /home/ubuntu/develop/docker/.env.memory up -d --no-deps --force-recreate <service>

# Rebuild single service (use --no-cache for fresh build)
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml build --no-cache <service>
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml up -d --no-deps --force-recreate <service>
```

## Adminer & Mongo Express (Web DB Tools)

```bash
# Deploy (one-time)
./deploy_databases.sh   # starts adminer and mongo-express alongside postgres/mongodb

# Access
#   Adminer:       http://<IP>:8081/     — PostgreSQL + any SQL DB
#   Mongo Express: http://<IP>:8082/     — MongoDB

# Adminer login:
#   System:      PostgreSQL
#   Server:      rxsoft-postgres (Docker network) or localhost
#   Username:    postgres
#   Password:    postgres
#   Database:    rxsoft, lis, or identity

# Mongo Express:
#   Auto-connected to rxsoft-mongodb via compose network
#   No login required (ME_CONFIG_BASICAUTH=false)
```

### nginx routes (optional, for cleaner access via port 80)

Add to `nginx-default.conf` or upload via `dns-update.sh`:

```nginx
location /adminer/ {
    proxy_pass http://rxsoft-adminer:8080/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
location /mongo-express/ {
    proxy_pass http://rxsoft-mongo-express:8081/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

Then reload nginx:
```bash
./ssh.sh sudo docker exec rxsoft-admin nginx -s reload
```

## Health Check

```bash
# Admin frontend
curl -s -o /dev/null -w "%{http_code}" http://<IP>/

# Backend API
curl -s http://<IP>/api/backend/website/homepage | head -5

# Identity
curl -s -o /dev/null -w "%{http_code}" http://<IP>/api/identity/
```

## Common Fixes

### MongoDB won't start (keyfile issues)
```bash
./ssh.sh sudo chown 999:999 /home/ubuntu/develop/docker/mongodb/mongo-keyfile
./ssh.sh sudo chmod 400 /home/ubuntu/develop/docker/mongodb/mongo-keyfile
./ssh.sh sudo docker rm -f rxsoft-mongodb
./ssh.sh sudo docker volume rm docker_mongo_data docker_mongo_config
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml --env-file /home/ubuntu/develop/docker/.env.memory up -d --no-deps mongodb
```

### Admin JS has wrong URLs
```bash
./ssh.sh sudo docker exec rxsoft-admin sh -c '
  sed -i "s|https://rxsoft-backend.onrender.com/api|/api/backend|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:3011/api/v1|/api/healthcare-concepts/api/v1|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:8091|/api/lis|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:3000/api/v1|/api/coding/api/v1|g" /usr/share/nginx/html/assets/*.js
  sed -i "s|http://localhost:8080/api|/api/conversation|g" /usr/share/nginx/html/assets/*.js
'
```

### OOM during build
```bash
# Build one at a time
./ssh.sh sudo COMPOSE_PARALLEL_LIMIT=1 docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml up -d <service>
```

### Env file changes not picked up after restart
Docker Compose doesn't detect when a `.env.<service>` file's *content* changes (only the file path reference in `env_file:` matters). Use `--force-recreate` to force the container to be re-created and read the updated env file.

```bash
# Single service — picks up new values from the .env file
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml \
  --env-file /home/ubuntu/develop/docker/.env.memory up -d --no-deps --force-recreate <service>

# Shortcut via restart-service.sh (already patched with --force-recreate)
./restart-service.sh <service>

# Verify the new values took effect
./ssh.sh sudo docker exec <container> env | sort

# Or using plain docker (bypass compose): stop, rm, re-run with --env-file
./ssh.sh sudo docker stop rxsoft-backend
./ssh.sh sudo docker rm rxsoft-backend
./ssh.sh sudo docker run -d --name rxsoft-backend \
  --env-file /home/ubuntu/develop/docker/.env.rxsoft-backend \
  --network rxsoft --restart unless-stopped \
  -p 8000:8080 \
  \$AWS_ACCOUNT_ID.dkr.ecr.\$AWS_REGION.amazonaws.com/rxsoft-backend:latest
```

### ECR 403 Forbidden on pull (expired auth token)
ECR login tokens expire after 12 hours. It also happens if the instance's IAM role lacks `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, `ecr:BatchCheckLayerAvailability`.

```bash
# Re-authenticate Docker to ECR (use ssh -t for sudo tty)
ssh -t -i terraform/ssh/id_rsa ubuntu@$(cat .ec2-ip) \
  "sudo aws ecr get-login-password --region eu-west-1 | sudo docker login --username AWS --password-stdin 750906968644.dkr.ecr.eu-west-1.amazonaws.com"

# Verify
./ssh.sh sudo docker pull 750906968644.dkr.ecr.eu-west-1.amazonaws.com/rxsoft-backend:latest
```

### Re-run cloud-init after script change
```bash
./ssh.sh sudo bash /var/lib/cloud/instance/scripts/part-001
```

### MongoDB replica set lost (rs.status() fails)
```bash
# Quick fix — re-run replica set init (handles bootstrap if admin user missing)
./deploy_mongo_init.sh

# Manual approach — if admin user exists:
./ssh.sh sudo docker exec rxsoft-mongodb mongosh -u admin -p admin123 \
  --authenticationDatabase admin --quiet \
  --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"localhost:27017"}]})'

# Manual approach — if admin user does NOT exist (bootstraps via temp container):
./ssh.sh sudo bash -c '
  docker stop rxsoft-mongodb
  docker run -d --name rxsoft-mongodb-tmp --network docker_rxsoft \
    -v docker_mongo_data:/data/db \
    mongo:8.0 --bind_ip_all --port 27018
  sleep 5
  docker exec rxsoft-mongodb-tmp mongosh admin --quiet \
    --eval "db.createUser({user:\"admin\",pwd:\"admin123\",roles:[{role:\"root\",db:\"admin\"}]})"
  docker stop rxsoft-mongodb-tmp; docker rm rxsoft-mongodb-tmp
  docker start rxsoft-mongodb
  sleep 10
  docker exec rxsoft-mongodb mongosh -u admin -p admin123 \
    --authenticationDatabase admin --quiet \
    --eval "rs.initiate({_id:\"rs0\",members:[{_id:0,host:\"localhost:27017\"}]})"
'

# Verify
./ssh.sh sudo docker exec rxsoft-mongodb mongosh -u admin -p admin123 \
  --authenticationDatabase admin --quiet --eval 'rs.status().ok'
# Should return 1
```

## Deployed Commit Hash

```bash
# Method 1: Fast — rxsoft-backend only (GIT_COMMIT baked into image at build time)
./ssh.sh sudo docker exec rxsoft-backend env | grep ^GIT_COMMIT

# Method 2: ECR image digest lookup — all services
# Finds the commit-<sha> tag in ECR matching the running container's image digest
./ssh.sh sudo bash -c '
  for svc in rxsoft-backend rxsoft-identity rxsoft-admin rxsoft-ehealthwares rxsoft-conversation-engine; do
    IMAGE=$(docker inspect $svc --format "{{.Config.Image}}" 2>/dev/null) || { echo "  $svc: not running"; continue; }
    DIGEST=$(docker inspect $svc --format "{{.Image}}" 2>/dev/null | sed "s/sha256://")
    REPO=$(echo "$IMAGE" | sed "s|^[^/]*/||" | cut -d: -f1)
    COMMIT=$(aws ecr describe-images --repository-name "$REPO" --image-ids "imageDigest=sha256:$DIGEST" \
      --query "imageDetails[0].imageTags" --output text 2>/dev/null | tr "\t" "\n" | grep "^commit-" | head -1 | sed "s/^commit-//" || echo "no commit tag")
    echo "  $svc: $COMMIT"
  done
'

# Method 3: One-liner for a single service
./ssh.sh sudo bash -c '
  svc=rxsoft-backend
  DIGEST=$(docker inspect $svc --format "{{.Image}}" | sed "s/sha256://")
  REPO=$(docker inspect $svc --format "{{.Config.Image}}" | sed "s|^[^/]*/||" | cut -d: -f1)
  aws ecr describe-images --repository-name "$REPO" --image-ids "imageDigest=sha256:$DIGEST" \
    --query "imageDetails[0].imageTags" --output text | tr "\t" "\n" | grep "^commit-" | sed "s/^commit-//"
'
```

## Backup

```bash
# Manual backup
./ssh.sh sudo /home/ubuntu/develop/docker/backup.sh

# List backups
./ssh.sh sudo ls -la /var/backups/rxsoft/

# S3 backups
aws s3 ls s3://rxsoft-postgres-backups-prod/rxsoft/
```

## Terraform

```bash
# Apply (or re-apply after changes)
cd terraform && terraform apply -auto-approve

# Force re-create instance
terraform taint aws_instance.postgres
terraform apply -auto-approve

# Get public IP
terraform output public_ip

# Teardown
terraform destroy -auto-approve
```
