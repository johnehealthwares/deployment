#!/bin/bash
set -e

# Create databases if they don't exist
for db in rxsoft lis healthcare-concepts identity; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    SELECT 'CREATE DATABASE $db'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
EOSQL
  echo "Database '$db' ready"
done
