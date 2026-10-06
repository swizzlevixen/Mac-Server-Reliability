#!/bin/zsh
# nas-early-mount.sh
# https://github.com/swizzlevixen/Mac-Server-Reliability
#
# Mounts the NAS shares at boot, before anyone logs in, as the server's normal user,
# at the usual /Volumes/<share> paths. Apps that macOS reopens at login (or that
# start before AutoMounter) then find their files already there.
#
# Mounts look exactly like the ones AutoMounter or Finder make: owned by the user,
# same paths. AutoMounter keeps running and handles reconnects after NAS blips.
# Runs once at boot from a LaunchDaemon (root); safe to run again by hand.
#
# Config: /etc/nas-early-mount.conf (root:wheel, mode 600; it holds the NAS password).
# See nas-early-mount.conf.example.

CONF=${NAS_EARLY_MOUNT_CONF:-/etc/nas-early-mount.conf}
LOG=/var/log/nas-early-mount.log
WAIT_SECS=300

touch "$LOG" 2>/dev/null && chmod 644 "$LOG" 2>/dev/null   # readable without sudo
log() { print -r -- "$(date +"%Y-%m-%d %H:%M:%S %Z") - nas-early-mount: $1" | tee -a "$LOG"; }

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -r $CONF ]] || { log "config not found: $CONF"; exit 1; }
source "$CONF"

# Wait for the NAS to answer on the SMB port (the network may not be up yet at boot)
host=${NAS_HOST%%._smb._tcp.local*}; [[ $host == $NAS_HOST ]] || host="$host.local"
start=$SECONDS
until nc -z -G 2 "$host" 445 >/dev/null 2>&1; do
    if (( SECONDS - start >= WAIT_SECS )); then
        log "NAS $host not reachable after ${WAIT_SECS}s; leaving the mounts to AutoMounter"; exit 1
    fi
    sleep 3
done
log "NAS reachable after $(( SECONDS - start ))s"

for entry in $SHARES; do
    share=${entry%%:*}; name=${entry#*:}
    mp="/Volumes/$name"
    if mount | grep -q " on $mp ("; then log "$share already mounted at $mp"; continue; fi
    if [[ -e $mp ]]; then
        # Never mount over something: only reuse an empty folder
        if [[ ! -d $mp || -n $(ls -A "$mp" 2>/dev/null) ]]; then log "$mp exists and isn't an empty folder; skipped $share"; continue; fi
    else
        mkdir "$mp" || { log "couldn't create $mp"; continue; }
    fi
    chown "${MOUNT_USER}:staff" "$mp"; chmod 755 "$mp"
    # Mount as the user, so it's theirs, just like a Finder or AutoMounter mount
    if err=$(sudo -u "$MOUNT_USER" /sbin/mount_smbfs "//${NAS_USER}:${NAS_PASS_ENC}@${NAS_HOST}/${share}" "$mp" 2>&1); then
        log "mounted $share at $mp"
    else
        log "FAILED to mount $share at $mp: $err"
        rmdir "$mp" 2>/dev/null    # leave no empty folder behind for AutoMounter to trip over
    fi
done
