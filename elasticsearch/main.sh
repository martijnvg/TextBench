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

OUTPUT_PREFIX="${1:-_m6i.8xlarge}"

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

    # Record index sizes (after force merge, before restart)
    ./total_size.sh | tee "${OUTPUT_PREFIX}_es_${scale}.index_size"

    # Restart to simulate cold start / clear in-memory state
    echo ""
    echo "=== Restarting Elasticsearch (cold start) ==="
    sudo systemctl restart elasticsearch
    sleep 10
    ./start.sh   # wait until healthy

    # Run ES|QL benchmark
    ./benchmark_esql.sh "$scale" "" "${OUTPUT_PREFIX}_es_${scale}.results_runtime"

    ./drop_indexes.sh
}

benchmark 1b
