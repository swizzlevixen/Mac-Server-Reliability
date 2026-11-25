#!/bin/zsh
# log-reboot.sh

# This script logs the most recent boot time to the log file
# and sends a notification that the server has rebooted.
# Run once at login by LaunchAgents/com.admin.log-reboot.plist.
#
# A restart planned by weekly-restart.sh is logged but not notified: that script
# leaves a note in the watchdog's state folder just before it restarts the Mac.

# Path to the log file (use the same file as LOG_FILE in the watchdog config)
log_file="$HOME/Library/Logs/mac-server-events.log"

# Notification command, called as: notify_cmd "Title" "Message"
notify_cmd="/Applications/pushover-notify.sh"

# The note weekly-restart.sh leaves (the watchdog removes it once everything is up)
planned_note="$HOME/Library/Application Support/mac-server-watchdog/planned-restart"
planned=""
[[ -n $(find "$planned_note" -mmin -30 2>/dev/null) ]] && planned=" (planned weekly restart)"

# Check the time of the last reboot
last_reboot=$(sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//')
{
    echo "$(date -r $last_reboot +"%Y-%m-%d %H:%M:%S %Z") - REBOOT$planned"
} >> "$log_file"
[[ -n $planned ]] && exit 0

# Send the notification. This runs right at login, when the network may not be up
# yet, so retry for about two minutes.
server_name=$(scutil --get ComputerName 2>/dev/null || hostname -s)
for attempt in {1..12}; do
    "$notify_cmd" "$server_name" "🔄 $server_name has rebooted. The watchdog is starting services." && break
    sleep 10
done
