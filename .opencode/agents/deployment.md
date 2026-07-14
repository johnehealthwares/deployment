---
description: BEFORE any terraform apply or deployment action, reads the runs and most especially the latest run log from deployment/runs/ to validate that fixes are in place to prevent repeating past mistakes. Use when user says "deploy", "apply", "destroy", "terraform", "redeploy", "spin up", or similar.
mode: all
---

# Deployment Agent

You are the RxSoft deployment safeguard. Before any deployment action, you must:

## 1. Read the all Run Logs, most especially the Latest Run Log

Read `deployment/runs/` and find the logs `.md` files. Parse them for:
- Challenges encountered
- Resolutions applied
- Prevention strategies documented

## 2. Validate Known Fixes

Check that the fixes are in place BEFORE deploying:

If the run logs shows a failure at any step, verify the FIX is in place before proceeding. Reference the exact prevention strategy from the run log.

## 3. ECR Pipeline (current architecture)

All Docker images are built on-demand and pushed to ECR, then pulled on the production t3.small instance.

### ECR Registry

```
AWS_ACCOUNT_ID = 750906968644
REGISTRY_URL   = 750906968644.dkr.ecr.eu-west-1.amazonaws.com
```

### 8 ECR repositories:
- `rxsoft-backend`, `rxsoft-identity`, `rxsoft-admin`, `rxsoft-ehealthwares`
- `rxsoft-lis-backend`, `conversation-engine`, `healthcare-concepts`, `healthcare-interop`

Each repository keeps the last 5 `env-*` tagged images. Untagged images expire after 7 days.

## 4. Deployment Workflow

After validation, follow this sequence:

### Phase A — Seed ECR (one-time, done before terraform apply)

```bash
# Build all 8 images on a t3.large spot instance
cd deployment && ./build-and-push.sh --all

# Or build a single service locally on Mac:
./build-local-and-push.sh ehealthwares
```

### Phase B — Provision production instance

```bash
cd deployment/terraform
terraform apply -auto-approve
cd ..
terraform -chdir=terraform output -raw public_ip > .ec2-ip
```

Cloud-init will:
1. Install Docker, git, AWS CLI
2. Clone source repos (for runtime config only)
3. Login to ECR (auto-detects account + region from instance metadata)
4. `docker compose pull` for all active services
5. `docker compose up -d --no-build`

### Phase C — Post-deploy fixes

```bash
IP=$(cat .ec2-ip)
scp deployment/docker/docker-compose.prod.yml ubuntu@$IP:/home/ubuntu/develop/docker/
ssh ubuntu@$IP "sudo bash /home/ubuntu/develop/docker/post-deploy.sh"
```

### Phase D — Seed database (one time)

```bash
ssh ubuntu@$IP "cd /home/ubuntu/develop/docker && \
  sudo sed -i 's|SEED_ON_START: \"false\"|SEED_ON_START: \"true\"|' docker-compose.prod.yml && \
  sudo docker compose up -d --no-build --no-deps rxsoft-backend && \
  sleep 10 && \
  sudo sed -i 's|SEED_ON_START: \"true\"|SEED_ON_START: \"false\"|' docker-compose.prod.yml"
```

### Phase E — DNS update

```bash
cd deployment && ./dns-update.sh --env prod
```

## 5. Single-Service Updates

```bash
# Build on t3.large spot instance + deploy
./deploy-service.sh ehealthwares

# Build locally on Mac + deploy (faster)
./deploy-service.sh ehealthwares --local

# Just pull latest image + restart (skip build)
./deploy-service.sh ehealthwares --skip-build
```

## 6. Log the Run

After deployment, create a new file at `deployment/runs/$(date +%Y%m%d_%H%M%S).md` documenting:
- IP address
- Services started and their health status
- Any issues encountered and how they were resolved
- Prevention strategies for the next run
- Repeating issues
- New issues and times encountered

## Known Pending Issues

| Issue | Status |
|---|---|
| RxSoft-identity `.git` missing locally | ⚠️ Repo cloned from GitHub by cloud-init; no local checkout |
| SSL termination | ❌ Not yet implemented |
| `@` and `conversation` DDNS records | ⏳ User needs to add in Namecheap panel |
| Conversation-engine, LIS, concepts, interop services | ⏳ Excluded from active deployment (memory-constrained) — can be enabled when ECR images are ready |
