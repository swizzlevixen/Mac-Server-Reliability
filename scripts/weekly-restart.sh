#!/bin/zsh
# weekly-restart.sh
# Companion to mac-server-watchdog.sh (https://github.com/swizzlevixen/Mac-Server-Reliability)
#
# Restarts the Mac once a week, in the small hours. Apps on a server that is never
# restarted keep memory they no longer need; swap grows until the startup disk has no
# room for more, and macOS then says it has run out of application memory.
#
# Run at the scheduled time by a LaunchAgent:
#   LaunchAgents/com.admin.weekly-restart.plist
# Settings (all optional) go in the watchdog's config file:
#   ~/.config/mac-server-watchdog.conf
#
# What it does:
#   - Waits while the Mac is busy: someone at the keyboard, something playing in Plex,
#     or one of the RESTART_BUSY_CHECKS in the config. It looks again every
#     RESTART_RETRY seconds, and after RESTART_WINDOW seconds skips this week.
#   - Runs the RESTART_CLEANUP commands in the config, if any: housekeeping that is
#     best done once a week, while nothing is using the Mac. A failure is logged and
#     the restart goes ahead.
#   - Runs before-update.sh, which stops the watchdog and quits the apps it manages,
#     so that macOS reopens none of them ahead of the network shares.
#   - Asks Finder to restart the Mac. That is an ordinary restart: an app with a
#     question on screen can stop it. If the Mac is still up RESTART_STUCK seconds
#     later, this puts everything back (before-update.sh --undo) and says which apps
#     are still open.
#   - Leaves a note for log-reboot.sh and the watchdog, which then log the restart
#     without their "has rebooted" and "startup complete" notifications. A startup
#     with problems is notified as always.
#   - Notifies only when there is something to do: an app stopped the restart, or the
#     restart has been put off until the Mac has been up RESTART_OVERDUE_DAYS days.
#
# Skip the next restart:    touch ~/.config/weekly-restart.hold   (removed once used)
# See what it would do:     DRY_RUN=1 zsh weekly-restart.sh
# Restart right now:        zsh weekly-restart.sh --now   (doesn't look whether the Mac is busy)

# ---------- defaults (override any of these in the config file) ----------
SERVER_NAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
LOG_FILE="$HOME/Library/Logs/mac-server-events.log"
NOTIFY_CMD="/Applications/pushover-notify.sh"   # called as: NOTIFY_CMD "Title" "Message" [priority]
STATE="$HOME/Library/Application Support/mac-server-watchdog"
RESTART_RETRY=600               # seconds between looks while the Mac is busy
RESTART_WINDOW=10800            # seconds after the scheduled time at which this week is skipped
RESTART_IDLE_MIN=15             # minutes without a key or mouse move before nobody is at the Mac
RESTART_MIN_UPTIME_DAYS=2       # no restart when the Mac was restarted this recently anyway
RESTART_OVERDUE_DAYS=13         # notify when a restart is skipped and the Mac has been up this long
RESTART_STUCK=300               # seconds after asking for the restart before it counts as stopped
RESTART_PLEX_URL="http://127.0.0.1:32400"   # wait while Plex is playing something; "" to skip
RESTART_BUSY_CHECKS=()          # "what is going on|command that succeeds while it is" — see below
RESTART_CLEANUP=()              # "what it does|command" — run just before the restart, 10 min each at most
RESTART_HOLD_FILE="$HOME/.config/weekly-restart.hold"
RESTART_BEFORE="${0:A:h}/before-update.sh"
RESTART_CMD=(osascript -e 'tell application "Finder" to restart')
DRY_RUN=${DRY_RUN:-0}
# Example for the config file:
#   RESTART_BUSY_CHECKS=(
#     "a backup script is running|pgrep -qf nightly-backup"
#     "the Actions runner has a job|pgrep -qf Runner.Worker"
#   )

CONF=${WATCHDOG_CONF:-$HOME/.config/mac-server-watchdog.conf}
[[ -r $CONF ]] && source "$CONF"

# Errors go to the event log, as the watchdog's do (launchd can't open files in ~/Desktop).
(( DRY_RUN )) || [[ -t 1 ]] || exec >>"$LOG_FILE" 2>&1
mkdir -p "$STATE" "${LOG_FILE:h}"

now=$(date +%s)
boot=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ,)
up_days=$(( (now - boot) / 86400 ))
NOTE="$STATE/planned-restart"   # read by log-reboot.sh and the watchdog after the restart
SELF=${0:A}

# ---------- helpers ----------
log() {
    (( DRY_RUN )) || print -r -- "$(date +"%Y-%m-%d %H:%M:%S %Z") - weekly restart: $1" >> "$LOG_FILE"
    (( DRY_RUN )) || [[ -t 1 ]] && print -r -- "weekly restart: $1"
}

notify() {      # message, [priority] — -1 by default: shown, but without a sound in the night
    if (( DRY_RUN )); then print -r -- "(dry run) notify: $1"; return; fi
    perl -e 'alarm shift; exec @ARGV' 20 "$NOTIFY_CMD" "$SERVER_NAME" "$1" "${2:--1}" >/dev/null 2>&1 \
        || log "notification failed: $1"
}

with_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }

plex_playing() {
    [[ -n $RESTART_PLEX_URL ]] || return 1
    local token n
    token=$(plutil -extract PlexOnlineToken raw -o - "$HOME/Library/Preferences/com.plexapp.plexmediaserver.plist" 2>/dev/null) || return 1
    # The token goes to curl on its standard input, not on its command line, where `ps` would show it
    n=$(print -r -- "header = \"X-Plex-Token: $token\"" | curl -fsS -m 10 -K - "$RESTART_PLEX_URL/status/sessions" 2>/dev/null \
        | sed -n 's/.*<MediaContainer size="\([0-9]*\)".*/\1/p' | head -1)
    (( ${n:-0} > 0 ))
}

# Fills $whys with every reason to wait; succeeds if there is one.
busy() {
    local idle entry
    whys=()
    idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF / 60000000000); exit}')
    [[ $idle == <-> ]] && (( idle < RESTART_IDLE_MIN )) && whys+=("someone is using the Mac (last key or mouse move $idle min ago)")
    plex_playing && whys+=("something is playing in Plex")
    for entry in $RESTART_BUSY_CHECKS; do
        ( eval "${entry#*|}" ) >/dev/null 2>&1 </dev/null && whys+=("${entry%%|*}")
    done
    (( ${#whys} ))
}

skipped() {     # reason — log it; notify only once the Mac has gone without a restart for too long
    log "skipped this week: $1. Up $up_days days."
    (( up_days >= RESTART_OVERDUE_DAYS )) || return
    notify "🔁 $SERVER_NAME has been up $up_days days: the weekly restart was put off again ($1). It tries again next week. To restart sooner: zsh $SELF --now"
}

put_back() {    # after a restart that didn't happen: watchdog on again (it reopens its apps), note gone
    rm -f "$NOTE"
    (( DRY_RUN )) || zsh "$RESTART_BEFORE" --undo >/dev/null 2>&1
}

# ---------- should it happen at all? ----------
if [[ $1 != --now ]]; then
    if (( up_days < RESTART_MIN_UPTIME_DAYS )); then
        log "skipped this week: the Mac was restarted $(( (now - boot) / 3600 )) hours ago"
        exit 0
    fi
    if [[ -e $RESTART_HOLD_FILE ]]; then
        (( DRY_RUN )) || rm -f "$RESTART_HOLD_FILE"
        skipped "held by $RESTART_HOLD_FILE (now removed)"
        exit 0
    fi
    last=""
    while busy; do
        why=${(j:; :)whys}
        if (( DRY_RUN )); then print -r -- "(dry run) would wait: $why"; break; fi
        [[ $why == $last ]] || log "waiting: $why"
        last=$why
        if (( $(date +%s) - now + RESTART_RETRY > RESTART_WINDOW )); then
            skipped "$why"
            exit 0
        fi
        sleep $RESTART_RETRY
    done
fi

if (( DRY_RUN )); then
    for entry in $RESTART_CLEANUP; do print -r -- "(dry run) cleanup: ${entry%%|*}: ${entry#*|}"; done
    print -r -- "(dry run) would run $RESTART_BEFORE, then: $RESTART_CMD"
    print -r -- "(dry run) Finder answers: $(with_timeout 20 osascript -e 'tell application "Finder" to get name of startup disk' 2>&1)"
    exit 0
fi

# ---------- restart ----------
log "restarting $SERVER_NAME (up $up_days days, swap used $(sysctl -n vm.swapusage | awk '{print $6}'))"
for entry in $RESTART_CLEANUP; do
    if out=$(with_timeout 600 zsh -c "${entry#*|}" 2>&1 </dev/null); then
        log "cleanup: ${entry%%|*}: ${${out##*$'\n'}:-done}"
    else
        log "cleanup FAILED: ${entry%%|*}: ${${out##*$'\n'}:-no message}"
    fi
done
print -r -- "$boot" > "$NOTE"

if ! out=$(zsh "$RESTART_BEFORE" 2>&1); then
    put_back
    log "called off: ${${out//$'\n'/ }//  / }"
    stuck=${${(f)out}[(r)Not quit:*]}; stuck=${${stuck#Not quit: }%%. Quit*}
    [[ -n $stuck ]] && stuck="$stuck wouldn't quit" || stuck="${RESTART_BEFORE:t} failed (see the log)"
    notify "🔁 The weekly restart was called off: $stuck. The watchdog is running again. To try again: zsh $SELF --now"
    exit 1
fi
rmdir "$STATE/lock" 2>/dev/null     # left behind if the watchdog was stopped in the middle of a run

with_timeout 60 $RESTART_CMD >/dev/null 2>&1 || log "the restart command failed"
sleep $RESTART_STUCK

# Still here: something stopped the restart.
put_back
still_open=$(lsappinfo visibleProcessList 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | grep -vx Finder | paste -sd ',' - | sed 's/,/, /g; s/_/ /g')
log "the restart did not happen; watchdog started again. Apps still open: ${still_open:-none}"
notify "🔁 The weekly restart didn't go through: an app wouldn't quit (still open: ${still_open:-none}). The watchdog and its apps are running again. Look for a question on $SERVER_NAME's screen, then: zsh $SELF --now"
exit 1
