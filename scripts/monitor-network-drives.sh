#!/bin/zsh
# monitor-network-drives.sh

# This script checks if the network drives are mounted,
# logs & notifies any negative status, and attempts to
# remount drives as needed.

# The script is intended to be run as a LaunchAgent
# on macOS, and is triggered by this LaunchAgent plist:
# ~/Library/LaunchAgents/com.admin.monitor-network-drives.plist
# I have this set to run every 10 seconds, for minimal downtime.

# Check the time of the last reboot
last_reboot=$(sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//')
current_time=$(date +%s)
time_since_reboot=$((current_time - last_reboot))

# If the last reboot was less than a minute ago, exit
# so we don't interfere with the startup AppleScript
if [ "$time_since_reboot" -lt 60 ]; then
    echo "The system was rebooted less than a minute ago. Exiting script."
    exit 0
fi

# Check if the network drive "plexmedia" is mounted
if ! mount | grep "plexmedia" > /dev/null; then
    plexmediaMounted=false
    # Log the status
    /Applications/log-event.sh "network drive unmounted: plexmedia"
fi

# Check if the network drive "scandocs" is mounted
if ! mount | grep "scandocs" > /dev/null; then
    scandocsMounted=false
    # Log the status
    /Applications/log-event.sh "network drive unmounted: scandocs"
fi

# If either network drive is not mounted, Send notification to HASS
if [ "$plexmediaMounted" = false ] || [ "$scandocsMounted" = false ]; then
    theMessage="Synology network drive(s) unmounted:"
    if [ "$plexmediaMounted" = false ]; then
        theMessage="$theMessage\n• plexmedia"
    fi
    if [ "$scandocsMounted" = false ]; then
        theMessage="$theMessage\n• scandocs"
    fi
    echo "One or more network drives are not mounted. Sending notification to HASS..."
    /Applications/hass-notify-callisto.sh "Skyfall Error" "$theMessage"
fi


# If the network drive "plexmedia" is not mounted,
# close dependent apps and re-run the Startup script.
# Doing this check before 'scandocs' because if 'plexmedia' is down,
# there's a good chance 'scandocs' is down as well,
# and will also be re-mounted by the Startup script.
if [ "$plexmediaMounted" = false ]; then
    echo "Network drive "plexmedia" is not mounted. Closing dependent apps and re-running Startup script..."
    echo "Quitting Plex Media Server..."
    osascript -e 'tell application "Plex Media Server" to quit'
    echo "Quitting Sonos..."
    osascript -e 'tell application "Sonos" to quit'
    echo "Quitting Music..."
    osascript -e 'tell application "Music" to quit'
    echo "Quitting DEVONthink..."
    osascript -e 'tell application id "DNtp" to quit'
    echo "Running Startup Apps and Databases..."
    /Applications/log-event.sh "Launching Startup Apps and Databases..."
    osascript -e 'tell application "Startup Apps and Databases" to activate'
    exit 0
fi

# If the network drive "scandocs" is not mounted, attempt re-mount
# This is only used for DEVONthink import, so no need to close the app
if [ "$scandocsMounted" = false ]; then
    echo "Network drive "scandocs" is not mounted. Attempting remount..."
    /Applications/log-event.sh "Attempting to remount network drive: scandocs..."
    osascript -e 'tell application "Finder" to mount volume "smb://mynas._smb._tcp.local/scandocs"'
fi
