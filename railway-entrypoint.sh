#!/bin/bash
# Railway wrapper entrypoint for CouchDB as an Obsidian Self-hosted LiveSync server.
#
# Two jobs, in order:
#   1. Bind CouchDB to the port Railway injects (CouchDB ignores $PORT on its own).
#   2. Finish the provisioning that upstream's docs make a mandatory manual step --
#      create the single-node system databases and the LiveSync database -- so the
#      deployer never has to install Deno and run couchdb-init.sh against their
#      own server, and never has to hand-create a database in Fauxton.
#
# Credentials deliberately come from the environment on EVERY boot and are never
# generated here. See README.md: generating one and printing it to the deploy log
# is what breaks the other templates in this category on their second deploy.
set -euo pipefail

LISTEN_PORT="${PORT:-5984}"
LIVESYNC_DATABASE="${LIVESYNC_DATABASE:-obsidiannotes}"
CONF=/opt/couchdb/etc/local.d/10-livesync.ini

# CouchDB has no $PORT support; the port has to be in the config file before boot.
# Appending under the [chttpd] header this file is known to contain.
sed -i "/^\[chttpd\]$/a port = ${LISTEN_PORT}" "$CONF"

echo "[railway] CouchDB ${COUCHDB_VERSION:-?} binding 0.0.0.0:${LISTEN_PORT}"
echo "[railway] admin user: ${COUCHDB_USER:-<unset>} (password from env, not generated)"

# Hand off to the stock entrypoint, which writes [admins] from COUCHDB_USER /
# COUCHDB_PASSWORD, repairs ownership of the mounted data dir as root, and then
# setpriv-drops to the couchdb user. Backgrounded so we can provision once it is up.
/docker-entrypoint.sh couchdb &
COUCHDB_PID=$!

API="http://127.0.0.1:${LISTEN_PORT}"
AUTH="${COUCHDB_USER}:${COUCHDB_PASSWORD}"

ready=false
for _ in $(seq 1 120); do
    if curl -sf -u "$AUTH" "${API}/_up" >/dev/null 2>&1; then
        ready=true
        break
    fi
    # If CouchDB died (bad config, unwritable data dir), stop waiting and surface it.
    kill -0 "$COUCHDB_PID" 2>/dev/null || break
    sleep 1
done

if [ "$ready" = true ]; then
    # The three system databases a single node needs. Upstream creates these via
    # POST /_cluster_setup {"action":"enable_single_node"}; doing it as three PUTs
    # avoids that call's side effect of rewriting bind_address/port in the live
    # config, which would move the listener off Railway's port mid-boot.
    # 201 = created, 412 = already exists. Both fine, so this is redeploy-safe.
    for db in _users _replicator _global_changes; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT "${API}/${db}")
        echo "[railway] system db ${db}: HTTP ${code}"
    done

    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT "${API}/${LIVESYNC_DATABASE}")
    echo "[railway] livesync db ${LIVESYNC_DATABASE}: HTTP ${code}"

    echo "[railway] provisioned. Point the LiveSync plugin at this service's public URL,"
    echo "[railway] database '${LIVESYNC_DATABASE}', user '${COUCHDB_USER}'."
else
    echo "[railway] WARNING: CouchDB did not become ready; skipping provisioning." >&2
fi

wait "$COUCHDB_PID"
