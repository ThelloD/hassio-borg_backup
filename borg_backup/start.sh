#!/usr/bin/env bashio
export BORG_REPO="ssh://$(bashio::config 'user')@$(bashio::config 'host'):$(bashio::config 'port')/$(bashio::config 'path')"
export BORG_PASSPHRASE="$(bashio::config 'passphrase')"
export BORG_BASE_DIR="/data"
export BORG_RSH="ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/data/known_hosts"

tmpdir=$(mktemp /backup/hassio-borg-XXXXXXXX)
PUBLIC_KEY=`cat ~/.ssh/id_ed25519.pub`

trap 'rm -rf "$tmpdir"' EXIT

bashio::log.info "A public/private key pair was generated for you."
bashio::log.notice "Please use this public key on the backup server:"
bashio::log.notice "${PUBLIC_KEY}"

if [ ! -f /data/known_hosts ]; then
   bashio::log.info "Running for the first time, acquiring host key and storing it in /data/known_hosts."
   ssh-keyscan -p $(bashio::config 'port') "$(bashio::config 'host')" > /data/known_hosts \
     || bashio::exit.nok "Could not acquire host key from backup server."
fi

bashio::log.info 'Trying to initialize the Borg repository.'
/usr/bin/borg init -e repokey || true

if [ "$(date +%u)" = 7 ]; then
  bashio::log.info 'Checking archive integrity. (Today is Sunday.)'
  /usr/bin/borg check \
    || bashio::exit.nok "Could not check archive integrity."
fi

if [ "$(bashio::config 'deduplicate_archives')" ]; then
  for i in /backup/*.tar; do
    archive_name=$(tar xf "$i" ./backup.json -O | jq -r '[.name, .date] | join("-")')

    if [ -z "$archive_name" ]; then
      bashio::log.error "Impossible to get backup info for $archive_name." \
        "Ensure it's a vaild backup file or disable deduplicate_archives option"
      continue
    fi

    # Handle this manually till we can't use borg import-tar
    tardir="$tmpdir/$(basename "$i" .tar)"
    mkdir "$tardir"
    tar xvf "$i" -C "$tardir"
    bashio::log.info "Uploading backup $i as $archive_name."
    /usr/bin/borg create $(bashio::config 'create_options') \
      "::$(bashio::config 'archive')-$archive_name" "$tardir" \
      || bashio::exit.nok "Could not upload backup $i."
  done
else
  bashio::log.info "Uploading backup."
    /usr/bin/borg create $(bashio::config 'create_options') \
      "::$(bashio::config 'archive')-{utcnow}" /backup \
      || bashio::exit.nok "Could not upload backup."
fi

bashio::log.info 'Checking backups.'
borg check --archives-only -P "$(bashio::config 'archive')"

bashio::log.info 'Pruning old backups.'
/usr/bin/borg prune $(bashio::config 'prune_options') --list \
  -P $(bashio::config 'archive') \
  || bashio::exit.nok "Could not prune backups."

local_snapshot_config=$(bashio::config 'local_snapshot')
local_snapshot=$((local_snapshot_config + 1))

if [ $local_snapshot -gt 1 ]; then
  bashio::log.info 'Cleaning old snapshots.'
  cd /backup
  ls -tp | grep -v '/$' | tail -n +$local_snapshot | tr '\n' '\0' | xargs -0 rm --
fi

bashio::log.info 'Finished.'
bashio::exit.ok
