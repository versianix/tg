#!/usr/bin/env bash

# ===================================================================
# PostgreSQL Professional Benchmark Suite
# Developed for Bachelor's Thesis
# 
# This script executes robust benchmarks with:
# - Multiple workloads (TPC-B, Select-Only, Prepared Statements)
# - Prometheus/Grafana integration for monitoring
# - Error handling and automatic recovery
# - Detailed reports and statistical analysis
# - Support for horizontal/vertical scaling decisions
# ===================================================================

set -euo pipefail
IFS=$'\n\t'

# ===================================================================
# GLOBAL CONFIGURATION
# ===================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_CMD="${COMPOSE_CMD:-docker-compose}"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Docker Services
readonly PG_SERVICE="postgres"
readonly PGBENCH_SERVICE="pgbench"

# Database Configuration
readonly DBNAME="${POSTGRES_DB:-benchmark_db}"
readonly DBUSER="${POSTGRES_USER:-postgres}"
readonly PGPASSWORD="${POSTGRES_PASSWORD:-postgres}"

# Benchmark Configuration
readonly SCALE="${SCALE:-10}"
readonly DURATION="${DURATION:-15}"
readonly WARMUP_DURATION="${WARMUP_DURATION:-5}"
readonly REPEATS="${REPEATS:-2}"
readonly CLIENTS_ARRAY="${CLIENTS:-4,16,32}"
readonly JOBS_RATIO="${JOBS_RATIO:-2}"

# Directories
readonly BASE_DIR="${SCRIPT_DIR}/benchmark"
readonly RESULTS_DIR="${BASE_DIR}/results_${TIMESTAMP}"
readonly LOGS_DIR="${BASE_DIR}/logs_${TIMESTAMP}"
readonly REPORTS_DIR="${BASE_DIR}/reports_${TIMESTAMP}"

# Prometheus
readonly PROM_URL="${PROM_URL:-http://localhost:9090}"
readonly PROM_STEP="${PROM_STEP:-15}"

# Output Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# ===================================================================
# WORKLOAD CONFIGURATION
# ===================================================================

declare -ra SUITE_NAMES=("tpcb" "select_only" "simple_update")
declare -ra SUITE_FLAGS=("" "-S" "-N")
declare -ra SUITE_DESCRIPTIONS=(
    "TPC-B: Mixed read/write workload (OLTP)"
    "Select-Only: Read-heavy workload (OLAP)"
    "Simple Update: Write-heavy workload"
)

# ===================================================================
# UTILITY FUNCTIONS
# ===================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        "INFO")  echo -e "${CYAN}[INFO ]${NC} ${timestamp} - $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN ]${NC} ${timestamp} - $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" >&2 ;;
        "SUCCESS") echo -e "${GREEN}[OK   ]${NC} ${timestamp} - $message" ;;
        "DEBUG") [[ "${DEBUG:-0}" == "1" ]] && echo -e "${BLUE}[DEBUG]${NC} ${timestamp} - $message" ;;
    esac
}

show_banner() {
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                PostgreSQL Professional Benchmark                 ║
║                     Bachelor's Thesis                           ║
╠══════════════════════════════════════════════════════════════════╣
║  • Multiple workloads for comprehensive analysis                 ║
║  • Prometheus/Grafana integration                               ║
║  • Detailed reports for scaling decisions                       ║
║  • Automatic recovery on failures                               ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    local deps=("docker" "curl" "jq")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Missing dependencies: ${missing_deps[*]}"
        log "INFO" "Install with: brew install ${missing_deps[*]}"
        exit 1
    fi
    
    # Check if docker-compose exists
    if ! command -v "$COMPOSE_CMD" &> /dev/null; then
        log "ERROR" "Docker Compose not found: $COMPOSE_CMD"
        exit 1
    fi
    
    log "SUCCESS" "All dependencies verified"
}

setup_directories() {
    log "INFO" "Setting up directories..."
    
    mkdir -p "$RESULTS_DIR" "$LOGS_DIR" "$REPORTS_DIR"
    
    # Create symbolic link for latest
    local latest_results="${BASE_DIR}/latest_results"
    local latest_logs="${BASE_DIR}/latest_logs" 
    local latest_reports="${BASE_DIR}/latest_reports"
    
    [[ -L "$latest_results" ]] && rm "$latest_results"
    [[ -L "$latest_logs" ]] && rm "$latest_logs"
    [[ -L "$latest_reports" ]] && rm "$latest_reports"
    
    ln -sf "$(basename "$RESULTS_DIR")" "$latest_results"
    ln -sf "$(basename "$LOGS_DIR")" "$latest_logs"
    ln -sf "$(basename "$REPORTS_DIR")" "$latest_reports"
    
    log "SUCCESS" "Directories configured:"
    log "INFO" "  Results: $RESULTS_DIR"
    log "INFO" "  Logs:    $LOGS_DIR"
    log "INFO" "  Reports: $REPORTS_DIR"
}

cleanup_on_exit() {
    local exit_code=$?
    log "INFO" "Executing cleanup..."
    
    # Save PID of background processes if they exist (macOS compatible)
    local bg_jobs
    bg_jobs=$(jobs -p 2>/dev/null || true)
    if [[ -n "$bg_jobs" ]]; then
        echo "$bg_jobs" | xargs kill 2>/dev/null || true
    fi
    
    # Generate report only if there are results AND functions are available AND not already generated
    if [[ -d "${RESULTS_DIR:-}" ]] && [[ $(find "${RESULTS_DIR:-}" -name "*.txt" 2>/dev/null | wc -l) -gt 0 ]] && declare -f generate_final_report >/dev/null 2>&1 && [[ "${REPORT_GENERATED:-0}" != "1" ]]; then
        log "INFO" "Generating final report..."
        generate_final_report 2>/dev/null || log "WARN" "Failed to generate final report"
        export REPORT_GENERATED=1
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Script finished with error (code: $exit_code)"
        log "INFO" "Check logs at: ${LOGS_DIR:-./logs}"
    else
        log "SUCCESS" "Script completed successfully"
    fi
    
    exit $exit_code
}

handle_interrupt() {
    log "WARN" "Interrupt detected (Ctrl+C). Shutting down gracefully..."
    cleanup_on_exit
}

# ===================================================================
# DOCKER FUNCTIONS
# ===================================================================

check_docker_services() {
    log "INFO" "Checking Docker services..."
    
    if ! docker info &>/dev/null; then
        log "ERROR" "Docker is not running"
        exit 1
    fi
    
    # Check if docker-compose.yml exists
    if [[ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        log "ERROR" "docker-compose.yml not found in ${SCRIPT_DIR}"
        exit 1
    fi
    
    log "SUCCESS" "Docker configured correctly"
}

start_services() {
    log "INFO" "Starting required services..."
    
    # Start only pgbench service (keep others as they are)
    if ! $COMPOSE_CMD up -d "$PGBENCH_SERVICE" 2>"$LOGS_DIR/docker_startup.log"; then
        log "ERROR" "Failed to start service $PGBENCH_SERVICE"
        cat "$LOGS_DIR/docker_startup.log"
        exit 1
    fi
    
    # Wait for services to be ready
    log "INFO" "Waiting for services to be ready..."
    sleep 5
    
    # Check if PostgreSQL is responding
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if $COMPOSE_CMD exec -T "$PGBENCH_SERVICE" pg_isready -h "$PG_SERVICE" -U "$DBUSER" &>/dev/null; then
            log "SUCCESS" "PostgreSQL is ready"
            break
        fi
        
        log "INFO" "Attempt $attempt/$max_attempts - Waiting for PostgreSQL..."
        sleep 2
        ((attempt++))
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        log "ERROR" "PostgreSQL did not respond after $max_attempts attempts"
        exit 1
    fi
}

# ===================================================================
# BENCHMARK FUNCTIONS
# ===================================================================

initialize_pgbench() {
    log "INFO" "Initializing pgbench data (scale: $SCALE)..."
    
    local init_log="$LOGS_DIR/pgbench_init.log"
    
    if ! $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
        pgbench -i -s "$SCALE" -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" \
        > "$init_log" 2>&1; then
        
        log "ERROR" "Failed to initialize pgbench"
        tail -n 20 "$init_log"
        exit 1
    fi
    
    log "SUCCESS" "Data initialized successfully"
    log "DEBUG" "Initialization log: $init_log"
    
    # Show initialization statistics
    local init_stats
    init_stats=$(tail -n 5 "$init_log" | grep -E "(done in|tables)" || true)
    if [[ -n "$init_stats" ]]; then
        log "INFO" "Initialization statistics:"
        echo "$init_stats" | while IFS= read -r line; do
            log "INFO" "  $line"
        done
    fi
}

run_warmup() {
    local suite="$1"
    local flags="$2"
    local clients="$3"
    local jobs="$4"
    
    log "INFO" "Running warmup - Suite: $suite, Clients: $clients, Jobs: $jobs"
    
    local warmup_log="$LOGS_DIR/warmup_${suite}_c${clients}_j${jobs}.log"
    
    $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
        pgbench ${flags} -c "$clients" -j "$jobs" -T "$WARMUP_DURATION" \
        -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" \
        > "$warmup_log" 2>&1 || {
        
        log "WARN" "Warmup failed - continuing anyway"
        log "DEBUG" "Warmup log: $warmup_log"
        return 1
    }
    
    log "SUCCESS" "Warmup completed"
    return 0
}

collect_prometheus_metrics() {
    local start_ts="$1"
    local end_ts="$2"
    local output_prefix="$3"
    
    # Check if Prometheus is available first
    if ! curl -s --connect-timeout 5 "$PROM_URL/api/v1/status/config" >/dev/null 2>&1; then
        log "INFO" "Prometheus not available - skipping metrics collection (benchmark continues normally)"
        return 0
    fi
    
    log "DEBUG" "Collecting Prometheus metrics..."
    
        # Define queries using metrics that actually exist in your environment
    local queries_names=("cpu_usage" "memory_usage" "disk_io_time" "disk_read_bytes" "disk_write_bytes" "pg_locks")
    local queries_values=(
        '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])))'
        '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100'
        'avg(rate(node_disk_io_time_seconds_total[1m])) * 100'
        'sum(rate(node_disk_read_bytes_total[1m]))'
        'sum(rate(node_disk_written_bytes_total[1m]))'
        'sum(pg_locks_count{datname="benchmark_db"})'
    )
    
    local collected_count=0
    local total_count=${#queries_names[@]}
    
    for i in "${!queries_names[@]}"; do
        local metric_name="${queries_names[$i]}"
        local query="${queries_values[$i]}"
        local output_file="${output_prefix}_${metric_name}.json"
        
        # Use timeout to avoid hanging
        if timeout 10 curl -s --get \
            --data-urlencode "query=$query" \
            --data-urlencode "start=$start_ts" \
            --data-urlencode "end=$end_ts" \
            --data-urlencode "step=$PROM_STEP" \
            "$PROM_URL/api/v1/query_range" \
            -o "$output_file" 2>/dev/null; then
            
            ((collected_count++))
            log "DEBUG" "Metric collected: $metric_name"
        else
            log "DEBUG" "Skipped metric: $metric_name"
        fi
    done
    
    if [[ $collected_count -gt 0 ]]; then
        log "DEBUG" "Collected $collected_count/$total_count Prometheus metrics"
    else
        log "INFO" "No Prometheus metrics collected - ensure monitoring stack is running for enhanced analysis"
    fi
}

run_benchmark_test() {
    local suite="$1"
    local flags="$2"
    local clients="$3"
    local jobs="$4"
    local run_number="$5"
    
    local run_id="${TIMESTAMP}_${suite}_c${clients}_j${jobs}_run${run_number}"
    local result_file="$RESULTS_DIR/${run_id}.txt"
    local log_file="$LOGS_DIR/${run_id}.log"
    local metrics_prefix="$RESULTS_DIR/${run_id}_metrics"
    
    log "INFO" "Running test $run_number - $suite (c:$clients, j:$jobs)"
    
    # Start timestamp
    local start_ts
    start_ts=$(date +%s)
    
    # Execute pgbench
    if $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
        pgbench ${flags} -c "$clients" -j "$jobs" -T "$DURATION" -r \
        -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" \
        > "$result_file" 2> "$log_file"; then
        
        local end_ts
        end_ts=$(date +%s)
        
        # Collect Prometheus metrics
        collect_prometheus_metrics "$start_ts" "$end_ts" "$metrics_prefix"
        
        # Extract TPS from result
        local tps
        tps=$(grep "tps = " "$result_file" | awk '{print $3}' || echo "N/A")
        
        log "SUCCESS" "Test completed - TPS: $tps"
        return 0
    else
        log "ERROR" "Test failed $run_id"
        log "DEBUG" "Error log: $log_file"
        return 1
    fi
}

# ===================================================================
# REPORT FUNCTIONS
# ===================================================================

parse_pgbench_result() {
    local result_file="$1"
    
    if [[ ! -f "$result_file" ]]; then
        echo "N/A,N/A,N/A,N/A"
        return
    fi
    
    local tps latency_avg failed_trans duration
    
    tps=$(grep "tps = " "$result_file" | head -n1 | awk '{print $3}' | sed 's/[^0-9.]//g' || echo "0")
    latency_avg=$(grep "latency average" "$result_file" | awk '{print $4}' | sed 's/[^0-9.]//g' || echo "0")
    failed_trans=$(grep "number of failed transactions" "$result_file" | awk '{print $6}' | sed 's/[^0-9.]//g' || echo "0")
    duration=$(grep "duration:" "$result_file" | awk '{print $3}' | sed 's/[^0-9.]//g' || echo "0")
    
    echo "$tps,$latency_avg,$failed_trans,$duration"
}

generate_csv_report() {
    local csv_file="$REPORTS_DIR/benchmark_results.csv"
    
    log "INFO" "Generating CSV report..."
    
    # Header
    echo "Suite,Clients,Jobs,Run,TPS,Latency_Avg_ms,Failed_Trans,Duration_s,Timestamp" > "$csv_file"
    
    # Process results
    for result_file in "$RESULTS_DIR"/*.txt; do
        [[ ! -f "$result_file" ]] && continue
        
        local filename
        filename=$(basename "$result_file" .txt)
        
        # Extract information from filename
        if [[ $filename =~ ([0-9]+_[0-9]+)_([^_]+)_c([0-9]+)_j([0-9]+)_run([0-9]+) ]]; then
            local timestamp="${BASH_REMATCH[1]}"
            local suite="${BASH_REMATCH[2]}"
            local clients="${BASH_REMATCH[3]}"
            local jobs="${BASH_REMATCH[4]}"
            local run="${BASH_REMATCH[5]}"
            
            local metrics
            metrics=$(parse_pgbench_result "$result_file")
            
            echo "$suite,$clients,$jobs,$run,$metrics,$timestamp" >> "$csv_file"
        fi
    done
    
    log "SUCCESS" "CSV report generated: $csv_file"
}

generate_summary_statistics() {
    local summary_file="$REPORTS_DIR/summary_statistics.txt"
    
    log "INFO" "Generating summary statistics..."
    
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "                    BENCHMARK STATISTICAL SUMMARY"
        echo "═══════════════════════════════════════════════════════════════"
        echo "Timestamp: $(date)"
        echo "Scale Factor: $SCALE"
        echo "Duration per test: ${DURATION}s"
        echo "Warmup duration: ${WARMUP_DURATION}s"
        echo "Repetitions: $REPEATS"
        echo ""
        
        # Analysis by suite and client configuration
        for suite_idx in "${!SUITE_NAMES[@]}"; do
            local suite="${SUITE_NAMES[$suite_idx]}"
            local description="${SUITE_DESCRIPTIONS[$suite_idx]}"
            
            echo "┌─ $suite: $description"
            
            IFS=',' read -ra clients_arr <<< "$CLIENTS_ARRAY"
            for clients in "${clients_arr[@]}"; do
                echo "├── $clients clients:"
                
                # Find files for this configuration
                local tps_values=()
                local latency_values=()
                
                for result_file in "$RESULTS_DIR"/*_"${suite}"_c"${clients}"_*.txt; do
                    [[ ! -f "$result_file" ]] && continue
                    
                    local metrics
                    metrics=$(parse_pgbench_result "$result_file")
                    IFS=',' read -ra metric_arr <<< "$metrics"
                    
                    if [[ "${metric_arr[0]}" != "N/A" && "${metric_arr[0]}" != "0" ]]; then
                        tps_values+=("${metric_arr[0]}")
                    fi
                    
                    if [[ "${metric_arr[1]}" != "N/A" && "${metric_arr[1]}" != "0" ]]; then
                        latency_values+=("${metric_arr[1]}")
                    fi
                done
                
                if [[ ${#tps_values[@]} -gt 0 ]]; then
                    # Calculate basic statistics using awk
                    local tps_stats
                    tps_stats=$(printf '%s\n' "${tps_values[@]}" | awk '
                        {sum+=$1; sumsq+=$1*$1; if($1>max || NR==1) max=$1; if($1<min || NR==1) min=$1}
                        END {
                            avg=sum/NR;
                            stddev=sqrt((sumsq-sum*sum/NR)/NR);
                            printf "Avg: %.2f, Min: %.2f, Max: %.2f, StdDev: %.2f", avg, min, max, stddev
                        }')
                    
                    echo "│   ├─ TPS: $tps_stats"
                    
                    local latency_stats
                    latency_stats=$(printf '%s\n' "${latency_values[@]}" | awk '
                        {sum+=$1; sumsq+=$1*$1; if($1>max || NR==1) max=$1; if($1<min || NR==1) min=$1}
                        END {
                            avg=sum/NR;
                            stddev=sqrt((sumsq-sum*sum/NR)/NR);
                            printf "Avg: %.2f, Min: %.2f, Max: %.2f, StdDev: %.2f", avg, min, max, stddev
                        }')
                    
                    echo "│   └─ Latency (ms): $latency_stats"
                else
                    echo "│   └─ No valid results found"
                fi
            done
            echo ""
        done
        
        echo "═══════════════════════════════════════════════════════════════"
        echo "                    SCALING RECOMMENDATIONS"
        echo "═══════════════════════════════════════════════════════════════"
        
        # Automatic analysis for recommendations
        echo "Based on benchmark results:"
        echo ""
        
        # Find performance peak
        local max_tps=0
        local optimal_clients=0
        local optimal_suite=""
        
        IFS=',' read -ra clients_arr <<< "$CLIENTS_ARRAY"
        for suite in "${SUITE_NAMES[@]}"; do
            for clients in "${clients_arr[@]}"; do
                for result_file in "$RESULTS_DIR"/*_"${suite}"_c"${clients}"_*.txt; do
                    [[ ! -f "$result_file" ]] && continue
                    
                    local metrics
                    metrics=$(parse_pgbench_result "$result_file")
                    IFS=',' read -ra metric_arr <<< "$metrics"
                    
                    local tps="${metric_arr[0]}"
                    if [[ "$tps" != "N/A" && "$tps" != "0" ]]; then
                        if (( $(echo "$tps > $max_tps" | bc -l) )); then
                            max_tps="$tps"
                            optimal_clients="$clients"
                            optimal_suite="$suite"
                        fi
                    fi
                done
            done
        done
        
        echo "• Performance peak: $max_tps TPS with $optimal_clients clients ($optimal_suite)"
        echo ""
        
        if (( optimal_clients <= 16 )); then
            echo "• RECOMMENDATION: VERTICAL SCALING"
            echo "  - Maximum performance with few clients suggests CPU/RAM limitation"
            echo "  - Consider increasing CPU cores and memory RAM"
            echo "  - Optimize PostgreSQL configuration (shared_buffers, work_mem)"
        else
            echo "• RECOMMENDATION: HORIZONTAL SCALING"
            echo "  - Maximum performance with many clients suggests good parallelization"
            echo "  - Consider implementing read replicas or sharding"
            echo "  - Implement connection pooling (PgBouncer)"
        fi
        
        echo ""
        echo "• For detailed analysis, check Grafana charts:"
        echo "  http://localhost:3000"
        echo ""
        
    } > "$summary_file"
    
    log "SUCCESS" "Statistics generated: $summary_file"
}

generate_final_report() {
    log "INFO" "Generating final report..."
    
    generate_csv_report
    generate_summary_statistics
    
    # Create simple HTML index file
    local html_file="$REPORTS_DIR/index.html"
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>PostgreSQL Benchmark Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #333; }
        .section { margin: 20px 0; padding: 15px; border: 1px solid #ddd; }
        .files { background-color: #f9f9f9; }
        a { color: #0066cc; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>PostgreSQL Benchmark Report</h1>
    <p>Generated at: $(date)</p>
    
    <div class="section">
        <h2>Quick Access</h2>
        <ul>
            <li><a href="benchmark_results.csv">CSV Results</a></li>
            <li><a href="summary_statistics.txt">Summary Statistics</a></li>
            <li><a href="http://localhost:3000" target="_blank">Grafana Dashboard</a></li>
            <li><a href="http://localhost:9090" target="_blank">Prometheus Metrics</a></li>
        </ul>
    </div>
    
    <div class="section files">
        <h2>Configuration</h2>
        <ul>
            <li>Scale Factor: $SCALE</li>
            <li>Test Duration: ${DURATION}s</li>
            <li>Warmup Duration: ${WARMUP_DURATION}s</li>
            <li>Repetitions: $REPEATS</li>
            <li>Client Configurations: $CLIENTS_ARRAY</li>
        </ul>
    </div>
</body>
</html>
EOF
    
    log "SUCCESS" "HTML report generated: $html_file"
    log "INFO" "════════════════════════════════════════════════════════════════"
    log "INFO" "                     BENCHMARK COMPLETED"
    log "INFO" "════════════════════════════════════════════════════════════════"
    log "INFO" "Results available at:"
    log "INFO" "  • Report: file://$html_file"
    log "INFO" "  • CSV: $REPORTS_DIR/benchmark_results.csv"
    log "INFO" "  • Statistics: $REPORTS_DIR/summary_statistics.txt"
    log "INFO" "  • Grafana: http://localhost:3000"
    log "INFO" "════════════════════════════════════════════════════════════════"
}

# ===================================================================
# MAIN FUNCTION
# ===================================================================

run_benchmark_suite() {
    local total_tests=0
    local completed_tests=0
    local failed_tests=0
    
    # Calculate total tests
    IFS=',' read -ra clients_arr <<< "$CLIENTS_ARRAY"
    total_tests=$(( ${#SUITE_NAMES[@]} * ${#clients_arr[@]} * REPEATS ))
    
    log "INFO" "Starting benchmark suite:"
    log "INFO" "  • Suites: ${#SUITE_NAMES[@]} (${SUITE_NAMES[*]})"
    log "INFO" "  • Client configurations: ${#clients_arr[@]} (${clients_arr[*]})"
    log "INFO" "  • Repetitions per configuration: $REPEATS"
    log "INFO" "  • Total tests: $total_tests"
    log "INFO" "  • Estimated time: $(( total_tests * (DURATION + WARMUP_DURATION + 10) / 60 )) minutes"
    log "INFO" "  • Note: Prometheus warnings are non-critical - pgBench results will still be captured"
    echo ""
    
    for suite_idx in "${!SUITE_NAMES[@]}"; do
        local suite="${SUITE_NAMES[$suite_idx]}"
        local flags="${SUITE_FLAGS[$suite_idx]}"
        local description="${SUITE_DESCRIPTIONS[$suite_idx]}"
        
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}Suite: $suite - $description${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        
        # Additional cleanup between different suites
        if [[ $suite_idx -gt 0 ]]; then
            log "INFO" "Running cleanup between workloads..."
            $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
                psql -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" -c "VACUUM ANALYZE;" >/dev/null 2>&1 || true
        fi
        
        for clients in "${clients_arr[@]}"; do
            local jobs=$(( clients / JOBS_RATIO ))
            [[ $jobs -lt 1 ]] && jobs=1
            
            log "INFO" "Configuration: $clients clients, $jobs jobs"
            
            # Warmup
            if ! run_warmup "$suite" "$flags" "$clients" "$jobs"; then
                log "WARN" "Warmup failed, but continuing..."
            fi
            
            # Execute repetitions
            for run in $(seq 1 "$REPEATS"); do
                local progress="$(( completed_tests + 1 ))/$total_tests"
                log "INFO" "Progress: $progress - Running test $run..."
                
                if run_benchmark_test "$suite" "$flags" "$clients" "$jobs" "$run"; then
                    ((completed_tests++))
                    log "SUCCESS" "Run $run completed ($progress)"
                else
                    ((failed_tests++))
                    log "ERROR" "Run $run failed ($progress)"
                fi
                
                # Brief pause between tests
                sleep 3
            done
            
            echo ""
        done
    done
    
    log "INFO" "Benchmark suite completed:"
    log "INFO" "  • Tests completed: $completed_tests/$total_tests"
    log "INFO" "  • Tests failed: $failed_tests"
    
    if [[ $failed_tests -gt 0 ]]; then
        log "WARN" "Some tests failed. Check logs at $LOGS_DIR"
    fi
}

# ===================================================================
# MAIN
# ===================================================================

main() {
    # Configure signal handling
    trap handle_interrupt SIGINT SIGTERM
    trap cleanup_on_exit EXIT
    
    show_banner
    
    # Initial checks with error handling
    if ! check_dependencies; then
        log "ERROR" "Failed dependency check"
        exit 1
    fi
    
    if ! check_docker_services; then
        log "ERROR" "Failed Docker services check"
        exit 1
    fi
    
    if ! setup_directories; then
        log "ERROR" "Failed directory setup"
        exit 1
    fi
    
    # Save current configuration
    {
        echo "Benchmark Configuration"
        echo "======================="
        echo "Timestamp: $(date)"
        echo "Scale Factor: $SCALE"
        echo "Duration: ${DURATION}s"
        echo "Warmup: ${WARMUP_DURATION}s"
        echo "Repetitions: $REPEATS"
        echo "Clients: $CLIENTS_ARRAY"
        echo "Jobs Ratio: $JOBS_RATIO"
        echo "Docker Compose: $COMPOSE_CMD"
        echo "Prometheus URL: $PROM_URL"
        echo ""
        echo "Configured Suites:"
        for i in "${!SUITE_NAMES[@]}"; do
            echo "  ${SUITE_NAMES[$i]}: ${SUITE_DESCRIPTIONS[$i]}"
        done
    } > "$LOGS_DIR/benchmark_config.txt"
    
    # Initialize environment with error handling
    if ! start_services; then
        log "ERROR" "Failed to start services"
        exit 1
    fi
    
    if ! initialize_pgbench; then
        log "ERROR" "Failed pgbench initialization"
        exit 1
    fi
    
    # Execute benchmark
    run_benchmark_suite
    
    # Generate reports
    generate_final_report
    export REPORT_GENERATED=1
}

# Check if script is being executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
