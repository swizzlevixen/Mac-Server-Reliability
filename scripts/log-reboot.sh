#!/bin/zsh
# log-reboot.sh

# This script logs the most recent boot time to the log file
# and sends a notification that the server has rebooted.
# Run once at login by LaunchAgents/com.admin.log-reboot.plist.

# Path to the log file (use the same file as LOG_FILE in the watchdog config)
log_file="$HOME/Library/Logs/mac-server-events.log"

# Notification command, called as: notify_cmd "Title" "Message"
notify_cmd="/Applications/pushover-notify.sh"

# Check the time of the last reboot
last_reboot=$(sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//')
{
    echo "$(date -r $last_reboot +"%Y-%m-%d %H:%M:%S %Z") - REBOOT"
} >> "$log_file"

# Send the notification. This runs right at login, when the network may not be up
# yet, so retry for about two minutes.
server_name=$(scutil --get ComputerName 2>/dev/null || hostname -s)
for attempt in {1..12}; do
    "$notify_cmd" "$server_name" "🔄 $server_name has rebooted. The watchdog is starting services." && break
    sleep 10
done
