#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# RxSoft — SSH into the EC2 instance
# Usage: ./ssh.sh [command...]
#   ./ssh.sh                          # interactive shell
#   ./ssh.sh sudo docker ps           # run command
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"
IP_FILE=".ec2-ip"
# Cache IP from terraform (refreshes if older than 1 hour)
if [ ! -f "$IP_FILE" ] || [ "$(find "$IP_FILE" -mmin +60)" ]; then
  terraform -chdir=terraform output -raw public_ip > "$IP_FILE" 2>/dev/null || true
fi
IP=$(cat "$IP_FILE" 2>/dev/null || terraform -chdir=terraform output -raw public_ip 2>/dev/null)
exec ssh -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -i terraform/ssh/id_rsa \
        -o ConnectTimeout=10 \
        "ubuntu@$IP" "$@"
