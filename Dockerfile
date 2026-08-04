FROM couchdb:3.5.2.1

# curl is needed by the entrypoint to provision the databases once CouchDB is up,
# and by anyone debugging the running container. Not in the base image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# The LiveSync server settings, taken from upstream's own provision.ts.
COPY config/10-livesync.ini /opt/couchdb/etc/local.d/10-livesync.ini

# Baked, NOT published as template variables. A template variable whose default is
# a literal is dropped by templateGenerate and publishes as a blank REQUIRED field,
# so shipping these as variables would put two settings CouchDB already knows onto
# the deploy form. Only values that genuinely belong to the deployer stay variables,
# and those are expressions (${{secret(32)}}), whose defaults do survive.
ENV COUCHDB_USER=admin
ENV LIVESYNC_DATABASE=obsidiannotes

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

EXPOSE 5984

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
