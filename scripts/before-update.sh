#!/bin/zsh
# before-update.sh
# https://github.com/swizzlevixen/Mac-Server-Reliability
#
# Run this just before installing a macOS update (or any planned restart).
#
# A restart for a software update reopens every app that was running, even with
# "Reopen windows when logging back in" turned off. Those apps then start before
# the network shares are mounted, ahead of the watchdog, which can do real damage:
# Music, for one, quietly resets its media folder to the local default when the
# folder on the share isn't there yet.
#
# So this stops the watchdog and quits the apps it manages, leaving nothing for
# macOS to reopen. After the restart the watchdog loads at login as usual and
# starts each app once its shares are mounted.
#
#   zsh before-update.sh          stop the watchdog and quit the apps
#   zsh before-update.sh --undo   changed your mind: start the watchdog again
#                                 (it relaunches the apps within a minute)

LABEL=com.admin.mac-server-watchdog
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONF=${WATCHDOG_CONF:-$HOME/.config/mac-server-watchdog.conf}
STATE="$HOME/Library/Application Support/mac-server-watchdog"

if [[ $1 == --undo ]]; then
    launchctl bootstrap gui/$UID "$PLIST" 2>/dev/null
    if launchctl print gui/$UID/$LABEL >/dev/null 2>&1; then
        echo "Watchdog running again; it will relaunch the apps within a minute."
    else
        echo "Couldn't start the watchdog. Try: launchctl bootstrap gui/$UID \"$PLIST\""; exit 1
    fi
    exit 0
fi

[[ -r $CONF ]] || { echo "Config not found: $CONF"; exit 1; }
SERVICES=()
source "$CONF"

# 1. Stop the watchdog first, or it would relaunch each app as soon as it quits.
launchctl bootout gui/$UID/$LABEL 2>/dev/null
if launchctl print gui/$UID/$LABEL >/dev/null 2>&1; then
    echo "Couldn't stop the watchdog; not quitting anything."; exit 1
fi
echo "Watchdog stopped."

# 2. Quit the managed apps, last-started first. Gracefully only: an app that won't
#    quit (an unsaved document, say) is reported, never force-quit.
not_quit=()
for entry in ${(Oa)SERVICES}; do
    IFS='|' read -r key label app needs url <<< "$entry"
    if [[ $app == creator:* ]]; then
        # The watchdog caches where it found the app; read the bundle id from there
        app_path=$(cat "$STATE/app-$key" 2>/dev/null)
        bid=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
    else
        bid=$app
    fi
    if [[ -z $bid ]]; then echo "  $label: couldn't find the app, skipped"; continue; fi
    if [[ $(osascript -e "application id \"$bid\" is running" 2>/dev/null) != true ]]; then
        echo "  $label: not running"; continue
    fi
    printf '  %s: quitting… ' "$label"
    perl -e 'alarm shift; exec @ARGV' 60 osascript -e "tell application id \"$bid\" to quit" >/dev/null 2>&1
    for i in {1..30}; do
        [[ $(osascript -e "application id \"$bid\" is running" 2>/dev/null) == true ]] || break
        sleep 1
    done
    if [[ $(osascript -e "application id \"$bid\" is running" 2>/dev/null) == true ]]; then
        echo "STILL RUNNING"; not_quit+=("$label")
    else
        echo "quit"
    fi
done

echo
if (( ${#not_quit} )); then
    echo "Not quit: ${(j:, :)not_quit}. Quit them by hand before installing the update."
    echo "(Or run with --undo to put everything back.)"
    exit 1
fi
echo "Ready. Install the update now; the watchdog starts again at the next login."
echo "Not updating after all? Run: zsh $0 --undo"
