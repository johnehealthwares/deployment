#!/usr/bin/env bash
#──────────────────────────────────────────────────────────────
# terraform-apply.sh — wrapper around terraform apply that
# automatically updates .ec2-ip and handles user_data changes
# by tainting the instance to force cloud-init re-run.
#
# Usage:
#   ./terraform-apply.sh [-auto-approve]    # apply with IP update
#   ./terraform-apply.sh --plan             # plan only (dry run)
#──────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

PLAN_ONLY=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --plan) PLAN_ONLY=true ;;
    *) ARGS+=("$arg") ;;
  esac
done

if $PLAN_ONLY; then
  echo "=== Plan only ==="
  terraform plan "${ARGS[@]}"
  exit 0
fi

# Check if user_data changed from the current deployment
USER_DATA_CHANGED=false
if terraform plan -no-color 2>&1 | grep -q "user_data will be updated"; then
  echo "--- user_data changed → tainting instance for full reprovision ---"
  terraform taint aws_instance.postgres 2>/dev/null || true
  USER_DATA_CHANGED=true
fi

echo "=== Applying terraform ==="
terraform apply "${ARGS[@]}" 2>&1

NEW_IP=$(terraform output -raw public_ip 2>/dev/null || true)
if [ -n "$NEW_IP" ]; then
  echo "$NEW_IP" > ../.ec2-ip
  echo "--- Updated .ec2-ip → $NEW_IP ---"
fi

if $USER_DATA_CHANGED; then
  echo ""
  echo "⚠️  Instance was tainted due to cloud-init changes."
  echo "   Cloud-init will run on next boot. Wait ~5 min before calling dns-update.sh."
fi

echo "=== Done ==="
