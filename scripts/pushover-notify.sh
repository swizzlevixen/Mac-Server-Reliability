#!/bin/zsh
# pushover-notify.sh
# Sends a notification through Pushover (https://pushover.net).
#
# Usage:
# pushover-notify.sh "Title" "Message" [priority]
#   priority: -2 (silent) | -1 (quiet) | 0 (normal, default) | 1 (high)
#
# Credentials are read from ~/.pushover-creds (chmod 600), or the file named in
# $PUSHOVER_CREDS, containing:
#   export PUSHOVER_USER="<YOUR_USER_KEY>"
#   export PUSHOVER_TOKEN="<APP_API_TOKEN>"
# Create an application for this server at https://pushover.net/apps/build so its
# notifications get their own name and icon.

creds=${PUSHOVER_CREDS:-$HOME/.pushover-creds}
[[ -r $creds ]] && source "$creds"
: "${PUSHOVER_USER:?Set PUSHOVER_USER in $creds}"
: "${PUSHOVER_TOKEN:?Set PUSHOVER_TOKEN in $creds}"

curl -fsS -m 15 \
    --form-string "token=$PUSHOVER_TOKEN" \
    --form-string "user=$PUSHOVER_USER" \
    --form-string "title=$1" \
    --form-string "message=$2" \
    --form-string "priority=${3:-0}" \
    https://api.pushover.net/1/messages.json >/dev/null
