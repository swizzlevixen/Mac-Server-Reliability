#!/bin/zsh
# hass-notify-iphone.sh
# Based on code © 2024 Viktor Mukha, from this article:
# https://medium.com/@viktor.mukha/push-notifications-from-bash-script-via-home-assistant-852fa92f60ab

# This script sends a notification to Home Assistant
# using the iPhone mobile app integration.

# Usage:
# hass-notify-iphone.sh "Title" "Message"

curl -X POST \
    -H "Authorization: Bearer <LONG_TERM_TOKEN>" \
    -H "Content-Type: application/json" \
    -d "{ \
    \"message\": \"$2\", \
    \"title\": \"$1\" \
    }" \
    http://homeassistant.local:8123/api/services/notify/<MOBILE_APP_NAME>
