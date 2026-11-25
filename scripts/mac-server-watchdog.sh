#!/bin/zsh
# mac-server-watchdog.sh
# https://github.com/swizzlevixen/Mac-Server-Reliability
#
# Keeps a Mac server's apps and network shares running. Replaces the earlier
# "Startup Apps and Databases" AppleScript + monitor-network-drives.sh pair.
#
# Run every 60 seconds (and at login) by a LaunchAgent:
#   LaunchAgents/com.admin.mac-server-watchdog.plist
# Configuration lives in a separate file, so this script has nothing
# machine-specific in it:
#   ~/.config/mac-server-watchdog.conf   (see watchdog.conf.example)
#
# What it does on every run:
#   - Checks each network share; gives your automounter a grace period, then remounts.
#   - Checks each service in config order. A service starts only when the shares it
#     needs are mounted; one missing share doesn't hold up unrelated apps.
#   - For services with a health URL, actually requests it; a running-but-hung app
#     is restarted after a few consecutive failures.
#   - Rate-limits restarts, so a broken app can't restart-loop.
#   - Shows self-closing dialogs (queued, one at a time) for anyone watching the screen.
#   - Sends notifications only on state changes (down / back / gave up), plus a
#     summary once per boot. (After a restart planned by weekly-restart.sh, the summary
#     is notified only if something didn't come up.)
#
# Test without touching anything:  DRY_RUN=1 zsh mac-server-watchdog.sh

setopt NULL_GLOB

# ---------- defaults (override any of these in the config file) ----------
SERVER_NAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
NAS_HOST=""                     # e.g. mynas.local — used to remount shares
SHARES=()                       # share names as mounted under /Volumes
SERVICES=()                     # "key|Label|app|required shares|health URL" — see example config
QUIT_WHEN_SHARE_MISSING=()      # service keys to quit if a required share stays missing
DEVONTHINK_DATABASES=()         # databases to keep open in DEVONthink (optional)
DEVONTHINK_DB_DIR="$HOME/Databases"
LOG_FILE="$HOME/Library/Logs/mac-server-events.log"
NOTIFY_CMD="/Applications/pushover-notify.sh"   # called as: NOTIFY_CMD "Title" "Message" [priority]
STATE="$HOME/Library/Application Support/mac-server-watchdog"
SHARE_GRACE=180                 # seconds a share may be missing before we act
LAUNCH_GRACE=300                # seconds after a launch before health checks count
UNHEALTHY_LIMIT=3               # consecutive failed health checks before a restart
MAX_RESTARTS=3                  # per service per hour, then give up and notify
BOOT_WINDOW=900                 # "startup" dialogs + boot summary within this long after boot
DIALOG_SECONDS=4                # how long each dialog stays up
MIN_FREE_GB=20                  # warn when the startup disk has less free space than this
MEMORY_PRESSURE_RUNS=10         # warn after this many consecutive runs under memory pressure
MEMORY_ALERT_LEVEL=2            # pressure level that counts: 2 = warning, 4 = critical only
HEARTBEAT_URL=""                # e.g. an Uptime Kuma push URL; pinged after every completed run
LOCAL_MEDIA_GUARD=()            # local folders that should stay empty because the real ones are on a share
LOCAL_MEDIA_GUARD_SKIP=()       # names to skip inside guarded folders, e.g. "*.musiclibrary" "*.movpkg"
PREF_CHECKS=()                  # "domain|key|expected value" — alert if an app setting drifts
MUSIC_SAMPLE_ROOT=""            # e.g. /Volumes/Plex/Music — once a day, check sampled Music tracks live here
MUSIC_SAMPLE_SIZE=20            # how many random tracks to sample
DRY_RUN=${DRY_RUN:-0}

CONF=${WATCHDOG_CONF:-$HOME/.config/mac-server-watchdog.conf}
if [[ ! -r $CONF ]]; then
    echo "mac-server-watchdog: config not found: $CONF (copy watchdog.conf.example there)" >&2
    exit 1
fi
source "$CONF"

# Errors go to the event log. (launchd itself can't open files in ~/Desktop, so this
# is done here rather than with StandardErrorPath in the LaunchAgent.)
(( DRY_RUN )) || exec >>"$LOG_FILE" 2>&1

mkdir -p "$STATE" "${LOG_FILE:h}"

# One run at a time; a lock older than 10 min is stale.
LOCK="$STATE/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    [[ -n $(find "$LOCK" -maxdepth 0 -mmin +10) ]] || exit 0
    rmdir "$LOCK"; mkdir "$LOCK" || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

now=$(date +%s)
boot=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ,)
BOOTING=false
[[ ! -f "$STATE/boot-$boot" ]] && (( now - boot < BOOT_WINDOW )) && BOOTING=true
problems=()

# ---------- helpers ----------
log() {
    print -r -- "$(date +"%Y-%m-%d %H:%M:%S %Z") - watchdog: $1" >> "$LOG_FILE"
    (( DRY_RUN )) && print -r -- "watchdog: $1"
}

# Synchronous on purpose: launchd kills a job's leftover background children when it exits.
notify() {
    if (( DRY_RUN )); then print -r -- "(dry run) notify: $1"; return; fi
    perl -e 'alarm shift; exec @ARGV' 20 "$NOTIFY_CMD" "$SERVER_NAME" "$1" "${2:-0}" >/dev/null 2>&1 \
        || log "notification failed: $1"
}

with_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }
st_get()       { cat "$STATE/$1" 2>/dev/null; }
st_set()       { print -r -- "$2" > "$STATE/$1"; }
running()      { pgrep -qf "^$1"; }
http_ok()      { curl -fsS -m 5 -o /dev/null "$1" 2>/dev/null; }
share_ok()     { mount | grep -q " on /Volumes/$1 ("; }
# Where a share is mounted when its own name was taken at the time, e.g. /Volumes/name-1.
# That happens when two things mount it at the same moment (a login item and an automounter).
share_astray() { mount | sed -n "s|^//.*/$1 on \\(/Volumes/$1-[0-9][0-9]*\\) (.*|\\1|p" | head -1; }

# Self-closing dialog for every watchdog action; never blocks the watchdog.
# Messages are queued and shown one at a time by a single detached runner —
# simultaneous dialogs stack on top of each other and hide all but the last.
# (AbandonProcessGroup in the LaunchAgent keeps the runner alive after this run exits.)
dialog() {
    local title="$SERVER_NAME watchdog"; $BOOTING && title="$SERVER_NAME startup"
    if (( DRY_RUN )); then print -r -- "(dry run) dialog [$title]: $1"; return; fi
    print -r -- "$title|$1" >> "$STATE/dialog-queue"
    mkdir "$STATE/dialog-runner" 2>/dev/null || return 0
    (
        while true; do
            line=$(head -1 "$STATE/dialog-queue" 2>/dev/null)
            [[ -z $line ]] && break
            sed -i '' 1d "$STATE/dialog-queue"
            with_timeout 15 osascript -e "display dialog \"${line#*|}\" with title \"${line%%|*}\" buttons {\"OK\"} default button 1 giving up after $DIALOG_SECONDS" >/dev/null 2>&1
        done
        rmdir "$STATE/dialog-runner"
    ) &!
}

mark_down() {   # key, message — notify once per outage (held back during boot; the summary covers it)
    problems+=("$2")
    [[ -f "$STATE/down-$1" ]] && return
    st_set "down-$1" "$now"
    log "DOWN $1: $2"
    $BOOTING || notify "⚠️ $2" 0
}

mark_up() {     # key, label — notify once when an outage ends
    rm -f "$STATE/fail-$1"
    [[ -f "$STATE/down-$1" ]] || return
    local since=$(st_get "down-$1"); rm -f "$STATE/down-$1"
    log "RECOVERED $1"
    $BOOTING || notify "✅ $2 is back (was down $(( (now - since + 59) / 60 )) min)" 0
}

may_restart() { # key, label — rate limit restarts (starts during boot don't count)
    $BOOTING && return 0
    local f="$STATE/restarts-$1"; touch "$f"
    local recent=$(awk -v c=$((now - 3600)) '$1 > c' "$f" | wc -l | tr -d ' ')
    if (( recent >= MAX_RESTARTS )); then
        if [[ ! -f "$STATE/gaveup-$1" ]]; then
            touch "$STATE/gaveup-$1"; log "GAVE UP on $1 after $MAX_RESTARTS restarts in an hour"
            notify "🛑 $2: $MAX_RESTARTS restarts in the last hour didn't fix it. Pausing restarts; needs a look." 1
        fi
        return 1
    fi
    rm -f "$STATE/gaveup-$1"
    echo "$now" >> "$f"
    return 0
}

# Find an app WITHOUT launching it. Don't use AppleScript's `path to application id`
# for this: it launches the app as a side effect, which breaks the startup order.
# The app is given as a bundle id (com.example.App) or a creator code (creator:DNtp);
# creator codes survive renames like "DEVONthink 3" -> "DEVONthink".
resolve_app() { # key, app  → sets APP_PATH, APP_BID, APP_EXE
    local key=$1 loc=$2 app_path field want a   # not "path": in zsh that is tied to $PATH
    app_path=$(st_get "app-$key")
    if [[ -z $app_path || ! -d $app_path ]]; then
        app_path=""
        if [[ $loc == creator:* ]]; then field=CFBundleSignature; want=${loc#creator:}
        else field=CFBundleIdentifier; want=$loc; fi
        for a in /Applications/*.app /Applications/*/*.app /System/Applications/*.app \
                 /System/Applications/Utilities/*.app "$HOME"/Applications/*.app; do
            [[ $(defaults read "$a/Contents/Info.plist" $field 2>/dev/null) == "$want" ]] && { app_path=$a; break; }
        done
        [[ -n $app_path ]] && st_set "app-$key" "$app_path"
    fi
    [[ -n $app_path ]] || return 1
    APP_PATH=$app_path
    APP_BID=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
    APP_EXE="$app_path/Contents/MacOS/$(defaults read "$app_path/Contents/Info.plist" CFBundleExecutable 2>/dev/null)"
}

launch_app() {  # path, label — a failed launch is logged and notified, not silent
    if (( DRY_RUN )); then log "(dry run) would launch $2"; return; fi
    local err
    if ! err=$(open -g "$1" 2>&1); then
        log "FAILED to launch $2: $err"
        notify "🛑 Couldn't launch $2: $err" 1
    fi
}

quit_app() {    # bundle id, executable, label — graceful quit first, then escalate
    if (( DRY_RUN )); then log "(dry run) would quit $3"; return; fi
    with_timeout 30 osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1
    for i in {1..15}; do running "$2" || return 0; sleep 2; done
    pkill -f "^$2"; sleep 3
    running "$2" && pkill -9 -f "^$2"
    return 0
}

# Keep one app running (and, if given, answering on its health URL).
check_app() {   # key, label, [health url]   (uses APP_PATH / APP_BID / APP_EXE)
    local key=$1 label=$2 url=$3
    local started=$(st_get "started-$key"); started=${started:-0}

    if ! running "$APP_EXE"; then
        (( now - started < 60 )) && return          # just launched, give it a moment
        mark_down "$key" "$label was not running"
        may_restart "$key" "$label" || return
        if $BOOTING; then dialog "Starting $label…"; else dialog "$label wasn't running. Starting it…"; fi
        log "starting $label"
        launch_app "$APP_PATH" "$label"
        st_set "started-$key" "$now"
        $BOOTING && print -r -- "$label" >> "$STATE/boot-started-$boot"
        return
    fi

    if [[ -z $url ]] || http_ok "$url"; then
        mark_up "$key" "$label"
        return
    fi

    (( now - started < LAUNCH_GRACE )) && return     # still starting up
    local n=$(( $(st_get "fail-$key" || echo 0) + 1 )); st_set "fail-$key" "$n"
    (( n < UNHEALTHY_LIMIT )) && return
    mark_down "$key" "$label is running but not answering at $url"
    may_restart "$key" "$label" || return
    dialog "$label isn't responding. Restarting it…"
    log "restarting $label (unresponsive)"
    quit_app "$APP_BID" "$APP_EXE" "$label"
    launch_app "$APP_PATH" "$label"
    st_set "started-$key" "$now"
    rm -f "$STATE/fail-$key"
}

# Keep the configured DEVONthink databases open (DEVONthink's web server only
# serves open databases). Addressed by creator code, so any DEVONthink version works.
devonthink_databases() {
    (( ${#DEVONTHINK_DATABASES} )) || return
    local open_dbs db
    open_dbs=$(with_timeout 20 osascript -e 'tell application id "DNtp" to get name of databases' 2>/dev/null)
    [[ -n $open_dbs ]] || return
    for db in $DEVONTHINK_DATABASES; do
        [[ ", $open_dbs, " == *", $db, "* ]] && continue
        if $BOOTING; then dialog "Opening DEVONthink database $db…"; else dialog "DEVONthink database $db was closed. Reopening it…"; fi
        log "opening DEVONthink database $db"
        (( DRY_RUN )) || with_timeout 60 osascript -e "tell application id \"DNtp\" to open database \"$DEVONTHINK_DB_DIR/$db.dtBase2\"" >/dev/null 2>&1
    done
}

# ---------- network shares ----------
if $BOOTING && [[ ! -f "$STATE/boot-dialog-$boot" ]]; then
    touch "$STATE/boot-dialog-$boot"
    rm -f "$STATE/dialog-queue"; rmdir "$STATE/dialog-runner" 2>/dev/null   # leftovers from before the reboot
    dialog "$SERVER_NAME is starting its services. Checking network shares…"
fi

for s in $SHARES; do
    if share_ok "$s"; then
        rm -f "$STATE/missing-$s"
        mark_up "share-$s" "Network share $s"
        continue
    fi
    # Mounted under another name: apps look for /Volumes/$s, and Finder won't mount a share
    # twice, so move it. Without force: if something has files open there, say so instead.
    what="unmounted"
    astray=$(share_astray "$s")
    if [[ -n $astray ]]; then
        if (( DRY_RUN )) || with_timeout 30 diskutil unmount "$astray" >/dev/null 2>&1; then
            log "share $s was mounted as $astray; mounting it as /Volumes/$s"
            (( DRY_RUN )) || [[ -z $NAS_HOST ]] || with_timeout 60 osascript -e "tell application \"Finder\" to mount volume \"smb://$NAS_HOST/$s\"" >/dev/null 2>&1
            continue
        fi
        what="mounted as $astray, which is in use and can't be moved,"
    fi
    first=$(st_get "missing-$s")
    [[ -z $first ]] && { first=$now; st_set "missing-$s" "$now"; log "share $s not mounted${astray:+ (it is mounted as $astray)}"; }
    if (( now - first >= SHARE_GRACE )); then
        mark_down "share-$s" "Network share $s $what for $(( (now - first) / 60 )) min"
        if [[ -n $NAS_HOST ]]; then
            dialog "Network share $s has been missing for $(( (now - first) / 60 )) min. Remounting it…"
            log "mounting smb://$NAS_HOST/$s"
            (( DRY_RUN )) || with_timeout 60 osascript -e "tell application \"Finder\" to mount volume \"smb://$NAS_HOST/$s\"" >/dev/null 2>&1
        fi
    elif $BOOTING && [[ ! -f "$STATE/boot-wait-$s-$boot" ]]; then
        touch "$STATE/boot-wait-$s-$boot"; dialog "Waiting for network share $s…"
    fi
done

# ---------- services, in config order ----------
for entry in $SERVICES; do
    IFS='|' read -r key label app needs url <<< "$entry"
    if ! resolve_app "$key" "$app"; then
        mark_down "$key" "$label: app not found ($app)"
        continue
    fi

    missing=()
    for s in ${=needs}; do share_ok "$s" || missing+=("$s"); done

    if (( ${#missing} )); then
        # Don't start (or restart) an app while its data isn't there.
        if running "$APP_EXE"; then
            # Optionally stop it if a required share has been gone past the grace period.
            if (( ${QUIT_WHEN_SHARE_MISSING[(Ie)$key]} )); then
                for s in $missing; do
                    first=$(st_get "missing-$s")
                    if (( now - ${first:-$now} >= SHARE_GRACE )); then
                        dialog "Share $s is missing. Quitting $label until it's back…"
                        log "quitting $label (share $s missing)"
                        quit_app "$APP_BID" "$APP_EXE" "$label"
                        break
                    fi
                done
            fi
        else
            problems+=("$label waiting for share(s) ${(j:, :)missing}")
        fi
        continue
    fi

    check_app "$key" "$label" "$url"
    [[ $app == creator:DNtp ]] && running "$APP_EXE" && devonthink_databases
done

# ---------- system health ----------
# Free space as Finder counts it: includes purgeable space (local Time Machine
# snapshots, caches) that macOS frees on demand. Fall back to df's strict figure.
free_gb=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); Math.floor($.NSURL.fileURLWithPath("/System/Volumes/Data").resourceValuesForKeysError(["NSURLVolumeAvailableCapacityForImportantUsageKey"], null).objectForKey("NSURLVolumeAvailableCapacityForImportantUsageKey").js / 1073741824)' 2>/dev/null)
[[ $free_gb == <-> ]] || free_gb=$(df -g /System/Volumes/Data | awk 'NR==2 {print $4}')
if [[ -n $free_gb ]] && (( free_gb < MIN_FREE_GB )); then
    mark_down disk "Startup disk is almost full: ${free_gb} GB free"
else
    mark_up disk "Startup disk space"
fi

# NAS traffic should go over a wired port. macOS can quietly move Wi-Fi above Ethernet
# in the service order, and then SMB and Time Machine run over Wi-Fi.
if [[ -n $NAS_HOST ]]; then
    wifi_dev=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/ {getline; print $2}')
    nas_ip=$(dscacheutil -q host -a name "$NAS_HOST" | awk '/^ip_address/ {print $2; exit}')
    nas_if=${nas_ip:+$(route -n get "$nas_ip" 2>/dev/null | awk '/interface:/ {print $2}')}
    if [[ -n $wifi_dev && $nas_if == $wifi_dev ]]; then
        mark_down nas-route "Traffic to $NAS_HOST is going over Wi-Fi ($wifi_dev) instead of Ethernet. Check the network service order."
    elif [[ -n $nas_if ]]; then
        mark_up nas-route "Traffic to $NAS_HOST over Ethernet"
    fi
fi

# Folders that should stay empty, such as Music's default local media folder when the
# real media folder is on a share. If an app starts before the share is mounted (after
# a software update restart, say), it can quietly fall back to its local default, and
# new files landing here are the first sign of it. Files already here when the guard
# was first set up are ignored.
if (( ${#LOCAL_MEDIA_GUARD} )); then
    [[ -f "$STATE/guard-baseline" ]] || touch "$STATE/guard-baseline"
    prune=(); for n in $LOCAL_MEDIA_GUARD_SKIP; do prune+=(${prune:+-o} -name "$n"); done
    (( ${#prune} )) && prune=('(' $prune ')' -prune -o)
    stray=("${(@f)$(find $LOCAL_MEDIA_GUARD $prune \
        -type f ! -name '.*' -Bnewer "$STATE/guard-baseline" -print 2>/dev/null)}")
    stray=(${stray:#})
    if (( ${#stray} )); then
        mark_down local-media "${#stray} new file(s) in a folder that should stay empty, e.g. ${stray[1]}. An app may have lost its folder on the share; check its settings (Music › Settings › Files)."
    else
        mark_up local-media "Local media folder guard"
    fi
fi

# App settings that must not drift, such as Music's media folder, which macOS can reset
# to the local default if Music starts before its share is mounted. Reads the plist file
# itself: under launchd, `defaults read` can't see other apps' settings and says "unset".
for entry in $PREF_CHECKS; do
    IFS='|' read -r domain pkey want <<< "$entry"
    have=$(plutil -extract "$pkey" raw -o - "$HOME/Library/Preferences/$domain.plist" 2>/dev/null)
    if [[ $have != $want ]]; then
        mark_down "pref-$domain-$pkey" "$domain $pkey is '${have:-unset}', expected '$want'. Check the app's settings."
    else
        mark_up "pref-$domain-$pkey" "$domain $pkey"
    fi
done

# Once a day, ask Music where a random sample of its tracks are, and check each file
# exists under MUSIC_SAMPLE_ROOT. Cloud-only tracks (no file) are skipped. Only runs
# while the share is mounted and Music is already running; it never launches Music.
if [[ -n $MUSIC_SAMPLE_ROOT ]] && share_ok "${${MUSIC_SAMPLE_ROOT#/Volumes/}%%/*}" \
    && pgrep -qx Music && [[ -z $(find "$STATE/music-sample" -mmin -1440 2>/dev/null) ]]; then
    locs=$(with_timeout 120 osascript <<EOF 2>/dev/null
tell application id "com.apple.Music"
    set n to count file tracks of library playlist 1
    set out to {}
    repeat $MUSIC_SAMPLE_SIZE times
        try
            set loc to location of file track (random number from 1 to n) of library playlist 1
            if loc is not missing value then set end of out to POSIX path of loc
        end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    return out as text
end tell
EOF
)
    if [[ -n $locs ]]; then
        touch "$STATE/music-sample"
        bad=()
        for p in "${(@f)locs}"; do
            [[ $p == $MUSIC_SAMPLE_ROOT/* && -e $p ]] || bad+=("$p")
        done
        log "music sample: $(( ${#${(@f)locs}} - ${#bad} )) of ${#${(@f)locs}} tracks OK"
        if (( ${#bad} )); then
            mark_down music-sample "${#bad} of ${#${(@f)locs}} sampled Music tracks are missing or outside $MUSIC_SAMPLE_ROOT, e.g. ${bad[1]}"
        else
            mark_up music-sample "Music track locations"
        fi
    fi
fi

# 1 = normal, 2 = warning, 4 = critical
pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
if (( ${pressure:-1} >= MEMORY_ALERT_LEVEL )); then
    runs=$(( $(st_get pressure-runs) + 1 )); st_set pressure-runs "$runs"
    if (( runs >= MEMORY_PRESSURE_RUNS )) && [[ ! -f "$STATE/down-memory" ]]; then
        # Name the biggest users (top's MEM includes compressed memory), so the alert says what to look at
        hogs=$(top -l 1 -o mem -n 3 -stats mem,command | tail -3 \
            | awk '{m=$1; $1=""; sub(/^ /,""); printf "%s%s %s", (NR>1 ? ", " : ""), $0, m}')
        mark_down memory "Memory pressure has been high for $runs min (swap used: $(sysctl -n vm.swapusage | awk '{print $6}'); top users: $hogs)"
    fi
else
    rm -f "$STATE/pressure-runs"
    mark_up memory "Memory pressure"
fi

# ---------- boot summary: once per boot, when everything is up or the window closes ----------
if $BOOTING && [[ ! -f "$STATE/boot-$boot" ]]; then
    all_up=true
    for entry in $SERVICES; do
        IFS='|' read -r key label app needs url <<< "$entry"
        resolve_app "$key" "$app" && running "$APP_EXE" || { all_up=false; break; }
        [[ -z $url ]] || http_ok "$url" || { all_up=false; break; }
    done
    if (( ${#problems} == 0 )) && $all_up; then
        touch "$STATE/boot-$boot"
        log "startup complete"
        dialog "All $SERVER_NAME services are running."
        started_list=$(paste -sd ',' "$STATE/boot-started-$boot" 2>/dev/null | sed 's/,/, /g')
        # weekly-restart.sh leaves a note just before it restarts the Mac. A planned restart
        # that went well isn't news: the log line above is enough.
        if [[ -n $(find "$STATE/planned-restart" -mmin -45 2>/dev/null) ]]; then
            log "planned restart: everything is back $(( (now - boot) / 60 ))m$(( (now - boot) % 60 ))s after boot${started_list:+ (started: $started_list)}; not notified"
        else
            notify "✅ $SERVER_NAME startup complete $(( (now - boot) / 60 ))m$(( (now - boot) % 60 ))s after boot. All services running${started_list:+ (started: $started_list)}." 0
        fi
        rm -f "$STATE/planned-restart"
    elif (( now - boot >= BOOT_WINDOW - 60 )); then
        touch "$STATE/boot-$boot"
        rm -f "$STATE/planned-restart"
        log "startup finished with problems: ${(j:; :)problems}"
        notify "⚠️ $SERVER_NAME restarted $(( (now - boot) / 60 )) min ago but not everything is up: ${(j:; :)problems}" 1
    fi
fi
rm -f "$STATE"/boot-*(Nm+30)

# Heartbeat last, so it means "the watchdog completed a run", not just "the Mac is on".
if [[ -n $HEARTBEAT_URL ]] && (( ! DRY_RUN )); then
    # One retry after 5 s; log curl's error so failures can be diagnosed.
    hb_errs=()
    for try in 1 2; do
        hb_err=$(curl -fsS -m 10 -o /dev/null -G --data-urlencode "status=up" \
            --data-urlencode "msg=${${(j:; :)problems}:-OK}" "$HEARTBEAT_URL" 2>&1) && break
        hb_errs+=("${hb_err//$'\n'/ }")
        if (( try == 1 )); then
            # Comparison: can we reach a well-known site right now? Tells the home
            # connection apart from the status server or its route.
            cmp=$(curl -sS -m 10 -o /dev/null -I -w '%{http_code} in %{time_total}s' https://www.apple.com/ 2>&1)
            sleep 5
        fi
    done
    if (( ${#hb_errs} == 2 )); then
        log "heartbeat failed twice: ${hb_errs[1]} / ${hb_errs[2]} (apple.com: ${cmp//$'\n'/ })"
    elif (( ${#hb_errs} == 1 )); then
        log "heartbeat retry OK after: ${hb_errs[1]} (apple.com: ${cmp//$'\n'/ })"
    fi
fi
exit 0
