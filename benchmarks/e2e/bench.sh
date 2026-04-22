#!/usr/bin/env bash
# Real end-to-end benchmark for Terraform plan performance.
#
# Builds the terraform binary from two branches (main vs optimized),
# generates a large config using terraform_data (built-in, no plugins),
# and measures wall-clock time for `terraform plan` across multiple runs.
#
# Usage: ./bench.sh [num_runs] [num_resources]
#   defaults: 5 runs, 500 resources

set -euo pipefail

RUNS="${1:-5}"
NUM_RESOURCES="${2:-500}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
CONFIG_DIR="$WORK_DIR/config"
RESULTS_DIR="$WORK_DIR/results"

MAIN_BRANCH="main"
OPT_BRANCH="codeflash/optimize"

MAIN_BIN="$WORK_DIR/terraform-main"
OPT_BIN="$WORK_DIR/terraform-opt"

mkdir -p "$RESULTS_DIR"

cleanup() {
  echo ""
  echo "Results saved in: $RESULTS_DIR"
  echo "Working dir (can be deleted): $WORK_DIR"
}
trap cleanup EXIT

echo "============================================"
echo " Terraform E2E Plan Benchmark"
echo "============================================"
echo " Repo:       $REPO_ROOT"
echo " Runs:       $RUNS"
echo " Resources:  ~$NUM_RESOURCES"
echo " Work dir:   $WORK_DIR"
echo "============================================"
echo ""

# --- Step 1: Build binaries ---
echo "[1/4] Building terraform binary from $MAIN_BRANCH..."
cd "$REPO_ROOT"
git stash --quiet 2>/dev/null || true
git checkout "$MAIN_BRANCH" --quiet
go build -o "$MAIN_BIN" . 2>&1
echo "  -> $MAIN_BIN ($(du -h "$MAIN_BIN" | cut -f1))"

echo "[1/4] Building terraform binary from $OPT_BRANCH..."
git checkout "$OPT_BRANCH" --quiet
go build -o "$OPT_BIN" . 2>&1
echo "  -> $OPT_BIN ($(du -h "$OPT_BIN" | cut -f1))"

# Return to opt branch
git checkout "$OPT_BRANCH" --quiet
git stash pop --quiet 2>/dev/null || true

# --- Step 2: Generate config ---
echo ""
echo "[2/4] Generating config with ~$NUM_RESOURCES resources..."
bash "$BENCH_DIR/generate_config.sh" "$CONFIG_DIR" "$NUM_RESOURCES"
echo "  Config dir: $CONFIG_DIR"
echo "  Files: $(find "$CONFIG_DIR" -name '*.tf' | wc -l) .tf files"
echo "  Lines: $(find "$CONFIG_DIR" -name '*.tf' -exec cat {} + | wc -l) total lines"

# --- Step 3: Run benchmarks ---
run_bench() {
  local label="$1"
  local binary="$2"
  local outfile="$3"

  echo ""
  echo "[3/4] Benchmarking: $label ($RUNS runs)..."

  # Initialize once (creates .terraform.lock.hcl etc)
  cd "$CONFIG_DIR"
  "$binary" init -input=false -no-color > /dev/null 2>&1 || true

  # Warm-up run (discard)
  "$binary" plan -input=false -no-color > /dev/null 2>&1

  local times=()
  for i in $(seq 1 "$RUNS"); do
    # Clear any cached state between runs
    rm -f "$CONFIG_DIR/terraform.tfstate" 2>/dev/null || true

    local start end elapsed
    start=$(date +%s%N)
    "$binary" plan -input=false -no-color > /dev/null 2>&1
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    times+=("$elapsed")
    echo "  Run $i: ${elapsed}ms"
  done

  # Write results
  printf "%s\n" "${times[@]}" > "$outfile"

  # Compute stats
  local sum=0 min=999999999 max=0
  for t in "${times[@]}"; do
    sum=$((sum + t))
    (( t < min )) && min=$t
    (( t > max )) && max=$t
  done
  local avg=$((sum / RUNS))

  # Compute median
  local sorted
  sorted=$(printf '%s\n' "${times[@]}" | sort -n)
  local mid=$((RUNS / 2))
  local median
  median=$(echo "$sorted" | sed -n "$((mid + 1))p")

  echo "  ---"
  echo "  Min: ${min}ms  Max: ${max}ms  Avg: ${avg}ms  Median: ${median}ms"
  echo "$label min=${min}ms max=${max}ms avg=${avg}ms median=${median}ms" >> "$RESULTS_DIR/summary.txt"
}

run_bench "main" "$MAIN_BIN" "$RESULTS_DIR/main_times.txt"
run_bench "optimized" "$OPT_BIN" "$RESULTS_DIR/opt_times.txt"

# --- Step 4: Compare ---
echo ""
echo "============================================"
echo "[4/4] Comparison"
echo "============================================"

read_stats() {
  local file="$1"
  local sum=0 count=0
  while read -r t; do
    sum=$((sum + t))
    count=$((count + 1))
  done < "$file"
  echo $((sum / count))
}

main_avg=$(read_stats "$RESULTS_DIR/main_times.txt")
opt_avg=$(read_stats "$RESULTS_DIR/opt_times.txt")

if [ "$main_avg" -gt 0 ]; then
  improvement=$(echo "scale=2; (($main_avg - $opt_avg) * 100) / $main_avg" | bc)
  abs_diff=$((main_avg - opt_avg))
else
  improvement="N/A"
  abs_diff=0
fi

echo ""
echo "  main branch:      avg ${main_avg}ms"
echo "  optimized branch: avg ${opt_avg}ms"
echo "  ---"
echo "  Difference:       ${abs_diff}ms (${improvement}%)"
echo ""

{
  echo ""
  echo "=== COMPARISON ==="
  echo "main:      avg ${main_avg}ms"
  echo "optimized: avg ${opt_avg}ms"
  echo "diff:      ${abs_diff}ms (${improvement}%)"
} >> "$RESULTS_DIR/summary.txt"

echo "Full results: $RESULTS_DIR/summary.txt"
echo ""
cat "$RESULTS_DIR/summary.txt"
