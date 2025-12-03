#!/bin/bash
# zsync Benchmark Runner and Comparison Tool
#
# Usage:
#   ./dev/bench.sh              Run benchmarks and save results
#   ./dev/bench.sh --compare    Compare latest run against baseline
#   ./dev/bench.sh --baseline   Set current results as new baseline

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_ROOT/benchmarks/results"
BASELINE_FILE="$RESULTS_DIR/baseline.txt"
LATEST_FILE="$RESULTS_DIR/latest.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

mkdir -p "$RESULTS_DIR"
cd "$PROJECT_ROOT"

run_benchmarks() {
    header "Building Benchmarks"
    log_info "Building with ReleaseFast optimizations..."
    zig build bench 2>/dev/null || {
        log_error "Build failed"
        exit 1
    }
    log_success "Build complete"

    header "Running Benchmarks"
    log_info "Executing benchmark suite..."

    # Run benchmarks and capture output
    if [ -f "./zig-out/bin/zsync-bench" ]; then
        ./zig-out/bin/zsync-bench > "$LATEST_FILE" 2>&1
    else
        # Fallback: run via zig build bench
        zig build bench > "$LATEST_FILE" 2>&1
    fi

    log_success "Results saved to $LATEST_FILE"

    # Also save timestamped copy
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp "$LATEST_FILE" "$RESULTS_DIR/run_$TIMESTAMP.txt"
    log_info "Timestamped copy: run_$TIMESTAMP.txt"

    echo ""
    cat "$LATEST_FILE"
}

compare_results() {
    header "Comparing Benchmark Results"

    if [ ! -f "$BASELINE_FILE" ]; then
        log_error "No baseline file found at $BASELINE_FILE"
        log_info "Run './dev/bench.sh --baseline' to set current results as baseline"
        exit 1
    fi

    if [ ! -f "$LATEST_FILE" ]; then
        log_error "No latest results found. Run './dev/bench.sh' first"
        exit 1
    fi

    echo ""
    echo "Baseline vs Latest Throughput Comparison:"
    echo "=========================================="
    echo ""

    # Extract throughput numbers and compare
    while IFS= read -r line; do
        if [[ "$line" == *"Throughput:"* ]]; then
            BENCH_NAME=$(grep -B5 "$line" "$LATEST_FILE" | grep -E "^[A-Z].*:" | tail -1 | sed 's/://g')
            LATEST_VAL=$(echo "$line" | grep -oE '[0-9]+' | head -1)

            # Find corresponding baseline value
            BASELINE_LINE=$(grep -A1 "$BENCH_NAME" "$BASELINE_FILE" 2>/dev/null | grep "Throughput:" | head -1)
            if [ -n "$BASELINE_LINE" ]; then
                BASELINE_VAL=$(echo "$BASELINE_LINE" | grep -oE '[0-9]+' | head -1)

                if [ -n "$BASELINE_VAL" ] && [ "$BASELINE_VAL" -gt 0 ]; then
                    DIFF=$((LATEST_VAL - BASELINE_VAL))
                    PCT=$((DIFF * 100 / BASELINE_VAL))

                    if [ $PCT -gt 5 ]; then
                        echo -e "${GREEN}$BENCH_NAME: $BASELINE_VAL -> $LATEST_VAL (+$PCT%)${NC}"
                    elif [ $PCT -lt -5 ]; then
                        echo -e "${RED}$BENCH_NAME: $BASELINE_VAL -> $LATEST_VAL ($PCT%)${NC}"
                    else
                        echo -e "$BENCH_NAME: $BASELINE_VAL -> $LATEST_VAL ($PCT%)"
                    fi
                fi
            fi
        fi
    done < "$LATEST_FILE"

    echo ""
    log_info "Green = >5% improvement, Red = >5% regression"
}

set_baseline() {
    header "Setting Baseline"

    if [ ! -f "$LATEST_FILE" ]; then
        log_info "No latest results found, running benchmarks first..."
        run_benchmarks
    fi

    cp "$LATEST_FILE" "$BASELINE_FILE"
    log_success "Baseline set from latest results"
    log_info "Baseline file: $BASELINE_FILE"
}

# Main
case "${1:-}" in
    --compare)
        compare_results
        ;;
    --baseline)
        set_baseline
        ;;
    --help)
        echo "Usage: ./dev/bench.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (none)      Run benchmarks and save results"
        echo "  --compare   Compare latest run against baseline"
        echo "  --baseline  Set current results as new baseline"
        echo "  --help      Show this help"
        ;;
    *)
        run_benchmarks
        ;;
esac
