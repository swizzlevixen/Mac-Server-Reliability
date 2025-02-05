#!/bin/zsh
# log-event.sh
# This script logs the current time, with provided text

# Usage:
# log-event.sh "Event description"

# Path to the log file
log_file="/path/to/log/events.log"

# Log the current time with any provided text
{
    echo "$(date +"%Y-%m-%d %H:%M:%S %Z") - $1"
} >> "$log_file"
