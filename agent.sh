#!/bin/bash
# BoxWatch Metrics Collector
# Runs every minute via cron to collect and send system metrics

set -e

CONFIG_FILE="/opt/boxwatch/config"
LOG_FILE="/opt/boxwatch/agent.log"
MAX_LOG_SIZE=1048576  # 1MB

# Load config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(date): Config file not found at $CONFIG_FILE" >> "$LOG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$AGENT_KEY" ] || [ -z "$API_URL" ]; then
    echo "$(date): Missing AGENT_KEY or API_URL in config" >> "$LOG_FILE"
    exit 1
fi

# Rotate log if too large
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
    mv "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null || true
fi

# Process cache update helper (called after HTTP response)
PROCESS_CACHE="/opt/boxwatch/processes.cache"
update_process_cache() {
    if [ -z "$RESPONSE_BODY" ]; then return; fi
    if echo "$RESPONSE_BODY" | grep -q '"watched_processes":\[\]'; then
        # Empty list — truncate cache
        mkdir -p /opt/boxwatch 2>/dev/null
        > "$PROCESS_CACHE" 2>/dev/null
        return
    fi
    NEW_CACHE=$(echo "$RESPONSE_BODY" \
                | grep -oE '"watched_processes":\[[^]]*\]' \
                | grep -oE '"[^"]+"' \
                | grep -v '^"watched_processes"$' \
                | tr -d '"')
    if [ -n "$NEW_CACHE" ]; then
        mkdir -p /opt/boxwatch 2>/dev/null
        echo "$NEW_CACHE" > "$PROCESS_CACHE.tmp" && mv "$PROCESS_CACHE.tmp" "$PROCESS_CACHE"
    fi
}
update_uptime_cache() {
    if [ -z "$RESPONSE_BODY" ]; then return; fi
    if ! command -v jq >/dev/null 2>&1; then return; fi
    local NEW_CACHE
    NEW_CACHE=$(echo "$RESPONSE_BODY" | jq -c '.uptime_checks // empty' 2>/dev/null)
    if [ -z "$NEW_CACHE" ]; then return; fi
    if [ "$NEW_CACHE" = "[]" ]; then
        mkdir -p /opt/boxwatch 2>/dev/null
        > "$UPTIME_CACHE" 2>/dev/null
    else
        mkdir -p /opt/boxwatch 2>/dev/null
        echo "$NEW_CACHE" > "$UPTIME_CACHE.tmp" && mv "$UPTIME_CACHE.tmp" "$UPTIME_CACHE"
    fi
}


# Collect basic info
HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get public IPv4 (with timeout and fallback, -4 forces IPv4)
IP=$(timeout 5 curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || \
     timeout 5 curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || \
     timeout 5 curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || \
     echo "unknown")

# OS information
OS=$(uname -sr 2>/dev/null || echo "unknown")

# Uptime (seconds)
if [ -f /proc/uptime ]; then
    UPTIME=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
else
    # macOS/BSD fallback
    UPTIME=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | sed 's/,//g' || echo "0")
    if [ "$UPTIME" != "0" ]; then
        UPTIME=$(($(date +%s) - UPTIME))
    fi
fi

# CPU usage (percentage)
if command -v top &> /dev/null; then
    # Try Linux format first
    CPU=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)

    if [ -z "$CPU" ]; then
        # Try alternative Linux format
        CPU=$(top -bn2 2>/dev/null | grep "Cpu(s)" | tail -1 | awk '{print $2}' | cut -d'%' -f1)
    fi

    if [ -z "$CPU" ] && command -v vmstat &> /dev/null; then
        # Fallback to vmstat
        CPU=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print 100-$15}')
    fi
fi

# Default to 0 if still empty
CPU=${CPU:-0}

# Memory usage (percentage)
if command -v free &> /dev/null; then
    MEMORY=$(free 2>/dev/null | grep Mem | awk '{printf "%.1f", $3/$2 * 100}')
elif [ -f /proc/meminfo ]; then
    # Parse /proc/meminfo directly
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_AVAILABLE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [ -n "$MEM_TOTAL" ] && [ -n "$MEM_AVAILABLE" ]; then
        MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
        MEMORY=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED/$MEM_TOTAL) * 100}")
    fi
fi

MEMORY=${MEMORY:-0}

# Disk usage (percentage of root)
if command -v df &> /dev/null; then
    DISK=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
fi

DISK=${DISK:-0}

# Disk usage for /mnt (if it's a separate mount - checks /mnt or /mnt/*)
DISK_MNT="null"
if command -v df &> /dev/null; then
    # Check if there's any mount under /mnt (e.g., /mnt, /mnt/s3, /mnt/data)
    MNT_LINE=$(df -h 2>/dev/null | grep -E '\s/mnt(/|$)' | head -1)
    if [ -n "$MNT_LINE" ]; then
        DISK_MNT=$(echo "$MNT_LINE" | awk '{print $5}' | tr -d '%')
    fi
fi

# Load averages
if [ -f /proc/loadavg ]; then
    LOAD_1=$(cat /proc/loadavg | cut -d' ' -f1)
    LOAD_5=$(cat /proc/loadavg | cut -d' ' -f2)
    LOAD_15=$(cat /proc/loadavg | cut -d' ' -f3)
elif command -v uptime &> /dev/null; then
    # macOS/BSD fallback
    LOAD_AVERAGES=$(uptime | awk -F'load averages?: ' '{print $2}')
    LOAD_1=$(echo $LOAD_AVERAGES | cut -d',' -f1 | xargs)
    LOAD_5=$(echo $LOAD_AVERAGES | cut -d',' -f2 | xargs)
    LOAD_15=$(echo $LOAD_AVERAGES | cut -d',' -f3 | xargs)
fi

LOAD_1=${LOAD_1:-0}
LOAD_5=${LOAD_5:-0}
LOAD_15=${LOAD_15:-0}

# Network (bytes, get primary interface)
if command -v ip &> /dev/null; then
    IFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
elif command -v route &> /dev/null; then
    # BSD/macOS fallback
    IFACE=$(route get default 2>/dev/null | grep interface | awk '{print $2}')
fi

if [ -n "$IFACE" ]; then
    if [ -f "/sys/class/net/$IFACE/statistics/rx_bytes" ]; then
        NET_IN=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo "0")
        NET_OUT=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo "0")
    elif command -v netstat &> /dev/null; then
        # BSD/macOS fallback
        NET_STATS=$(netstat -ibn 2>/dev/null | grep "$IFACE" | head -1)
        NET_IN=$(echo $NET_STATS | awk '{print $7}')
        NET_OUT=$(echo $NET_STATS | awk '{print $10}')
    fi
fi

NET_IN=${NET_IN:-0}
NET_OUT=${NET_OUT:-0}

# === Process monitoring (May 2026) ===
PROCESSES_JSON="[]"

if [ -f /proc/stat ] && [ -f "$PROCESS_CACHE" ]; then
    BTIME=$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null)
    HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
    MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)

    if [ -n "$BTIME" ] && [ -n "$HZ" ]; then
        PROCESSES_JSON="["
        FIRST=1
        while IFS= read -r PNAME; do
            [ -z "$PNAME" ] && continue
            PIDS=$(pgrep -x "$PNAME" 2>/dev/null)
            COUNT=0
            SUM_RSS_KB=0
            OLDEST_START=0
            SUM_CPU=0
            if [ -n "$PIDS" ]; then
                for PID in $PIDS; do
                    STAT_FILE="/proc/$PID/stat"
                    STATUS_FILE="/proc/$PID/status"
                    [ ! -r "$STAT_FILE" ] && continue
                    START_TICKS=$(awk '{print $22}' "$STAT_FILE" 2>/dev/null)
                    if [ -n "$START_TICKS" ] && [ "$START_TICKS" != "0" ]; then
                        START_UNIX=$(( BTIME + START_TICKS / HZ ))
                        if [ "$OLDEST_START" -eq 0 ] || [ "$START_UNIX" -lt "$OLDEST_START" ]; then
                            OLDEST_START=$START_UNIX
                        fi
                    fi
                    RSS_KB=$(awk '/^VmRSS:/ {print $2}' "$STATUS_FILE" 2>/dev/null || echo 0)
                    SUM_RSS_KB=$(( SUM_RSS_KB + RSS_KB ))
                    COUNT=$(( COUNT + 1 ))
                done
                PID_CSV=$(echo "$PIDS" | tr '\n' ',' | sed 's/,$//')
                if [ -n "$PID_CSV" ]; then
                    SUM_CPU=$(ps -o pcpu= -p "$PID_CSV" 2>/dev/null | awk '{s += $1} END {printf "%.1f", s}')
                    SUM_CPU=${SUM_CPU:-0}
                fi
            fi
            RSS_PCT=0
            if [ -n "$MEM_TOTAL_KB" ] && [ "$MEM_TOTAL_KB" -gt 0 ] && [ "$SUM_RSS_KB" -gt 0 ]; then
                RSS_PCT=$(awk "BEGIN {printf \"%.1f\", ($SUM_RSS_KB/$MEM_TOTAL_KB)*100}")
            fi
            [ $FIRST -eq 0 ] && PROCESSES_JSON="$PROCESSES_JSON,"
            PROCESSES_JSON="$PROCESSES_JSON{\"name\":\"$PNAME\",\"count\":$COUNT,\"cpu\":$SUM_CPU,\"rss_kb\":$SUM_RSS_KB,\"rss_pct\":$RSS_PCT,\"oldest_start_unix\":$OLDEST_START}"
            FIRST=0
        done < "$PROCESS_CACHE"
        PROCESSES_JSON="$PROCESSES_JSON]"
    fi
fi

# === Synthetic uptime checks (May 2026, v2.1) ===
UPTIME_RESULTS_JSON="[]"
UPTIME_CACHE="/opt/boxwatch/uptime.cache"

if [ -f "$UPTIME_CACHE" ] && command -v jq >/dev/null 2>&1; then
    check_status_in_range() {
        local CODE="$1" EXPECTED="$2"
        local RANGES RANGE LO HI
        IFS=',' read -ra RANGES <<< "$EXPECTED"
        for RANGE in "${RANGES[@]}"; do
            if [[ "$RANGE" == *"-"* ]]; then
                LO="${RANGE%-*}"
                HI="${RANGE#*-}"
                [ "$CODE" -ge "$LO" ] && [ "$CODE" -le "$HI" ] && return 0
            else
                [ "$CODE" = "$RANGE" ] && return 0
            fi
        done
        return 1
    }

    run_check() {
        local CHECK_JSON="$1"
        local ID TYPE TARGET TIMEOUT
        ID=$(echo "$CHECK_JSON" | jq -r '.id')
        TYPE=$(echo "$CHECK_JSON" | jq -r '.type')
        TARGET=$(echo "$CHECK_JSON" | jq -r '.target')
        TIMEOUT=$(echo "$CHECK_JSON" | jq -r '.timeout_seconds // 10')

        local OK=false STATUS_CODE="null" LATENCY_MS="null" BODY_MATCHED="null"
        local CERT_DAYS_LEFT="null" ERROR_KIND="null" ERROR_MSG="null"

        case "$TYPE" in
            http)
                local EXP MAX_LAT BODY_MATCH FOLLOW FLAG_L TMPBODY CURL_OUT
                EXP=$(echo "$CHECK_JSON" | jq -r '.config.expected_status_codes // "200-299"')
                MAX_LAT=$(echo "$CHECK_JSON" | jq -r '.config.max_latency_ms // empty')
                BODY_MATCH=$(echo "$CHECK_JSON" | jq -r '.config.body_contains // empty')
                FOLLOW=$(echo "$CHECK_JSON" | jq -r '.config.follow_redirects // true')
                FLAG_L=""; [ "$FOLLOW" = "true" ] && FLAG_L="-L"
                TMPBODY=$(mktemp)
                CURL_OUT=$(curl -s $FLAG_L -o "$TMPBODY" -w "%{http_code} %{time_total}" \
                              --max-time "$TIMEOUT" "$TARGET" 2>/dev/null)
                STATUS_CODE=$(echo "$CURL_OUT" | awk '{print $1}')
                LATENCY_MS=$(echo "$CURL_OUT" | awk '{printf "%.0f", $2 * 1000}')
                STATUS_CODE=${STATUS_CODE:-0}; LATENCY_MS=${LATENCY_MS:-0}

                if [ "$STATUS_CODE" = "0" ] || [ "$STATUS_CODE" = "000" ]; then
                    OK=false; ERROR_KIND='"timeout"'; ERROR_MSG='"connection failed or timed out"'
                elif ! check_status_in_range "$STATUS_CODE" "$EXP"; then
                    OK=false; ERROR_KIND='"http_status"'
                    ERROR_MSG="\"got status $STATUS_CODE, expected $EXP\""
                elif [ -n "$MAX_LAT" ] && [ "$LATENCY_MS" -gt "$MAX_LAT" ]; then
                    OK=false; ERROR_KIND='"latency_high"'
                    ERROR_MSG="\"$LATENCY_MS ms > $MAX_LAT ms\""
                elif [ -n "$BODY_MATCH" ]; then
                    if grep -q -F -- "$BODY_MATCH" "$TMPBODY"; then
                        OK=true; BODY_MATCHED=true
                    else
                        OK=false; BODY_MATCHED=false
                        ERROR_KIND='"body_mismatch"'
                        ERROR_MSG='"body did not contain expected string"'
                    fi
                else
                    OK=true
                fi
                rm -f "$TMPBODY"
                ;;
            tcp)
                local HOST PORT
                HOST=$(echo "$TARGET" | cut -d: -f1)
                PORT=$(echo "$TARGET" | cut -d: -f2)
                if timeout "$TIMEOUT" bash -c "</dev/tcp/$HOST/$PORT" 2>/dev/null; then
                    OK=true
                else
                    OK=false; ERROR_KIND='"tcp_refused"'
                    ERROR_MSG="\"could not connect to $TARGET\""
                fi
                ;;
            tls_expiry)
                local HOST PORT WARN_DAYS END_DATE END_EPOCH NOW_EPOCH
                HOST=$(echo "$TARGET" | cut -d: -f1)
                PORT=$(echo "$TARGET" | cut -d: -f2)
                WARN_DAYS=$(echo "$CHECK_JSON" | jq -r '.config.warn_days_before_expiry // 14')
                END_DATE=$(echo | timeout "$TIMEOUT" openssl s_client \
                            -connect "$HOST:$PORT" -servername "$HOST" 2>/dev/null \
                            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$END_DATE" ]; then
                    END_EPOCH=$(date -d "$END_DATE" +%s 2>/dev/null \
                                || date -j -f "%b %e %T %Y %Z" "$END_DATE" +%s 2>/dev/null)
                    NOW_EPOCH=$(date +%s)
                    if [ -n "$END_EPOCH" ]; then
                        CERT_DAYS_LEFT=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))
                        if [ "$CERT_DAYS_LEFT" -gt 0 ]; then
                            OK=true
                        else
                            OK=false; ERROR_KIND='"cert_expired"'
                            ERROR_MSG="\"cert expired $((-CERT_DAYS_LEFT)) days ago\""
                        fi
                    else
                        OK=false; ERROR_KIND='"tls_fail"'
                        ERROR_MSG='"could not parse cert expiry date"'
                    fi
                else
                    OK=false; ERROR_KIND='"tls_fail"'
                    ERROR_MSG='"could not retrieve cert"'
                fi
                ;;
        esac

        cat <<JSON
{"check_id":$ID,"ok":$OK,"status_code":$STATUS_CODE,"latency_ms":$LATENCY_MS,"body_matched":$BODY_MATCHED,"cert_days_left":$CERT_DAYS_LEFT,"error_kind":$ERROR_KIND,"error_message":$ERROR_MSG}
JSON
    }

    # Sequential execution — quotes preserved (xargs -I{} strips them).
    UPTIME_TMP=$(mktemp)
    while IFS= read -r CHECK_LINE; do
        [ -z "$CHECK_LINE" ] && continue
        run_check "$CHECK_LINE" >> "$UPTIME_TMP" 2>/dev/null
    done < <(jq -c '.[]' "$UPTIME_CACHE" 2>/dev/null)
    if [ -s "$UPTIME_TMP" ]; then
        UPTIME_RESULTS_JSON=$(jq -s '.' "$UPTIME_TMP" 2>/dev/null)
    fi
    rm -f "$UPTIME_TMP"
    [ -z "$UPTIME_RESULTS_JSON" ] && UPTIME_RESULTS_JSON="[]"
fi

# Build JSON payload
JSON=$(cat <<EOF
{
    "hostname": "$HOSTNAME",
    "ip": "$IP",
    "os": "$OS",
    "timestamp": "$TIMESTAMP",
    "uptime": $UPTIME,
    "cpu": $CPU,
    "memory": $MEMORY,
    "disk": $DISK,
    "disk_mnt": $DISK_MNT,
    "load_1m": $LOAD_1,
    "load_5m": $LOAD_5,
    "load_15m": $LOAD_15,
    "network_in": $NET_IN,
    "network_out": $NET_OUT,
    "agent_version": "2.1",
    "processes": $PROCESSES_JSON,
    "uptime_results": $UPTIME_RESULTS_JSON
}
EOF
)

# Send to API
RESPONSE=$(curl -s --max-time 10 -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Agent-Key: $AGENT_KEY" \
    -d "$JSON" \
    "$API_URL/agent/heartbeat" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

# Handle response based on status code
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
    update_process_cache
    update_uptime_cache
elif [ "$HTTP_CODE" = "429" ]; then
    update_process_cache
    update_uptime_cache
    # Rate limited - this is normal for plans with longer intervals
    # Extract retry_after from response if available
    RETRY_AFTER=$(echo "$RESPONSE_BODY" | grep -o '"retry_after":[0-9]*' | cut -d':' -f2)
    if [ -n "$RETRY_AFTER" ]; then
        RETRY_MIN=$((RETRY_AFTER / 60))
        # Only log once per hour to avoid log spam
        LAST_RATE_LOG="/tmp/boxwatch_rate_log"
        CURRENT_HOUR=$(date +%Y%m%d%H)
        LAST_HOUR=$(cat "$LAST_RATE_LOG" 2>/dev/null || true)
        if [ "$CURRENT_HOUR" != "$LAST_HOUR" ]; then
            echo "$(date): Rate limited - Next metrics push in ${RETRY_MIN} minutes (plan limit)" >> "$LOG_FILE"
            echo "$CURRENT_HOUR" > "$LAST_RATE_LOG"
        fi
    fi
else
    # Other errors - log and fail loudly so install/manual runs surface the problem
    echo "$(date): HTTP $HTTP_CODE - Failed to send metrics" >> "$LOG_FILE"
    if [ -n "$RESPONSE_BODY" ]; then
        echo "$(date): Response: $RESPONSE_BODY" >> "$LOG_FILE"
    fi
    echo "BoxWatch agent: heartbeat failed (HTTP $HTTP_CODE)" >&2
    if [ -n "$RESPONSE_BODY" ]; then
        echo "Response: $RESPONSE_BODY" >&2
    fi
    exit 1
fi
