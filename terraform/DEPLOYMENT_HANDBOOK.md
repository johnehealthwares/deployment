# RxSoft Deployment Handbook

> **Living document** — every failure and fix is recorded here so we never repeat mistakes.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Deployment Phases](#deployment-phases)
3. [Challenges & Resolutions](#challenges--resolutions)
4. [Variable Injection Points](#variable-injection-points)
5. [Seamless Deployment Checklist](#seamless-deployment-checklist)
6. [Post-Deploy Verification](#post-deploy-verification)
7. [Recovery Procedures](#recovery-procedures)

---

## Architecture Overview

```
Internet → EC2 (t3.small, 2GB RAM, 30GB gp3)
  ├── nginx (rxsoft-admin container, port 80)
  │   ├── /api/backend/*    → rxsoft-backend:8080/api/
  │   ├── /api/identity/*   → rxsoft-identity:8092/
  │   ├── /api/lis/*        → rxsoft-lis-backend:8091/
  │   ├── /api/conversation/* → conversation-engine:8090/
  │   ├── /api/communication/* → rxsoft-backend:8080/
  │   ├── /api/coding/*     → healthcare-interop:3000/
  │   └── /api/healthcare-concepts/* → healthcare-concepts:3011/
  ├── postgres:16 (port 5432)
  ├── mongodb:8.0 (port 27017, replica set rs0)
  ├── rxsoft-backend (port 8000→8080)
  └── rxsoft-identity (port 8005→8092)
```

### Service-to-Service Dependencies

```
postgres ─┬── rxsoft-backend (DB: rxsoft)
          ├── rxsoft-identity (DB: identity)
          └── rxsoft-lis-backend (DB: lis)

mongodb ──┬── rxsoft-backend (DB: apm_campaign)
          └── conversation-engine (DB: conversation_engine)
```

---

## Deployment Phases

### Phase 0: Prerequisites
- Python 3, Terraform, AWS CLI configured
- SSH key at `deployment/terraform/ssh/id_rsa`
- GitHub repos: all public (common-admin, common-healthcare-resources are private)
- S3 bucket: `rxsoft-postgres-backups-prod` (created manually)

### Phase 1: Terraform Infrastructure
```
cd deployment/terraform
terraform apply -auto-approve
```

### Phase 2: Cloud-init Bootstrap
On first boot, cloud-init.sh runs automatically:
1. System packages (Docker, git, curl, AWS CLI)
2. 2GB swap file
3. Docker start
4. Git clone all repos
5. Init scripts (postgres-init, mongo-init)
6. MongoDB keyfile
7. Docker compose up

### Phase 3: Post-Deploy Fixes
After cloud-init completes, manual fixes are currently required:
1. Fix Dockerfiles for missing lockfiles / OOM
2. Start services sequentially
3. MongoDB keyfile ownership
4. Patch admin JS files

### Phase 4: Verification
Test all endpoints and backup.

### Phase 5: Teardown
```
terraform destroy
```

---

## Challenges & Resolutions

### C1. Cloud-init `user_data` size limit (16384 bytes)

**Symptom:** AWS rejected cloud-init scripts > 16384 bytes.

**Root Cause:** The cloud-init script with all inline files (Dockerfiles, init scripts, nginx config) exceeded the hard AWS limit.

**Resolution:** 
- Moved most file content to the GitHub deployment repo (`johnehealthwares/docker.git`)
- Used `sed` patches to modify cloned files instead of embedding copies
- Only essential scripts remain inline (postgres-init, mongo-init, nginx.conf)
- Terraform uses `replace()` for template variables (`__SERVICE_MEMORY__`, `__BACKUP_ENV__`, `__PROFILE_FLAGS__`)

**Lesson:** Cloud-init is for bootstrap scaffolding only. Store application config in the deployment repo.

### C2. `user_data_replace_on_change = false` prevents re-run

**Symptom:** After updating cloud-init.sh, `terraform apply` did NOT re-run the script on reboot.

**Root Cause:** Terraform's `aws_instance` resource has `user_data_replace_on_change = false` by default. The updated user_data was uploaded but the instance wasn't replaced. On reboot, cloud-init saw the same instance-id and skipped the scripts_user module (frequency: once-per-instance).

**Resolution:** Manually run `sudo bash /var/lib/cloud/instance/scripts/part-001` on the server after applying terraform. Or use `terraform taint` to force recreation.

**Lesson:** Set `user_data_replace_on_change = true` in terraform, or accept that cloud-init changes require `terraform taint aws_instance.postgres && terraform apply`.

### C3. Git clone fails on existing directories

**Symptom:** `git clone` exits with non-zero when the target directory already exists. With `set -e`, the entire script aborts.

**Resolution:** Added `rm -rf "$repo"` before each `git clone`.

### C4. Private repos can't be cloned (GitHub auth)

**Symptom:** `fatal: could not read Username for 'https://github.com'` for `common-admin` and `common-healthcare-resources` repos.

**Root Cause:** These repos are private. No GitHub token or SSH key was configured on the server.

**Resolution:** These repos are actually PUBLIC under different names (`johnehealthwares/common-admin` is `rxsoft-admin-3`, `johnehealthwares/common-healthcare-resources` is `healthcare-concepts`). The cloned directories (`common-admin/`, `common-healthcare-resources/`) are symlinked or directly used by Docker build contexts.

**Current State:** Public repos clone fine. Private repos are not needed — the compose build contexts (`../common-admin`, `../common-healthcare-resources`, `../identity`) match the public GitHub repo names.

**Lesson:** Match clone list exactly to compose build context paths. Verify each repo is public before adding to clone list.

### C5. Lockfiles not committed to repos

**Symptom:** Dockerfile build fails with `COPY yarn.lock ./` → not found, or `yarn install --frozen-lockfile` fails without lockfile.

**Root Cause:** The repos do not commit `yarn.lock`, `package-lock.json`, or `nest-cli.json`. These are generated by local development tools.

**Files affected:** `Dockerfile.rxsoft-admin`, `Dockerfile.rxsoft-backend`, `Dockerfile.rxsoft-identity`, `Dockerfile.conversation-engine`, `Dockerfile.healthcare-concepts`

**Resolution:**
- Removed `yarn.lock`/`package-lock.json` from COPY commands
- Replaced `--frozen-lockfile` / `npm ci` with `yarn install` / `npm install`
- Created minimal `nest-cli.json` in repos that lack it

**Lesson:** Dockerfiles must handle repos that don't commit lockfiles. Always use `yarn install`/`npm install` without frozen flag unless lockfile is guaranteed.

### C6. OOM during TypeScript build on t3.small

**Symptom:** `FATAL ERROR: Ineffective mark-compacts near heap limit` during `yarn build` / `nest build`. Node exits with code 134.

**Root Cause:** t3.small has only 2GB RAM. Docker build container has no memory limit and can use all host memory. The TypeScript compiler (`nest build` → `tsc`) allocated > 1GB and hit the V8 heap limit (even with `--max-old-space-size=1536`).

**Resolution:**
- Use pre-built `dist/` from git repo (1366 files, 14MB) — avoids running tsc at all
- Added 2GB swap file as safety net
- Set `NODE_OPTIONS="--max-old-space-size=1536"` in Dockerfiles that still build
- Build services sequentially (`COMPOSE_PARALLEL_LIMIT=1`)

**Services using pre-built dist:**
| Service | Dist size | Reason |
|---------|-----------|--------|
| rxsoft-backend | 14MB (committed) | Largest project, 456 TS files |
| rxsoft-identity | 1.6MB (committed) | Avoid tsc entirely |

**Services that still build from source:**
| Service | Reason |
|---------|--------|
| rxsoft-admin | Vite build, not tsc |
| rxsoft-lis-backend | No pre-built dist, but small (130 files) |
| conversation-engine | No pre-built dist, moderate (168 files) |
| healthcare-concepts | No pre-built dist, small |
| healthcare-interop | Has pre-built dist (1.8MB) |

**Lesson:** For memory-constrained instances, prefer repos that commit `dist/`. Otherwise, build on larger instances or pre-build images.

### C7. MongoDB keyfile permissions

**Symptom:** MongoDB container crashes immediately with:
```
"Read security file failed" — "permissions on /etc/mongo-keyfile are too open"
"Error creating service context" — "Unable to acquire security key[s]"
```

**Root Cause:** Three interleaved issues:
1. Keyfile created with `chmod 444` (world-readable) — MongoDB rejects this
2. Keyfile owned by `root:root` — MongoDB process runs as UID 999, can't read `chmod 400` root-owned file
3. Keyfile content contained newlines from `openssl rand -base64 756` (OpenSSL wraps at 64 chars)

**Resolution:**
```
openssl rand -base64 756 | tr -d \\n > mongo-keyfile  # remove newlines
chown 999:999 mongo-keyfile                             # match container UID
chmod 400 mongo-keyfile                                  # MongoDB-required mode (not 444)
```

**Lesson:** MongoDB keyfiles require:
- Content: 6–1024 chars, base64 charset, no newlines
- Permissions: 400 or 600 only (not 444!)
- Ownership: must match container user (UID 999 for mongo:8.0)

### C8. nginx-default.conf not in build context

**Symptom:** Docker build for admin fails:
```
COPY nginx-default.conf /etc/nginx/conf.d/default.conf
ERROR: failed to compute cache key: "/nginx-default.conf": not found
```

**Root Cause:** Docker build context is `../common-admin` but `nginx-default.conf` lives in `../docker/`. Docker COPY cannot access files outside the build context.

**Resolution:** Copy `nginx-default.conf` into the common-admin dir before building, or change the compose to use a wider build context.

**Current Fix:** `cp /home/ubuntu/develop/docker/nginx-default.conf /home/ubuntu/develop/common-admin/` before building. Also added `COPY nginx-default.conf` to the Dockerfile.

**Better Fix (TODO):** Change compose to use build context `../docker` with dockerfile `Dockerfile.rxsoft-admin`, and adjust COPY paths accordingly. Or embed the nginx config as a config map.

### C9. VITE_* env vars not passed to build

**Symptom:** Built admin JS files still contain `https://rxsoft-backend.onrender.com/api` and `http://localhost:*` URLs despite setting `VITE_*` in compose `environment:`.

**Root Cause:** `import.meta.env.VITE_*` values are baked into the JavaScript bundle at **build time** by Vite. Docker compose `environment:` only sets runtime env vars for the container, which Vite doesn't read since it already compiled.

**Resolution:**
1. Added `build: args:` to compose that passes `VITE_*` as Docker build args
2. Added `ARG` + `ENV` declarations in `Dockerfile.rxsoft-admin` to forward build args to the Vite build process
3. For running containers without rebuild: `sed -i` patch the built JS files in-place

**Current state:** Build args work for new builds. Existing containers need JS patching.

**Lesson:** Vite env vars must be passed as Docker build args, not runtime env vars. The pattern is:
```yaml
# docker-compose.yml
build:
  args:
    VITE_API_URL: /api/backend
```
```dockerfile
# Dockerfile
ARG VITE_API_URL
ENV VITE_API_URL=$VITE_API_URL
```

### C10. nginx proxy trailing-slash semantics

**Symptom:** Backend returned 500 errors for proxied requests.

**Root Cause:** The nginx `proxy_pass` directive has different behavior with and without trailing slashes:
- `proxy_pass http://backend:8080/api/;` — strips matched location prefix, appends `/api/` + remainder
- `proxy_pass http://backend:8080;` — passes full original URI

**Resolution:** Match trailing-slash behavior carefully:
```
location /api/backend/ {
    proxy_pass http://rxsoft-backend:8080/api/;
    # /api/backend/website/homepage → http://rxsoft-backend:8080/api/website/homepage
}
```

**Lesson:** nginx proxy_pass with path = replaces matched location prefix with the proxy path. Without path = passes original URI unchanged.

### C11. Docker compose parallel builds cause OOM

**Symptom:** When building multiple images simultaneously, memory runs out faster.

**Resolution:** Set `COMPOSE_PARALLEL_LIMIT=1` to build one image at a time, or build services individually with `--no-deps <service>`.

### C12. Jenkins cron persistence

**Symptom:** Cron job for daily backup lost after reboot (if not in `/etc/cron.d/`).

**Resolution:** Install cron at `/etc/cron.d/rxsoft` (system-wide, survives reboot). Add swap to `/etc/fstab` for persistence.

---

## Variable Injection Points

Every variable that enters the deployment has a defined injection point. This table shows where each type of variable is set, how it flows through the system, and how to change it.

### By Variable Type

| Variable Type | Examples | Injection Point | Scope | How to Change |
|---|---|---|---|---|
| **Terraform vars** | `aws_region`, `instance_type`, `deploy_mode` | `variables.tf` / `terraform.tfvars` | Terraform only | Edit .tfvars, re-apply |
| **Cloud-init** | `__SERVICE_MEMORY__`, `__BACKUP_ENV__`, `__PROFILE_FLAGS__` | `main.tf` via `replace()` on `cloud-init.sh` | Bootstrap | Edit `variables.tf` or `.env`, re-apply terraform |
| **Docker Compose** | `PORT`, `DB_HOST`, `DB_NAME`, `JWT_ACCESS_SECRET` | `docker-compose.prod.yml` `environment:` | Container runtime | Edit compose file, `docker compose up -d` |
| **Docker Build Args** | `VITE_RXSOFT_API_URL`, `VITE_IDENTITY_API_URL` | Compose `build: args:` + Dockerfile `ARG`/`ENV` | Build-time only | Edit compose + rebuild |
| **Dockerfile ENV** | `NODE_OPTIONS`, `YARN_HTTP_TIMEOUT` | Inline in Dockerfile | Build-time | Edit Dockerfile |
| **nginx proxy** | Backend upstream URLs, proxy paths | `nginx-default.conf` | Runtime (nginx) | Edit conf, restart admin |
| **Runtime patches** | render.com → IP replacement | `sed -i` in running container | Runtime only | Re-run sed, or rebuild image |
| **Backup config** | `S3_BUCKET`, `POSTGRES_USER` | `.env.backup` (written by cloud-init) | Cron (backup.sh) | Edit `.env.backup`, or update terraform `.env` |

### By Deployment Stage

```
[terraform apply]
  ├── variables.tf            → aws_region, instance_type, allowed_ips
  ├── .env                    → __BACKUP_ENV__ (S3_BUCKET, DB creds)
  ├── variables.tf            → __SERVICE_MEMORY__, __PROFILE_FLAGS__
  └── cloud-init.sh           → user_data script (≤ 16384 bytes)
       │
       ▼
[cloud-init runs]
  ├── git clone repos         → source code + deployment config
  ├── sed patches             → compose file (healthchecks, mounts, env vars)
  ├── heredoc files           → nginx-default.conf, init scripts, Dockerfiles
  └── docker compose up -d    → containers start
       │
       ▼
[Docker build]
  ├── build: args:            → VITE_* for admin (baked into JS at build time)
  └── Dockerfile ENV          → NODE_OPTIONS, YARN_HTTP_TIMEOUT
       │
       ▼
[Docker runtime]
  ├── compose environment:    → PORT, DB_HOST, JWT_*, etc.
  ├── nginx config            → proxy_pass upstreams
  └── sed -i patches          → JS file URL replacements (temporary fix)
```

### Public IP Injection

The EC2 public IP is not known until `terraform apply` completes. It flows into the system as follows:

| Path | File | How IP Gets In |
|---|---|---|
| nginx proxy | `nginx-default.conf` | Uses Docker service names (e.g., `http://rxsoft-backend:8080/`), no IP needed |
| Admin JS | Built `.js` files | Via `VITE_*` build args: `/api/backend` (proxy-relative path) |
| Running container JS | `sed -i` patches | Manually: `sed -i "s|render.com|/api/backend|g" /usr/share/nginx/html/assets/*.js` |

**Key insight:** Because admin JS files use proxy-relative paths (`/api/backend`), the IP only needs to be known by the end user (browser URL). The server-side configuration uses Docker internal DNS, not IPs.

### Environment Variables Not Yet Injectable

These are hardcoded and should be made configurable:

| Location | Variable | Current Value | Where to inject from |
|---|---|---|---|
| compose → backend | `MONGODB_URI` | `mongodb://admin:admin123@...` | `.env.backup` or terraform var |
| compose → backend | `JWT_ACCESS_SECRET` | `admin-access-secret` | Terraform variable (sensitive) |
| compose → identity | `JWT_REFRESH_SECRET` | `admin-refresh-secret` | Terraform variable (sensitive) |
| compose → identity | `INTERNAL_API_KEY` | `rxsoft-internal-key` | Terraform variable (sensitive) |
| compose → all | `DB_PASSWORD` | `postgres` | Terraform variable (sensitive) |
| mongo-init | admin password | `admin123` | Terraform variable |

---

## How Seamless Deployment Works Now

### What's Automated (by cloud-init.sh)

| Step | Status | Notes |
|---|---|---|
| Install system packages | ✅ Auto | Docker, git, curl, AWS CLI |
| Add swap | ✅ Auto | 2GB, persisted to /etc/fstab |
| Start Docker | ✅ Auto | Retry up to 10x |
| Clone repos | ✅ Auto | 8 repos, removes existing dirs |
| Create postgres-init | ✅ Auto | Creates 3 databases on first start |
| Create mongo-init | ✅ Auto | Initializes replica set + admin user |
| Create MongoDB keyfile | ✅ Auto | Correct permissions (999:999, 400), no newlines |
| Write nginx config | ✅ Auto | Via heredoc in cloud-init |
| Write Dockerfile.lis-backend | ✅ Auto | Via heredoc |
| Patch compose file | ✅ Auto | Adds postgres-init mount, fixes healthchecks |
| Start services | ✅ Auto | Via docker compose with profile flags |
| Memory limits | ✅ Auto | Calculated from instance RAM |

### What's Manual (post-deploy)

| Step | Why Manual | Plan to Automate |
|---|---|---|
| Fix Dockerfiles (lockfiles, OOM) | cloud-init uses GitHub's Dockerfiles, not our local ones | Push fixes to GitHub repos |
| Start services one-at-a-time | OOM on parallel builds | Use `COMPOSE_PARALLEL_LIMIT=1` in cloud-init |
| Patch admin JS files | VITE_* not passed as build args by GitHub compose | Push fixed compose to GitHub |
| Fix nginx-default.conf path | Copied into build context | Embed in Dockerfile or change compose context |
| Create missing nest-cli.json | Not committed to some repos | Push to GitHub repos |
| Fix keyfile permissions | cloud-init creates with wrong permissions | **Already fixed** in cloud-init.sh |

### The "Push to GitHub" Fix

The most impactful change: **push these files to `johnehealthwares/docker.git`:**

```
deployment/docker/docker-compose.prod.yml      # build: args for admin, node healthchecks, identity service
deployment/docker/Dockerfile.rxsoft-backend    # pre-built dist, no yarn.lock
deployment/docker/Dockerfile.rxsoft-identity   # pre-built dist, no package-lock.json
deployment/docker/Dockerfile.rxsoft-admin      # ARG/ENV for VITE_*, nginx-default.conf inside
deployment/docker/Dockerfile.rxsoft-lis-backend # no package-lock.json
deployment/docker/Dockerfile.*                 # all fixed for lockfiles + OOM
deployment/docker/nginx-default.conf           # trailing-slash proxy_pass, all 7 routes
deployment/docker/backup.sh                    # fixed (MongoDB archive, S3 prefix, timeout)
deployment/docker/restore.sh                   # verified working
```

After pushing, cloud-init will pull the fixed versions and a fresh deploy will work out of the box.

---

## Seamless Deployment Checklist

### Pre-Deploy (Do Once)

- [ ] Push all fixed Dockerfiles to `johnehealthwares/docker.git`
- [ ] Push fixed `docker-compose.prod.yml` (with build args, identity service, node healthchecks)
- [ ] Push fixed `nginx-default.conf` (all 7 proxy routes, trailing-slash)
- [ ] Commit `nest-cli.json` to all repos that lack it
- [ ] Verify all 8 clone URLs are public and correct
- [ ] Set `user_data_replace_on_change = true` in `main.tf` (optional)

### Deploy

```bash
cd deployment/terraform

# Fresh deploy
terraform apply -auto-approve

# After code change
terraform taint aws_instance.postgres  # if user_data changed
terraform apply -auto-approve
```

### Post-Deploy Verify (Required Until Repos Updated)

- [ ] SSH: `ssh -i deployment/terraform/ssh/id_rsa ubuntu@<IP>`
- [ ] Check services: `sudo docker ps --format "table {{.Names}}\t{{.Status}}"`
- [ ] Expected: postgres (healthy), mongodb (healthy), backend (healthy), identity (healthy), admin (healthy)
- [ ] Fix if needed: rebuild services one-at-a-time if OOM
- [ ] Patch JS: sed replace render.com/localhost URLs
- [ ] Test: `curl -s http://<IP>/api/backend/website/homepage`
- [ ] Test: `curl -s -o /dev/null -w "%{http_code}" http://<IP>/`
- [ ] Backup: `sudo ./backup.sh` (test run)
- [ ] Verify cron: `sudo cat /etc/cron.d/rxsoft`

### Troubleshooting Matrix

| Symptom | Likely Cause | Fix |
|---|---|---|
| MongoDB restarting | Keyfile permissions | `chown 999:999; chmod 400; rm -rf docker volumes` |
| Backend OOM on build | t3.small too small | Use pre-built dist, build one-at-a-time |
| Admin shows blank page | VITE_* not baked in | `sed -i` patch JS, or rebuild with build args |
| 500 on proxy routes | nginx trailing-slash | Use `proxy_pass http://service:port/path/` |
| `git clone` fails | Dir exists | Script now has `rm -rf` before clone |
| Cannot connect to DB | DB not initialized | Check `postgres-init` ran, check DB names |
| S3 backup fails | `s3://` prefix needed | `backup.sh` now uses `S3_PATH` with correct prefix |

---

## Recovery Procedures

### Full Teardown and Redeploy

```bash
# Backup first
ssh -i deployment/terraform/ssh/id_rsa ubuntu@<IP> 'sudo ./deployment/docker/backup.sh'

# Destroy
terraform destroy

# Optionally empty S3 bucket
aws s3 rm s3://rxsoft-postgres-backups-prod --recursive

# Redeploy
terraform apply -auto-approve
```

### Restore from Backup

```bash
# On server
sudo ./deployment/docker/restore.sh list          # list available backups
sudo ./deployment/docker/restore.sh latest         # restore latest
sudo ./deployment/docker/restore.sh rxsoft-20260711_030000.tar.gz  # specific backup
```

### Manual Container Recovery

```bash
# Check all
sudo docker ps -a

# Restart single service
sudo docker compose -f /path/to/compose.yml up -d --no-deps <service>

# Rebuild single service (use pre-built dist)
sudo docker compose -f /path/to/compose.yml build --no-cache <service>
sudo docker compose -f /path/to/compose.yml up -d --no-deps <service>

# View logs
sudo docker logs <container-name> --tail 50
```

### Cloud-init Re-run

```bash
# After updating user_data script
sudo rm -f /var/lib/cloud/instances/*/sem/config_scripts_user
sudo cloud-init clean --logs
sudo cloud-init init
# Or just run the script directly:
sudo bash /var/lib/cloud/instance/scripts/part-001
```

---

## File Reference

| File | Purpose | Last Updated |
|---|---|---|
| `deployment/terraform/cloud-init.sh` | EC2 bootstrap script | Current session |
| `deployment/terraform/main.tf` | Infrastructure as code | Current session |
| `deployment/terraform/variables.tf` | Terraform variables | Current session |
| `deployment/docker/docker-compose.prod.yml` | Production service definitions | Current session |
| `deployment/docker/Dockerfile.rxsoft-backend` | Pre-built dist, no lockfile | Current session |
| `deployment/docker/Dockerfile.rxsoft-admin` | VITE build args, nginx config | Current session |
| `deployment/docker/Dockerfile.rxsoft-identity` | Pre-built dist, no lockfile | Current session |
| `deployment/docker/Dockerfile.rxsoft-lis-backend` | No lockfile (npm install) | Current session |
| `deployment/docker/Dockerfile.conversation-engine` | No lockfile (yarn install) | Current session |
| `deployment/docker/Dockerfile.healthcare-concepts` | No lockfile (yarn install) | Current session |
| `deployment/docker/Dockerfile.healthcare-interop` | No lockfile (npm install) | Current session |
| `deployment/docker/nginx-default.conf` | Nginx proxy config (7 routes) | Current session |
| `deployment/docker/backup.sh` | PostgreSQL + MongoDB + SQLite backup | Current session |

---

## Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-07-11 | Use pre-built dist for backend/identity | Avoid tsc OOM on t3.small; dist is committed to git |
| 2026-07-11 | Remove `--frozen-lockfile` / `npm ci` | Repos don't commit lockfiles |
| 2026-07-11 | VITE_* via build: args not environment: | Vite bakes values at build time |
| 2026-07-11 | nginx trailing-slash proxy_pass | Preserves backend's `/api` global prefix |
| 2026-07-11 | MongoDB keyfile chown 999:999 | Container runs as UID 999, needs read access |
| 2026-07-11 | Swap file on t3.small | Prevents OOM for peak memory usage |
| 2026-07-11 | Cloud-init stays ≤ 16384 bytes | Hard AWS limit for user_data |
| 2026-07-11 | Services run on Docker bridge network | Internal DNS resolution, no IP needed between services |
