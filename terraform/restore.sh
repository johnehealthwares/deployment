#!/bin/bash
#──────────────────────────────────────────────────────────────
# DEPRECATED — use docker/restore.sh instead
# docker/restore.sh supports: list, pull from S3, restore PG + MongoDB
#──────────────────────────────────────────────────────────────

FILE=$1

docker exec -i \
$(docker ps -q -f name=postgres) \
psql \
-U rxsoft \
-d rxsoft \
< "$FILE"