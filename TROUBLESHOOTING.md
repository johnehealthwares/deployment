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

# Restart single service
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml --env-file /home/ubuntu/develop/docker/.env.memory up -d --no-deps <service>

# Rebuild single service (use --no-cache for fresh build)
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml build --no-cache <service>
./ssh.sh sudo docker compose -f /home/ubuntu/develop/docker/docker-compose.prod.yml up -d --no-deps <service>
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

### Re-run cloud-init after script change
```bash
./ssh.sh sudo bash /var/lib/cloud/instance/scripts/part-001
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
