#!/bin/bash

# Usage: ./run_queries_esql_local.sh [index] [log_file] [query_file]
#   index:      full index name to run against (e.g. otel_logs_1b)
#   log_file:   file to append raw JSON responses to (default: /dev/null)
#   query_file: path to ES|QL query JSON file (default: queries_esql.json)
#
# Local variant of run_queries_esql.sh — skips the systemctl stop/start and
# OS page-cache drop, so it runs on any non-systemd host. Allows for easy testing locally.
# All 3 runs per query are warm; there is no cold-cache measurement.

ES_URL="${ES_URL:-http://localhost:9200}"
INDEX="${1:?Usage: $0 <index> [log_file] [query_file]}"
LOG_FILE="${2:-/dev/null}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_FILE="${3:-$SCRIPT_DIR/queries_esql.json}"

if [[ ! -f "$QUERY_FILE" ]]; then
    echo "Error: query file '$QUERY_FILE' not found." >&2
    exit 1
fi

QUERY_COUNT=$(jq 'length' "$QUERY_FILE")
echo "Running $QUERY_COUNT ES|QL queries against $INDEX (3 warm runs each)"
echo ""

for idx in $(seq 0 $((QUERY_COUNT - 1))); do
    LABEL=$(jq -r ".[$idx].label"       "$QUERY_FILE")
    DESC=$(jq -r  ".[$idx].description" "$QUERY_FILE")
    ESQL=$(jq -r ".[$idx].esql" "$QUERY_FILE" | sed "s/FROM otel_logs/FROM $INDEX/g")
    BODY=$(jq -n --arg q "$ESQL" '{"query": $q}')

    echo "--- $LABEL: $DESC ---"
    for i in $(seq 1 3); do
        RESPONSE=$(curl -sf -X POST "$ES_URL/_query" \
            -H 'Content-Type: application/json' \
            -d "$BODY")
        echo "$RESPONSE" >> "$LOG_FILE"
        TOOK_MS=$(echo "$RESPONSE" | jq -r '.took')
        TOOK_S=$(python3 -c "print(f'{$TOOK_MS/1000:.3f}')")
        printf "  Run %d: %.3f s\n" "$i" "$TOOK_S"
    done
    echo ""
done
