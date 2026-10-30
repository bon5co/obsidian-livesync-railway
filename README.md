# obsidian-livesync-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/obsidian-livesync-couchdb-v3521-or-admin?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [Obsidian LiveSync CouchDB template](https://railway.com/deploy/obsidian-livesync-couchdb-v3521-or-admin?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Wrapper image for running [Apache CouchDB](https://couchdb.apache.org/) on
[Railway](https://railway.com) as a sync server for the
[Obsidian Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin.

`ghcr.io/bon5co/obsidian-livesync-railway:latest` — built from `couchdb:3.5.2.1`.

Upstream CouchDB is not modified. This image adds three things Railway needs and one
thing upstream's docs make a manual step.

## 1. Credentials come from the environment, on every boot

This is the whole reason the image exists.

The other published Railway templates in this category all build from one repo,
[`BURNI80/obsidian-livesync-railway`](https://github.com/BURNI80/obsidian-livesync-railway),
whose entrypoint **generates** an admin password on first boot, prints it to the deploy
log, and then on any later boot falls back to a hardcoded literal:

```bash
if $IS_FRESH; then
    export COUCHDB_PASSWORD="$(head -c 24 /dev/urandom | base64 | ...)"
else
    export COUCHDB_PASSWORD="existing"     # <-- literal, on every redeploy
fi
```

The `else` branch rests on the entrypoint's own claim that "Credentials are stored on
the volume." They are not: CouchDB keeps its `[admins]` section in
`/opt/couchdb/etc/local.d/docker.ini`, which lives in the image layer, while the mounted
volume is `/opt/couchdb/data`. So `etc` resets on every redeploy and the stock entrypoint
rewrites the admin from whatever is in the environment — which, on that code path, is the
string `existing`.

Reproduced against their exact image, root-owned volume, `PORT=8080` as Railway injects it:

```
BOOT 1 (fresh):  Admin password: moov9iTIO1LTKgQeKxcCRnKR
                 PUT /obsidian-livesync/note1 as admin -> 201

BOOT 2 (redeploy, same volume):
  original generated password -> 401
  admin:existing              -> 200
  admin:existing reads the vault:
      {"_id":"note1","path":"Private/salary.md","data":"SECRET VAULT CONTENT"}
```

Railway redeploys on a variable change, an image update, or a restart, so this is not an
edge case. After the first redeploy the admin credentials of a public HTTPS endpoint
holding someone's entire Obsidian vault are `admin` / `existing` — a literal published in
a public GitHub repository.

This image never generates a password and has no fallback. `COUCHDB_PASSWORD` is supplied
by the environment every boot; on Railway the template sets it to `${{secret(32)}}`, which
is generated once per deploy, stored as a project variable, and identical on every
subsequent boot. Verified: same password still returns 200 after a redeploy, `admin:existing`
returns 401, and the note survives.

## 2. CouchDB is provisioned at boot

Upstream's `docs/setup_own_server.md` makes provisioning a required step ("2. Run
couchdb-init.sh for initialise") that needs Deno installed and run against the server.
The settings it applies are in
[`utils/couchdb/provision.ts`](https://github.com/vrtmrz/obsidian-livesync/blob/main/utils/couchdb/provision.ts);
all of them are baked into `config/10-livesync.ini` here, and the entrypoint creates the
single-node system databases plus the LiveSync database itself.

Measured on the competing image, which does none of this: `_global_changes` returns **404**
and no vault database exists — their readme sends the deployer to Fauxton to create one by
hand. On this image all four are present on first boot:

```
["_global_changes","_replicator","_users","obsidiannotes"]
```

System databases are created with three idempotent `PUT`s rather than
`POST /_cluster_setup {"action":"enable_single_node"}`, because that call also rewrites
`bind_address` and `port` in the live config and would move the listener off Railway's port
mid-boot.

## 3. `require_valid_user`, without breaking the healthcheck

`provision.ts` sets `chttpd/require_valid_user` and `chttpd_auth/require_valid_user` to
`true`; the competing config sets neither, and its `[chttpd_auth]` section is empty despite
one listing's readme advertising both.

Turning it on naively fails every Railway deploy: the healthcheck is an **unauthenticated**
`GET /_up`, and `require_valid_user` answers it `401`. `require_valid_user_except_for_up`
exists for exactly this and is scoped to `/_up` alone. Verified live:

```
ANON GET /_up  -> 200 {"seeds":{},"status":"ok"}
ANON GET /     -> 401
```

Note on scope: this is defence in depth, not a fix for an exposure. It was worth checking
whether the competing deployment leaves a vault world-readable — it does not. A database
created by an admin in CouchDB 3.x is admin-only by default, and anonymous `GET` of the
database, its documents, `_all_docs` and `_all_dbs` all returned `401` there. The claim was
tested and dropped.

## 4. The port

CouchDB has no `$PORT` support, and on Railway the healthcheck dials the **injected** port
rather than the domain's target port. The entrypoint writes Railway's `$PORT` into
`[chttpd]` before CouchDB starts.

## Environment

| Variable | Default | Notes |
| --- | --- | --- |
| `COUCHDB_PASSWORD` | none — **required** | Admin password. Template sets `${{secret(32)}}`. Never generated in-image. |
| `COUCHDB_SECRET` | none | Session-cookie secret. Template sets `${{secret(32)}}` so `_session` cookies stay valid across a redeploy. |
| `COUCHDB_USER` | `admin` | Baked as an image `ENV`. |
| `LIVESYNC_DATABASE` | `obsidiannotes` | Baked as an image `ENV`. Created at boot. |
| `PORT` | injected by Railway | Written into `[chttpd] port`. |

`COUCHDB_USER` and `LIVESYNC_DATABASE` are baked rather than published as template
variables on purpose: Railway's `templateGenerate` drops a variable default whose value is
a literal, so shipping them as variables would publish them as blank **required** fields on
the deploy form.

Volume mount path: `/opt/couchdb/data`. The stock CouchDB entrypoint runs as root, chowns
the mount to `5984:5984` and then `setpriv`s down, so Railway's root-owned volume needs no
repair here (verified: `5984:5984 /opt/couchdb/data`).
