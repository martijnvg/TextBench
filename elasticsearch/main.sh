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

    echo ""
    echo "========================================"
    echo "  SCALE: $scale"
    echo "========================================"

    ./start.sh
    ./create_indexes.sh "$scale"

    # Ingest standard index
    ./load_data.sh "$scale" "otel_logs"

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

    ./drop_indexes.sh
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
