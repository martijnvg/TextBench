#!/bin/bash
set -e

# Full benchmark orchestration for Elasticsearch (1b scale, ES|QL).
#
# Usage: ./main.sh [output_prefix]
#   output_prefix: prefix for result files (default: _m6i.8xlarge)
#
# The script:
#   1. Starts Elasticsearch
#   2. Creates otel_logs (logsdb, 1 shard) index
#   3. Ingests 1b rows
#   4. Restarts ES (cold-start simulation)
#   5. Runs ES|QL benchmark queries (3 runs each)
#   6. Records index sizes
#   7. Drops indexes

DEFAULT_CHOICE=ask
CHOICE="${1:-$DEFAULT_CHOICE}"
OUTPUT_PREFIX="${2:-_m6i.8xlarge}"

if [ "$CHOICE" = "ask" ]; then
    echo "Select the dataset size to benchmark:"
    echo "1) 1b  — 1 Parquet file  (~1B rows)"
    echo "2) 10b — 10 Parquet files (~10B rows)"
    echo "3) 50b — all 50 files     (~50B rows)"
    echo "4) all — run 1b → 10b → 50b"
    read -rp "Enter choice [1-4]: " CHOICE
fi

./install.sh

benchmark() {
    local scale=$1   # 1b | 10b | 50b
    local suffix="_${scale}"

    # Map scale -> parquet file range (parts are 000..049)
    local file_first=0 file_last
    case "$scale" in
        1b)  file_last=0  ;;
        10b) file_last=9  ;;
        50b) file_last=49 ;;
        *) echo "Unknown scale '$scale'. Use: 1b | 10b | 50b" >&2; return 1 ;;
    esac

    echo ""
    echo "========================================"
    echo "  SCALE: $scale"
    echo "========================================"

    ./start.sh
    ./create_indexes.sh "$file_first" "$file_last"

    # Ingest standard index
    ./load_data.sh "$file_first" "$file_last"

    # Record index sizes (after waiting for background merges to complete, before restart)
    ./total_size.sh | tee "${OUTPUT_PREFIX}_es_${scale}.index_size"

    # Restart to simulate cold start / clear in-memory state
    echo ""
    echo "=== Restarting Elasticsearch (cold start) ==="
    sudo systemctl restart elasticsearch
    sleep 10
    ./start.sh   # wait until healthy

    # Run ES|QL queries:
    ./benchmark_esql.sh "$scale" "" "${OUTPUT_PREFIX}_es_${scale}.results_runtime"

    ./drop_indexes.sh "$scale"
}

case $CHOICE in
    2) benchmark 10b ;;
    3) benchmark 50b ;;
    4)
        benchmark 1b
        benchmark 10b
        benchmark 50b
        ;;
    *)
        benchmark 1b
        ;;
esac
