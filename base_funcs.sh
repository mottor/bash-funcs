#!/bin/bash

#CUR_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
#ME=$(basename $0)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHT_GRAY='\033[0;37m'
NC='\033[0m' # No Color

export CHECK_MARK="\u2705"
export CROSS_MARK="\u274c"
export WARN_MARK="\u26A0\ufe0f"
export THUMBS_UP_MARK="\U0001F44D"
export PARTY_POPPER_MARK="\U0001F389"

# =================================================================================

printMessage() {
    echo -e "${LIGHT_GRAY}base_funcs:${NC} $@"
}

printRed() {
    echo -e "${LIGHT_GRAY}base_funcs:${NC} ${RED}$@${NC}"
}

printGreen() {
    echo -e "${LIGHT_GRAY}base_funcs:${NC} ${GREEN}$@${NC}"
}

printYellow() {
    echo -e "${LIGHT_GRAY}base_funcs:${NC} ${YELLOW}$@${NC}"
}

printBlue() {
    echo -e "${LIGHT_GRAY}base_funcs:${NC} ${BLUE}$@${NC}"
}

printPurple() {
    echo -e "${LIGHT_GRAY}base_funcs:${NC} ${PURPLE}$@${NC}"
}

printCyan() {
    echo -e "${LIGHT_GRAY}base_funcs:${NC} ${CYAN}$@${NC}"
}

logMessage() {
    if [ "$DEBUG" != "" ]; then
        LOG_FILE="${1}"
        MESSAGE="${2}"
        echo "$MESSAGE" >> $LOG_FILE
    fi
}

# =================================================================================

urlencode() {
  local length="${#1}"
  for (( i = 0; i < length; i++ )); do
    local c="${1:i:1}"
    case $c in
      [a-zA-Z0-9.~_-]) printf "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# =================================================================================

# Args: []
# Envs: MATTERMOST_BASE_URL, MM_TOKEN_PATH, MM_USER, MM_PASS
function mattermost_auth() {
    if [ -z "$MATTERMOST_BASE_URL" ]; then
        echo "ERROR: не определена переменная MATTERMOST_BASE_URL."
        exit 1
    fi

    if [ -z "$MM_TOKEN_PATH" ]; then
        export MM_TOKEN_PATH="./mattermost_token"
    fi

    if [ -f "$MM_TOKEN_PATH" ]; then
        export MATTERMOST_TOKEN=$(head -n 1 "$MM_TOKEN_PATH" | tr -d '\r')
    else
        if [ -z "$MM_USER" ]; then
            echo "ERROR: не определена переменная MM_USER."
            exit 1
        fi
        if [ -z "$MM_PASS" ]; then
            echo "ERROR: не определена переменная MM_PASS."
            exit 1
        fi

        local _API_URL="api/v4/users/login"
        local _REQ_DATA=$(jq -c --null-input --arg user "$MM_USER" --arg pass "$MM_PASS" '{"login_id": $user, "password": $pass}')
        local _RESPONSE=$(curl -s -i -H "Content-Type: application/json; charset=utf-8" -X POST -d "$_REQ_DATA" "$MATTERMOST_BASE_URL/$_API_URL" | tr -d '\r')
        local _RESPONSE_STATUS=$(echo "$_RESPONSE" | grep "HTTP/" | cut -d' ' -f 2)

        if [ "$_RESPONSE_STATUS" == "200" ]; then
            local _TOKEN=$(echo "$_RESPONSE" | grep -Fi token | awk 'BEGIN {FS=": "}/^token/{print $2}')
            if [ "$_TOKEN" != "" ]; then
                echo -n "$_TOKEN" > "$MM_TOKEN_PATH"
                export MATTERMOST_TOKEN="$_TOKEN"
            else
                echo "ERROR: не получили токен. Raw response: $_RESPONSE"
                exit 1
            fi
        else
            echo "ERROR: запрос /$_API_URL вернул статус = $_RESPONSE_STATUS. Raw response: $_RESPONSE"
            exit 1
        fi
    fi
}

# Args:
# - channel id
# - message text
# - root post id (optional)
#
# Envs: MATTERMOST_BASE_URL, TEAM_DEV_CHANNEL_ID, UPDATES_CHANNEL_ID
#
# Returns:
# - post_id
function mattermost_post_message() {
    if [ -z "$MATTERMOST_BASE_URL" ]; then
        echo "ERROR: не определена переменная MATTERMOST_BASE_URL."
        exit 1
    fi

    local _CHANNEL_ID="$1"
    if [ "$_CHANNEL_ID" == "" ]; then
        echo "ERROR: аргумент $_CHANNEL_ID не задан или пустой."
        exit 1
    fi

    local MESSAGE="$2"
    if [ "$MESSAGE" == "" ]; then
        echo "ERROR: аргумент MESSAGE не задан или пустой."
        exit 1
    fi

    local ROOT_POST_ID="${3:-}"

    case "$_CHANNEL_ID" in
    team_dev)
        _CHANNEL_ID="$TEAM_DEV_CHANNEL_ID"
        ;;
    updates)
        _CHANNEL_ID="$UPDATES_CHANNEL_ID"
        ;;
    *)
    esac

    local _DATE=$(date '+%d.%m.%Y')
    local _TEXT=`echo "$MESSAGE" | sed -e "s/{DATE}/$_DATE/g"`
    local _REQ_DATA=$(jq -c --null-input --arg channel_id "$_CHANNEL_ID" --arg message "$_TEXT" '{"channel_id": $channel_id, "message": $message, "props":{}}')

    if [ "$ROOT_POST_ID" != "" ]; then
        _REQ_DATA=$(echo $_REQ_DATA | jq -c --arg root_post_id "$ROOT_POST_ID" '.root_id = $root_post_id')
    fi

    local _API_URL="api/v4/posts"
    local _TRIED_RELOGIN="false"

    while true; do
        local _CURL_RESPONSE_FILE=$(mktemp)
        local _RESPONSE_STATUS=$(curl -s -o $_CURL_RESPONSE_FILE -w "%{http_code}" -H "Authorization: Bearer $MATTERMOST_TOKEN" -H "Content-Type: application/json; charset=utf-8" -X POST -d "${_REQ_DATA//\\\\n/\\n}" "$MATTERMOST_BASE_URL/$_API_URL" | tr -d '\r')
        local _RESPONSE=$(head -n 1 $_CURL_RESPONSE_FILE)
        rm $_CURL_RESPONSE_FILE

        case "$_RESPONSE_STATUS" in
        201)
            POST_ID=$(echo $_RESPONSE | jq -r ".id")
            echo "$POST_ID"
            return 0
            ;;
        401)
            if [ "$_TRIED_RELOGIN" == "false" ]; then
                mattermost_auth
                _TRIED_RELOGIN="true"
            else
                echo "ERROR: запрос /$_API_URL вернул статус = $_RESPONSE_STATUS. ПОВТОРНО! Raw response: $_RESPONSE"
                return 1
            fi
            ;;
        *)
            echo "ERROR: запрос /$_API_URL вернул статус = $_RESPONSE_STATUS. Raw response: $_RESPONSE"
            return 1
            ;;
        esac
    done
}

# Args:
# - post id
# - new message text
#
# Envs: MATTERMOST_BASE_URL
#
function mattermost_update_message() {
    if [ -z "$MATTERMOST_BASE_URL" ]; then
        echo "ERROR: не определена переменная MATTERMOST_BASE_URL."
        exit 1
    fi

    local _POST_ID="${1}"
    if [ "$_POST_ID" == "" ]; then
        echo "ERROR: аргумент _POST_ID не задан или пустой."
        exit 1
    fi

    local _NEW_MESSAGE="${2}"
    if [ "$_NEW_MESSAGE" == "" ]; then
        echo "ERROR: аргумент _NEW_MESSAGE не задан или пустой."
        exit 1
    fi

    local _DATE=$(date '+%d.%m.%Y')
    local _TEXT=`echo "$_NEW_MESSAGE" | sed -e "s/{DATE}/$_DATE/g"`
    local _REQ_DATA=$(jq -c --null-input --arg message "$_TEXT" '{"message": $message}')

    local _API_URL="api/v4/posts/$_POST_ID/patch"
    local _TRIED_RELOGIN="false"

    while true; do
        local _CURL_RESPONSE_FILE=$(mktemp)
        local _RESPONSE_STATUS=$(curl -s -o $_CURL_RESPONSE_FILE -w "%{http_code}" -H "Authorization: Bearer $MATTERMOST_TOKEN" -H "Content-Type: application/json; charset=utf-8" -X PUT -d "${_REQ_DATA//\\\\n/\\n}" "$MATTERMOST_BASE_URL/$_API_URL" | tr -d '\r')
        local _RESPONSE=$(head -n 1 $_CURL_RESPONSE_FILE)
        rm $_CURL_RESPONSE_FILE

        case "$_RESPONSE_STATUS" in
        200)
            return 0
            ;;
        401)
            if [ "$_TRIED_RELOGIN" == "false" ]; then
                mattermost_auth
                _TRIED_RELOGIN="true"
            else
                echo "ERROR: запрос /$_API_URL вернул статус = $_RESPONSE_STATUS. ПОВТОРНО! Raw response: $_RESPONSE"
                return 1
            fi
            ;;
        *)
            echo "ERROR: запрос /$_API_URL вернул статус = $_RESPONSE_STATUS. Raw response: $_RESPONSE"
            return 1
            ;;
        esac
    done
}

# Args:
# - post id
# - emoji name (example: 'x', 'white_check_mark')
#
# Envs: MATTERMOST_BASE_URL, MM_REACTING_USER_ID
#
function mattermost_create_reaction() {
    if [ -z "$MATTERMOST_BASE_URL" ]; then
        echo "ERROR: не определена переменная MATTERMOST_BASE_URL."
        exit 1
    fi

    local _POST_ID="${1}"
    if [ "$_POST_ID" == "" ]; then
        echo "ERROR: аргумент _POST_ID не задан или пустой."
        exit 1
    fi

    local _EMOJI_NAME="${2}"
    if [ "$_EMOJI_NAME" == "" ]; then
        echo "ERROR: аргумент _EMOJI_NAME не задан или пустой."
        exit 1
    fi

    local _REACTING_USER_ID="5cqj47g3g3gt5yb7oprc7msj1c"
    if [ "$MM_REACTING_USER_ID" != "" ]; then
        _REACTING_USER_ID="${MM_REACTING_USER_ID}"
    fi

    local _REQ_DATA=$(jq -c --null-input \
      --arg user_id "$_REACTING_USER_ID" \
      --arg post_id "$_POST_ID" \
      --arg emoji_name "$_EMOJI_NAME" \
      '{"user_id": $user_id, "post_id": $post_id, "emoji_name": $emoji_name}')

    # Updating message

    local _API_URL="api/v4/reactions"
    local _TRIED_RELOGIN="false"

    while true; do
        local _CURL_RESPONSE_FILE=$(mktemp)
        local _RESPONSE_STATUS=$(curl -s -o $_CURL_RESPONSE_FILE -w "%{http_code}" -H "Authorization: Bearer $MATTERMOST_TOKEN" -H "Content-Type: application/json; charset=utf-8" -X POST -d "${_REQ_DATA//\\\\n/\\n}" "$MATTERMOST_BASE_URL/$_API_URL" | tr -d '\r')
        local _RESPONSE=$(head -n 1 $_CURL_RESPONSE_FILE)
        rm $_CURL_RESPONSE_FILE

        case "$_RESPONSE_STATUS" in
        200)
            return 0
            ;;
        401)
            if [ "$_TRIED_RELOGIN" == "false" ]; then
                mattermost_auth
                _TRIED_RELOGIN="true"
            else
                echo "ERROR: запрос /$_API_URL вернул статус = $_RESPONSE_STATUS. ПОВТОРНО! Raw response: $_RESPONSE"
                return 1
            fi
            ;;
        *)
            echo "ERROR: запрос /$_API_URL вернул статус = $_RESPONSE_STATUS. Raw response: $_RESPONSE"
            return 1
            ;;
        esac
    done
}

function mattermost_delete_message() {
    if [ -z "$MATTERMOST_BASE_URL" ]; then
        echo "ERROR: не определена переменная MATTERMOST_BASE_URL."
        exit 1
    fi

    local _POST_ID="${1}"
    if [ "$_POST_ID" == "" ]; then
        echo "ERROR: аргумент _POST_ID не задан или пустой."
        exit 1
    fi

    local _API_URL="api/v4/posts/$_POST_ID"
    local _API_METHOD="DELETE"
    local _TRIED_RELOGIN="false"

    while true; do
        local _CURL_RESPONSE_FILE=$(mktemp)
        local _RESPONSE_STATUS=$(curl -s -o $_CURL_RESPONSE_FILE -w "%{http_code}" -H "Authorization: Bearer $MATTERMOST_TOKEN" -H "Content-Type: application/json; charset=utf-8" -X $_API_METHOD "$MATTERMOST_BASE_URL/$_API_URL" | tr -d '\r')
        local _RESPONSE=$(head -n 1 $_CURL_RESPONSE_FILE)
        rm $_CURL_RESPONSE_FILE

        case "$_RESPONSE_STATUS" in
        200)
            return 0
            ;;
        401)
            if [ "$_TRIED_RELOGIN" == "false" ]; then
                mattermost_auth
                _TRIED_RELOGIN="true"
            else
                echo "ERROR: запрос $_API_METHOD /$_API_URL вернул статус = $_RESPONSE_STATUS. ПОВТОРНО! Raw response: $_RESPONSE"
                return 1
            fi
            ;;
        *)
            echo "ERROR: запрос $_API_METHOD /$_API_URL вернул статус = $_RESPONSE_STATUS. Raw response: $_RESPONSE"
            return 1
            ;;
        esac
    done
}