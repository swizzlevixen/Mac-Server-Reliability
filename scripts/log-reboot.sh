#!/bin/zsh
# log-reboot.sh

# This script logs the most recent boot time to the log file
# and sends a notification to Home Assistant

# Path to the log file
log_file="/path/to/log/events.log"

# Check the time of the last reboot
last_reboot=$(sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//')
{
    echo "$(date -r $last_reboot +"%Y-%m-%d %H:%M:%S %Z") - REBOOT"
} >> "$log_file"

# Send notification to iPhone via Home Assistant
/Applications/hass-notify-iphone.sh "Server Reboot" "Server has rebooted."
