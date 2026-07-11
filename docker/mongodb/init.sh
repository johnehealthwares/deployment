#!/bin/bash
set -e

until mongosh --host mongodb --username admin --password admin123 \
  --authenticationDatabase admin --quiet \
  --eval 'db.adminCommand({ ping: 1 }).ok' | grep 1
do
  echo "Waiting for MongoDB..."
  sleep 2
done

mongosh --host mongodb --username admin --password admin123 \
  --authenticationDatabase admin <<'EOF'
try {
  rs.status();
} catch (e) {
  rs.initiate({
    _id: "rs0",
    members: [{ _id: 0, host: "mongodb:27017" }]
  });
}
EOF

until mongosh --host mongodb --username admin --password admin123 \
  --authenticationDatabase admin --quiet \
  --eval 'db.hello().isWritablePrimary' | grep true
do
  echo "Waiting for PRIMARY..."
  sleep 1
done

echo "Replica set ready."