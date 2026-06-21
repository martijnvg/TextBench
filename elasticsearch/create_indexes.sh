#!/bin/bash
set -e

# Usage: ./create_indexes.sh [start_file [end_file]]
#   Creates one index per parquet file: otel_logs_part_NNN
#   Then sets up aliases: otel_logs_1b, otel_logs_10b, otel_logs_50b
#
#   start_file  first file number to create (default: 0)
#   end_file    last file number to create inclusive (default: 49)
#
# Each index uses logsdb mode, 1 primary shard, no replicas, sorted by
# (ServiceName, Body.template_id, @timestamp) to match the ClickHouse primary key.

START="${1:-0}"
END="${2:-49}"
ES_URL="${ES_URL:-http://localhost:9200}"
SHARDS=1

# ---------------------------------------------------------------------------
# Create one index
# ---------------------------------------------------------------------------
create_index() {
    local FILE_NUM="$1"
    local NAME="otel_logs_part_${FILE_NUM}"

    echo "=== Creating $NAME ==="
    curl -sf -X DELETE "$ES_URL/$NAME" > /dev/null 2>&1 || true

    curl -s -X PUT "$ES_URL/$NAME" \
        -H 'Content-Type: application/json' \
        -d "$(cat <<EOF
{
  "settings": {
    "index": {
      "mode":               "logsdb",
      "number_of_shards":   $SHARDS,
      "number_of_replicas": 0,
      "sort.field": ["ServiceName", "Body.template_id", "@timestamp"],
      "sort.order": ["asc", "asc", "desc"]
    }
  },
  "mappings": {
    "properties": {
      "@timestamp":         { "type": "date_nanos", "index": false },
      "TraceId":            { "type": "keyword",    "index": false },
      "SpanId":             { "type": "keyword",    "index": false },
      "TraceFlags":         { "type": "byte",       "index": false },
      "SeverityText":       { "type": "keyword",    "index": false },
      "SeverityNumber":     { "type": "byte",       "index": false },
      "ServiceName":        { "type": "keyword",    "index": false },
      "Body":               { "type": "pattern_text" },
      "ResourceSchemaUrl":  { "type": "keyword",    "index": false },
      "ResourceAttributes": { "type": "flattened",  "index": false },
      "ScopeSchemaUrl":     { "type": "keyword",    "index": false },
      "ScopeName":          { "type": "keyword",    "index": false },
      "ScopeVersion":       { "type": "keyword",    "index": false },
      "ScopeAttributes":    { "type": "flattened",  "index": false },
      "LogAttributes":      { "type": "flattened",  "index": false }
    }
  }
}
EOF
)" | python3 -m json.tool --no-indent
    echo ""
}

# ---------------------------------------------------------------------------
# Create indices
# ---------------------------------------------------------------------------
for i in $(seq "$START" "$END"); do
    FILE_NUM=$(printf "%03d" "$i")
    create_index "$FILE_NUM"
done

# ---------------------------------------------------------------------------
# Aliases — rebuild based on all existing otel_logs_part_* indices
# ---------------------------------------------------------------------------
echo "=== Setting up aliases ==="

build_alias_actions() {
    local alias_name="$1"
    local from="$2"
    local to="$3"
    local actions=""
    for i in $(seq "$from" "$to"); do
        FILE_NUM=$(printf "%03d" "$i")
        INDEX="otel_logs_part_${FILE_NUM}"
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ES_URL/$INDEX")
        if [[ "$HTTP_STATUS" == "200" ]]; then
            actions="${actions}{\"add\":{\"index\":\"$INDEX\",\"alias\":\"$alias_name\"}},"
        fi
    done
    echo "${actions%,}"  # strip trailing comma
}

for alias_def in "otel_logs_1b:0:0" "otel_logs_10b:0:9" "otel_logs_50b:0:49"; do
    ALIAS="${alias_def%%:*}"
    REST="${alias_def#*:}"
    FROM="${REST%%:*}"
    TO="${REST##*:}"

    ACTIONS=$(build_alias_actions "$ALIAS" "$FROM" "$TO")
    if [[ -z "$ACTIONS" ]]; then
        echo "  $ALIAS: no indices found, skipping"
        continue
    fi

    # Remove old alias first, then re-add
    curl -s -X DELETE "$ES_URL/*/_alias/$ALIAS" > /dev/null 2>&1 || true
    curl -s -X POST "$ES_URL/_aliases" \
        -H 'Content-Type: application/json' \
        -d "{\"actions\":[${ACTIONS}]}" | python3 -m json.tool --no-indent
    echo "  $ALIAS → parts $(printf '%03d' "$FROM")..$(printf '%03d' "$TO")"
done

echo ""
echo "Done."
