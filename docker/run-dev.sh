#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# ──  SET THESE TO YOUR ACTUAL REPO URLS  ──
GIT_ORG="johnehealthwares"   # ← CHANGE THIS to your GitHub org/username

COMPOSE_FILE="docker-compose.yml"
ALL_SERVICES=("mongodb" "mongo-init" "postgres" "rxsoft-backend" "rxsoft-lis-backend" "conversation-engine" "healthcare-concepts" "healthcare-interop" "rxsoft-identity" "rxsoft-admin" "adminer" "mongo-express")
REPOS=(
  "rxsoft-backend"
  "common-admin"
  "conversation-engine"
  "common-healthcare-resources"
  "healthcare-interoperability-switch"
  "rxsoft-lis-backend"
  "identity"
)

pull_repos() {
  for repo in "${REPOS[@]}"; do
    target="../../$repo"
    if [ -d "$target/.git" ]; then
      echo "  Pulling $repo..."
      (cd "$target" && BRANCH=$(git rev-parse --abbrev-ref HEAD) && git pull origin "$BRANCH" --ff-only)
    else
      echo "  Cloning $repo..."
      git clone "git@github.com:$GIT_ORG/$repo.git" "$target" 2>/dev/null ||
        git clone "https://github.com/$GIT_ORG/$repo.git" "$target"
    fi
  done
}

install_deps() {
  for repo in "${REPOS[@]}"; do
    target="../../$repo"
    if [ -f "$target/package.json" ]; then
      echo "  Installing dependencies: $repo..."
      (cd "$target" && yarn install --immutable --immutable-cache --check-cache 2>/dev/null || yarn install)
    fi
  done
}

if [ "$GIT_ORG" = "your-org" ]; then
  echo "ERROR: Set GIT_ORG at the top of $(basename "$0") to your GitHub org/username."
  exit 1
fi

usage() {
  echo "Usage: $0 [command] [service...]"
  echo ""
  echo "Commands:"
  echo "  start     Start services (no git pull — for cron)"
  echo "    up
        Git pull + install deps + start services (default)"
  echo "  down      Stop and remove all containers"
  echo "  stop      Stop all/specific services (keep containers)"
  echo "  restart   Restart all/specific services"
  echo "  logs      Follow logs from all/specific services"
  echo "  ps        Show container status"
  echo "  pull      Git pull all repos only"
  echo "  install   Install dependencies only (no git pull)"
  echo "  build     Build images (no git pull)"
  echo ""
  echo "Env variables:"
  echo "  ENABLED_SERVICES  Space-separated list of services to start."
  echo "                    Default: all services."
  echo "                    Example: ENABLED_SERVICES=\"postgres mongodb rxsoft-backend\""
  echo ""
  echo "Examples:"
  echo "  $0                                                   Pull + start everything"
  echo "  $0 up rxsoft-backend                                 Start only backend"
  echo "  ENABLED_SERVICES=\"postgres rxsoft-backend\" $0        Start specific services"
  echo "  $0 start                                             Start without git pull (cron)"
  echo "  $0 stop rxsoft-backend                               Stop specific service"
  echo "  $0 down                                              Tear down everything"
  echo "  $0 logs rxsoft-admin                                 Follow admin logs"
  exit 1
}

cmd="${1:-up}"
shift 2>/dev/null || true

# Resolve which services to operate on and build profile flags
resolve_services() {
  if [ -n "${ENABLED_SERVICES:-}" ] && [ $# -eq 0 ]; then
    echo "$ENABLED_SERVICES"
  elif [ $# -gt 0 ]; then
    echo "$*"
  else
    echo "${ALL_SERVICES[*]}"
  fi
}

to_profiles() {
  for svc in $1; do echo "--profile $svc"; done
}

prompt_for_tools() {
  TOOL_FLAGS=""
  if [ -t 0 ]; then
    echo ""
    echo -n "Include optional tools (adminer, mongo-express)? [y/N] "
    read -r -t 10 -n 1 answer || true
    echo ""
    case "${answer:-n}" in
      y|Y) TOOL_FLAGS="--profile adminer --profile mongo-express" ;;
    esac
  fi
}

case "$cmd" in
  start)
    prompt_for_tools
    SERVICES=$(resolve_services "$@")
    PROFILES=$(to_profiles "$SERVICES")" $TOOL_FLAGS"
    echo "Starting dev environment: $SERVICES"
    # shellcheck disable=SC2086
    docker compose -f "$COMPOSE_FILE" $PROFILES up -d
    echo "Started."
    ;;
  up)
    if [ $# -eq 0 ]; then
      prompt_for_tools
      echo "Pulling latest code..."
      pull_repos
      echo "Installing dependencies..."
      install_deps
    fi
    SERVICES=$(resolve_services "$@")
    PROFILES=$(to_profiles "$SERVICES")" $TOOL_FLAGS"
    echo "Starting dev environment: $SERVICES"
    # shellcheck disable=SC2086
    docker compose -f "$COMPOSE_FILE" $PROFILES up -d
    echo "Done. Run '$0 logs' to follow output."
    ;;
  down)
    docker compose -f "$COMPOSE_FILE" down "$@"
    ;;
  stop)
    docker compose -f "$COMPOSE_FILE" stop "$@"
    ;;
  restart)
    docker compose -f "$COMPOSE_FILE" restart "$@"
    ;;
  logs)
    docker compose -f "$COMPOSE_FILE" logs -f "$@"
    ;;
  ps)
    docker compose -f "$COMPOSE_FILE" ps
    ;;
  pull)
    pull_repos
    ;;
  install)
    install_deps
    ;;
  build)
    docker compose -f "$COMPOSE_FILE" build "$@"
    ;;
  *)
    usage
    ;;
esac
