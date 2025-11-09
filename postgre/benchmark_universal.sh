 #!/usr/bin/env bash

# ===================================================================
# Universal Database Benchmark Suite
# Supports PostgreSQL and Citus with automatic detection
# Developed for Graduate Thesis
# 
# This script executes agnostic benchmarks that work on both:
# - PostgreSQL standalone
# - Citus (distributed PostgreSQL)
# 
# Features:
# - Auto-detection of database type
# - Specific workloads for each architecture
# - Prometheus/Grafana integration
# - Comparative reports
# - Distribution metrics for Citus
# ===================================================================

set -euo pipefail
IFS=$'\n\t'

# ===================================================================
# GLOBAL CONFIGURATIONS
# ===================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_CMD="${COMPOSE_CMD:-docker-compose}"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Database configurations (will be detected automatically)
DBNAME="${POSTGRES_DB:-}"
readonly DBUSER="${POSTGRES_USER:-postgres}"
readonly PGPASSWORD="${POSTGRES_PASSWORD:-postgres}"

# Benchmark configurations (optimized for fast execution)
readonly SCALE="${SCALE:-10}"
readonly DURATION="${DURATION:-15}"
readonly WARMUP_DURATION="${WARMUP_DURATION:-5}"
readonly REPEATS="${REPEATS:-2}"
readonly CLIENTS_ARRAY="${CLIENTS:-4,16}"
readonly JOBS_RATIO="${JOBS_RATIO:-2}"

# Directories
readonly BASE_DIR="${SCRIPT_DIR}/benchmark_universal"
readonly RESULTS_DIR="${BASE_DIR}/results_${TIMESTAMP}"
readonly LOGS_DIR="${BASE_DIR}/logs_${TIMESTAMP}"
readonly REPORTS_DIR="${BASE_DIR}/reports_${TIMESTAMP}"

# Prometheus
readonly PROM_URL="${PROM_URL:-http://localhost:9090}"
readonly PROM_STEP="${PROM_STEP:-15}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Global variables (will be defined during detection)
DB_TYPE=""           # "postgresql" or "citus"
DB_HOST=""           # Primary database host
DB_PORT=""           # Primary database port
BENCHMARK_SERVICE="" # Benchmark service name in compose
WORKER_HOSTS=()      # Array with worker hosts (Citus only)

# ===================================================================
# UNIVERSAL WORKLOAD CONFIGURATIONS (COMPARABLE)
# ===================================================================

# Base workloads - same for PostgreSQL and Citus (optimized for speed)
declare -ra BASE_SUITE_NAMES=("tpcb" "select_only" "simple_update")
declare -ra BASE_SUITE_FLAGS=("" "-S" "-N")
declare -ra BASE_SUITE_DESCRIPTIONS=(
    "TPC-B: Mixed read/write workload (OLTP)"
    "Select-Only: Read-heavy workload (OLAP)" 
    "Simple Update: Write-heavy workload"
)

# Citus-specific workloads (removed for simplification)
declare -ra CITUS_EXTRA_NAMES=()
declare -ra CITUS_EXTRA_FLAGS=()
declare -ra CITUS_EXTRA_DESCRIPTIONS=()

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
║                Universal Database Benchmark                      ║
║              PostgreSQL & Citus Compatible                      ║
╠══════════════════════════════════════════════════════════════════╣
║  • Auto-detection of architecture (PostgreSQL/Citus)           ║
║  • Specific workloads for each type                             ║
║  • Distribution metrics for clusters                            ║
║  • Comparative reports and recommendations                      ║
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
    
    if ! command -v "$COMPOSE_CMD" &> /dev/null; then
        log "ERROR" "Docker Compose not found: $COMPOSE_CMD"
        exit 1
    fi
    
    log "SUCCESS" "All dependencies verified"
}

# ===================================================================
# ENVIRONMENT DETECTION
# ===================================================================

detect_database_type() {
    log "INFO" "Detecting database type..."
    
    # Check if we're in postgre or citus folder
    local current_dir
    current_dir=$(basename "$PWD")
    
    if [[ -f "docker-compose.yml" ]]; then
        # Analyze docker-compose.yml to detect type
        if grep -q "citusdata/citus" docker-compose.yml; then
            DB_TYPE="citus"
            DBNAME="${POSTGRES_DB:-citus_platform}"
            DB_HOST="coordinator"
            DB_PORT="5432"
            BENCHMARK_SERVICE="coordinator"
            
            # Detect workers
            local workers
            workers=$(grep -E "worker[0-9]+" docker-compose.yml | grep "hostname:" | awk '{print $2}' || true)
            if [[ -n "$workers" ]]; then
                while IFS= read -r worker; do
                    WORKER_HOSTS+=("$worker")
                done <<< "$workers"
            fi
            
        elif grep -q "postgres:" docker-compose.yml || grep -q "image: postgres" docker-compose.yml; then
            DB_TYPE="postgresql"
            DBNAME="${POSTGRES_DB:-mydb}"
            DB_HOST="postgres"
            DB_PORT="5432"
            BENCHMARK_SERVICE="postgres"
        else
            log "ERROR" "Database type not recognized in docker-compose.yml"
            exit 1
        fi
    else
        log "ERROR" "docker-compose.yml not found in current directory"
        log "INFO" "Run the script in 'postgre' or 'citus' folder"
        exit 1
    fi
    
    log "SUCCESS" "Database detected: $DB_TYPE"
    log "INFO" "Configuration:"
    log "INFO" "  • Type: $DB_TYPE"
    log "INFO" "  • Database: $DBNAME"
    log "INFO" "  • Host: $DB_HOST:$DB_PORT"
    log "INFO" "  • Benchmark service: $BENCHMARK_SERVICE"
    
    if [[ "$DB_TYPE" == "citus" && ${#WORKER_HOSTS[@]} -gt 0 ]]; then
        log "INFO" "  • Workers: ${WORKER_HOSTS[*]}"
    fi
}

setup_directories() {
    log "INFO" "Setting up directories..."
    
    mkdir -p "$RESULTS_DIR" "$LOGS_DIR" "$REPORTS_DIR"
    
    # Create symbolic links for latest
    local latest_results="${BASE_DIR}/latest_results"
    local latest_logs="${BASE_DIR}/latest_logs" 
    local latest_reports="${BASE_DIR}/latest_reports"
    
    [[ -L "$latest_results" ]] && rm "$latest_results"
    [[ -L "$latest_logs" ]] && rm "$latest_logs"
    [[ -L "$latest_reports" ]] && rm "$latest_reports"
    
    ln -sf "$(basename "$RESULTS_DIR")" "$latest_results"
    ln -sf "$(basename "$LOGS_DIR")" "$latest_logs"
    ln -sf "$(basename "$REPORTS_DIR")" "$latest_reports"
    
    log "SUCCESS" "Directories configured"
}

# ===================================================================
# DATABASE SETUP FUNCTIONS
# ===================================================================

check_database_connection() {
    log "INFO" "Checking database connection..."
    
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if $COMPOSE_CMD exec -T "$BENCHMARK_SERVICE" pg_isready -h "$DB_HOST" -U "$DBUSER" -d "$DBNAME" &>/dev/null; then
            log "SUCCESS" "Connection to $DB_TYPE established"
            return 0
        fi
        
        log "INFO" "Attempt $attempt/$max_attempts - Waiting for $DB_TYPE..."
        sleep 2
        ((attempt++))
    done
    
    log "ERROR" "$DB_TYPE did not respond after $max_attempts attempts"
    return 1
}

setup_citus_cluster() {
    if [[ "$DB_TYPE" != "citus" ]]; then
        return 0
    fi
    
    log "INFO" "Setting up Citus cluster..."
    
    # Check if Citus extension is loaded
    local citus_check
    citus_check=$($COMPOSE_CMD exec -T "$BENCHMARK_SERVICE" psql -h "$DB_HOST" -U "$DBUSER" -d "$DBNAME" -tAc "SELECT count(*) FROM pg_extension WHERE extname='citus';" || echo "0")
    
    if [[ "$citus_check" == "0" ]]; then
        log "INFO" "Enabling Citus extension..."
        $COMPOSE_CMD exec -T "$BENCHMARK_SERVICE" psql -h "$DB_HOST" -U "$DBUSER" -d "$DBNAME" -c "CREATE EXTENSION IF NOT EXISTS citus;" >/dev/null
    fi
    
    # Add workers to cluster
    for worker in "${WORKER_HOSTS[@]}"; do
        log "INFO" "Adding worker: $worker"
        $COMPOSE_CMD exec -T "$BENCHMARK_SERVICE" psql -h "$DB_HOST" -U "$DBUSER" -d "$DBNAME" \
            -c "SELECT citus_add_node('$worker', 5432);" 2>/dev/null || {
            log "WARN" "Worker $worker already added or connection failed"
        }
    done
    
    # Check nodes
    local node_count
    node_count=$($COMPOSE_CMD exec -T "$BENCHMARK_SERVICE" psql -h "$DB_HOST" -U "$DBUSER" -d "$DBNAME" -tAc "SELECT count(*) FROM pg_dist_node WHERE isactive;" || echo "0")
    log "SUCCESS" "Citus cluster configured with $node_count active nodes"
}

initialize_benchmark_data() {
    log "INFO" "Initializing benchmark data..."
    
    if [[ "$DB_TYPE" == "postgresql" ]]; then
        # Standard PostgreSQL - use traditional pgbench
        log "INFO" "Initializing standard pgbench (scale: $SCALE)..."
        
        $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$BENCHMARK_SERVICE" \
            pgbench -i -s "$SCALE" -U "$DBUSER" -h "$DB_HOST" "$DBNAME" \
            > "$LOGS_DIR/pgbench_init.log" 2>&1
            
    elif [[ "$DB_TYPE" == "citus" ]]; then
        # Citus - initialize and distribute tables
        log "INFO" "Initializing distributed data for Citus..."
        
        # First, initialize data locally on coordinator
        $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$BENCHMARK_SERVICE" \
            pgbench -i -s "$SCALE" -U "$DBUSER" -h "$DB_HOST" "$DBNAME" \
            > "$LOGS_DIR/pgbench_init.log" 2>&1
        
        # Distribute pgbench tables (simple and direct)
        log "INFO" "Distributing pgbench tables..."
        $COMPOSE_CMD exec -T "$BENCHMARK_SERVICE" psql -h "$DB_HOST" -U "$DBUSER" -d "$DBNAME" -c "
            SELECT create_distributed_table('pgbench_accounts', 'aid');
            SELECT create_distributed_table('pgbench_branches', 'bid');  
            SELECT create_distributed_table('pgbench_tellers', 'tid');
            SELECT create_distributed_table('pgbench_history', 'aid');
        " >> "$LOGS_DIR/citus_distribution.log" 2>&1
    fi
    
    log "SUCCESS" "Data initialized successfully"
}

# ===================================================================
# SPECIFIC WORKLOADS
# ===================================================================

get_workload_config() {
    local workload_type="$1"
    
    case "$workload_type" in
        "tpcb")
            echo ""  # Flags padrão do pgbench TPC-B
            ;;
        "select_only") 
            echo "-S"  # Select-only workload
            ;;
        "simple_update")
            echo "-N"  # Simple update workload
            ;;
        "prepared_statements")
            echo "-M prepared"  # Prepared statements
            ;;
        "cross_shard_join")
            # Custom workload for Citus - cross-shard JOINs
            create_custom_script "cross_shard_join"
            echo "-f $LOGS_DIR/cross_shard_join.sql"
            ;;
        "distributed_analytics")
            # Distributed analytical workload for Citus
            create_custom_script "distributed_analytics"
            echo "-f $LOGS_DIR/distributed_analytics.sql"
            ;;
        *)
            echo ""
            ;;
    esac
}

create_custom_script() {
    local script_type="$1"
    local script_file="$LOGS_DIR/${script_type}.sql"
    
    case "$script_type" in
        "cross_shard_join")
            cat > "$script_file" << 'EOF'
-- Cross-shard JOIN workload for Citus
\set aid1 random(1, 100000 * :scale)
\set aid2 random(1, 100000 * :scale)

-- JOIN between distributed tables (may cross shards)
SELECT 
    a1.aid as account1,
    a1.abalance as balance1,
    a2.aid as account2, 
    a2.abalance as balance2,
    h.delta
FROM pgbench_accounts a1
JOIN pgbench_history h ON a1.aid = h.aid
JOIN pgbench_accounts a2 ON h.tid = (a2.aid % 10 + 1)
WHERE a1.aid = :aid1 AND a2.aid = :aid2
LIMIT 5;
EOF
            ;;
        "distributed_analytics")
            cat > "$script_file" << 'EOF'
-- Distributed analytics workload for Citus
\set branch_id random(1, :scale)

-- Aggregation across distributed tables
SELECT 
    b.bid,
    COUNT(a.aid) as account_count,
    AVG(a.abalance) as avg_balance,
    SUM(h.delta) as total_transactions,
    COUNT(DISTINCT h.tid) as unique_tellers
FROM pgbench_branches b
JOIN pgbench_accounts a ON b.bid = a.bid
JOIN pgbench_history h ON a.aid = h.aid
WHERE b.bid = :branch_id
GROUP BY b.bid
ORDER BY total_transactions DESC;
EOF
            ;;
    esac
}

# ===================================================================
# BENCHMARK EXECUTION
# ===================================================================

run_warmup() {
    local suite="$1"
    local flags="$2"
    local clients="$3"
    local jobs="$4"
    
    log "INFO" "Running warmup - Suite: $suite, Clients: $clients"
    
    local warmup_log="$LOGS_DIR/warmup_${suite}_c${clients}_j${jobs}.log"
    
    $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$BENCHMARK_SERVICE" \
        pgbench ${flags} -c "$clients" -j "$jobs" -T "$WARMUP_DURATION" \
        -U "$DBUSER" -h "$DB_HOST" "$DBNAME" \
        > "$warmup_log" 2>&1 || {
        
        log "WARN" "Warmup failed - continuing anyway"
        return 1
    }
    
    log "SUCCESS" "Warmup completed"
    return 0
}

collect_citus_metrics() {
    if [[ "$DB_TYPE" != "citus" ]]; then
        return 0
    fi
    
    local output_file="$1"
    
    log "DEBUG" "Collecting Citus-specific metrics..."
    
    # Collect distribution statistics
    $COMPOSE_CMD exec -T "$BENCHMARK_SERVICE" psql -h "$DB_HOST" -U "$DBUSER" -d "$DBNAME" -c "
        SELECT 
            schemaname,
            tablename,
            shardcount,
            replicationfactor
        FROM citus_tables;
        
        SELECT 
            nodename,
            nodeport,
            isactive,
            noderole
        FROM pg_dist_node;
        
        SELECT 
            shardid,
            shardlength,
            nodename,
            nodeport
        FROM pg_dist_placement pdp
        JOIN pg_dist_node pdn ON pdp.groupid = pdn.groupid
        ORDER BY shardid
        LIMIT 10;
    " > "$output_file" 2>&1
}

run_benchmark_test() {
    local suite="$1"
    local clients="$2" 
    local jobs="$3"
    local run_number="$4"
    
    local flags
    flags=$(get_workload_config "$suite")
    
    local run_id="${TIMESTAMP}_${suite}_c${clients}_j${jobs}_run${run_number}"
    local result_file="$RESULTS_DIR/${run_id}.txt"
    local log_file="$LOGS_DIR/${run_id}.log"
    local citus_metrics_file="$RESULTS_DIR/${run_id}_citus_metrics.txt"
    
    log "INFO" "Running test $run_number - $suite (c:$clients, j:$jobs)"
    
    # Start timestamp
    local start_ts
    start_ts=$(date +%s)
    
    # Run pgbench
    if $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$BENCHMARK_SERVICE" \
        pgbench ${flags} -c "$clients" -j "$jobs" -T "$DURATION" -r \
        -U "$DBUSER" -h "$DB_HOST" "$DBNAME" \
        > "$result_file" 2> "$log_file"; then
        
        local end_ts
        end_ts=$(date +%s)
        
        # Collect Citus-specific metrics
        collect_citus_metrics "$citus_metrics_file"
        
        # Extract TPS from result
        local tps
        tps=$(grep "tps = " "$result_file" | awk '{print $3}' || echo "N/A")
        
        log "SUCCESS" "Test completed - TPS: $tps"
        return 0
    else
        log "ERROR" "Test failed $run_id"
        return 1
    fi
}

# ===================================================================
# REPORTS
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

generate_comparative_report() {
    local summary_file="$REPORTS_DIR/comparative_analysis.txt"
    
    log "INFO" "Generating comparative analysis..."
    
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "              COMPARATIVE ANALYSIS - $DB_TYPE"
        echo "═══════════════════════════════════════════════════════════════"
        echo "Timestamp: $(date)"
        echo "Database Type: $DB_TYPE"
        echo "Scale Factor: $SCALE"
        echo "Test Duration: ${DURATION}s per test"
        echo ""
        
        if [[ "$DB_TYPE" == "citus" ]]; then
            echo "┌─ CITUS CLUSTER CONFIGURATION"
            echo "├── Coordinator: $DB_HOST:$DB_PORT"
            echo "├── Workers: ${#WORKER_HOSTS[@]}"
            for worker in "${WORKER_HOSTS[@]}"; do
                echo "│   └── $worker:5432"
            done
            echo ""
        fi
        
        # Analysis by workload - use same execution logic
        local all_suite_names=("${BASE_SUITE_NAMES[@]}")
        local all_suite_descriptions=("${BASE_SUITE_DESCRIPTIONS[@]}")
        
        # Add Citus-specific workloads if applicable  
        if [[ "$DB_TYPE" == "citus" && ${#CITUS_EXTRA_NAMES[@]} -gt 0 ]]; then
            all_suite_names+=("${CITUS_EXTRA_NAMES[@]}")
            all_suite_descriptions+=("${CITUS_EXTRA_DESCRIPTIONS[@]}")
        fi
        
        for suite_idx in "${!all_suite_names[@]}"; do
            local suite="${all_suite_names[$suite_idx]}"
            local description="${all_suite_descriptions[$suite_idx]}"
            
            echo "┌─ $suite: $description"
            
            IFS=',' read -ra clients_arr <<< "$CLIENTS_ARRAY"
            for clients in "${clients_arr[@]}"; do
                echo "├── $clients clients:"
                
            # Calculate statistics
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
                    local tps_stats latency_stats
                    tps_stats=$(printf '%s\n' "${tps_values[@]}" | awk '
                        {sum+=$1; sumsq+=$1*$1; if($1>max || NR==1) max=$1; if($1<min || NR==1) min=$1}
                        END {
                            avg=sum/NR;
                            stddev=sqrt((sumsq-sum*sum/NR)/NR);
                            printf "%.2f (±%.2f) [%.2f-%.2f]", avg, stddev, min, max
                        }')
                    
                    latency_stats=$(printf '%s\n' "${latency_values[@]}" | awk '
                        {sum+=$1; sumsq+=$1*$1; if($1>max || NR==1) max=$1; if($1<min || NR==1) min=$1}
                        END {
                            avg=sum/NR;
                            stddev=sqrt((sumsq-sum*sum/NR)/NR);
                            printf "%.2f (±%.2f) [%.2f-%.2f]", avg, stddev, min, max
                        }')
                    
                    echo "│   ├─ TPS: $tps_stats"
                    echo "│   └─ Latency (ms): $latency_stats"
                else
                    echo "│   └─ No valid data"
                fi
            done
            echo ""
        done
        
        # (Removed: scaling analysis/recommendation. Only results for manual comparison)
        echo "═══════════════════════════════════════════════════════════════"
        
    } > "$summary_file"
    
    log "SUCCESS" "Comparative analysis generated: $summary_file"
}

generate_final_report() {
    log "INFO" "Generating final report..."
    
    # Basic CSV
    local csv_file="$REPORTS_DIR/benchmark_results.csv"
    echo "Database_Type,Suite,Clients,Jobs,Run,TPS,Latency_Avg_ms,Failed_Trans,Duration_s,Timestamp" > "$csv_file"
    
    for result_file in "$RESULTS_DIR"/*.txt; do
        [[ ! -f "$result_file" ]] && continue
        [[ "$result_file" == *"_citus_metrics.txt" ]] && continue
        
        local filename
        filename=$(basename "$result_file" .txt)
        
        if [[ $filename =~ ([0-9]+_[0-9]+)_(.+)_c([0-9]+)_j([0-9]+)_run([0-9]+) ]]; then
            local timestamp="${BASH_REMATCH[1]}"
            local suite="${BASH_REMATCH[2]}"
            local clients="${BASH_REMATCH[3]}"
            local jobs="${BASH_REMATCH[4]}"
            local run="${BASH_REMATCH[5]}"
            
            local metrics
            metrics=$(parse_pgbench_result "$result_file")
            
            echo "$DB_TYPE,$suite,$clients,$jobs,$run,$metrics,$timestamp" >> "$csv_file"
        fi
    done
    
    # Comparative analysis
    generate_comparative_report
    
    # HTML Index
    local html_file="$REPORTS_DIR/index.html"
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Universal Database Benchmark Report</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; }
        h2 { color: #34495e; }
        .db-type { display: inline-block; padding: 8px 16px; border-radius: 20px; color: white; font-weight: bold; margin-bottom: 20px; }
        .postgresql { background: #336791; }
        .citus { background: #ff6b35; }
        .section { margin: 20px 0; padding: 20px; border-left: 4px solid #3498db; background: #ecf0f1; }
        .files { background: #ffffff; border: 1px solid #ddd; padding: 15px; border-radius: 5px; }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul { list-style-type: none; padding-left: 0; }
        li { padding: 8px 0; border-bottom: 1px solid #eee; }
        .config-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-top: 15px; }
        .metric { background: #3498db; color: white; padding: 5px 10px; border-radius: 3px; margin: 2px; display: inline-block; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Universal Database Benchmark Report</h1>
        <div class="db-type $DB_TYPE">Database: $(echo $DB_TYPE | tr '[:lower:]' '[:upper:]')</div>
        <p><strong>Generated:</strong> $(date)</p>
        
        <div class="section">
            <h2>🚀 Quick Access</h2>
            <ul>
                <li><a href="benchmark_results.csv">📊 CSV Results</a></li>
                <li><a href="comparative_analysis.txt">📈 Comparative Analysis</a></li>
                <li><a href="http://localhost:3000" target="_blank">📉 Grafana Dashboard</a></li>
                <li><a href="http://localhost:9090" target="_blank">🔍 Prometheus Metrics</a></li>
            </ul>
        </div>
        
        <div class="config-grid">
            <div class="files">
                <h2>⚙️ Configuration</h2>
                <ul>
                    <li><span class="metric">Scale</span> $SCALE</li>
                    <li><span class="metric">Duration</span> ${DURATION}s</li>
                    <li><span class="metric">Warmup</span> ${WARMUP_DURATION}s</li>
                    <li><span class="metric">Repetitions</span> $REPEATS</li>
                    <li><span class="metric">Clients</span> $CLIENTS_ARRAY</li>
                </ul>
            </div>
            
            <div class="files">
                <h2>🏗️ Architecture</h2>
                <ul>
                    <li><span class="metric">Type</span> $DB_TYPE</li>
                    <li><span class="metric">Host</span> $DB_HOST:$DB_PORT</li>
EOF

    if [[ "$DB_TYPE" == "citus" && ${#WORKER_HOSTS[@]} -gt 0 ]]; then
        echo "                    <li><span class=\"metric\">Workers</span> ${#WORKER_HOSTS[@]} nodes</li>" >> "$html_file"
    fi

    cat >> "$html_file" << EOF
                </ul>
            </div>
        </div>
        
        <div class="section">
            <h2>📋 Test Results Summary</h2>
            <p>Detailed analysis available in the comparative analysis file. Key metrics tracked:</p>
            <div style="margin-top: 15px;">
                <span class="metric">TPS (Transactions/sec)</span>
                <span class="metric">Latency (ms)</span>
                <span class="metric">Failed Transactions</span>
                <span class="metric">Resource Usage</span>
EOF

    if [[ "$DB_TYPE" == "citus" ]]; then
        echo "                <span class=\"metric\">Distribution Metrics</span>" >> "$html_file"
    fi

    cat >> "$html_file" << EOF
            </div>
        </div>
    </div>
</body>
</html>
EOF
    
    log "SUCCESS" "HTML report generated: $html_file"
    log "INFO" "════════════════════════════════════════════════════════════════"
    log "INFO" "                 UNIVERSAL BENCHMARK COMPLETED"
    log "INFO" "════════════════════════════════════════════════════════════════"
    log "INFO" "Database Type: $DB_TYPE"
    log "INFO" "Results available at:"
    log "INFO" "  • Report: file://$html_file" 
    log "INFO" "  • CSV: $csv_file"
    log "INFO" "  • Analysis: $REPORTS_DIR/comparative_analysis.txt"
    log "INFO" "════════════════════════════════════════════════════════════════"
}

# ===================================================================
# MAIN FUNCTION
# ===================================================================

run_benchmark_suite() {
    # Build suite list based on database type
    local all_suite_names=("${BASE_SUITE_NAMES[@]}")
    local all_suite_descriptions=("${BASE_SUITE_DESCRIPTIONS[@]}")
    
    # Add Citus-specific workloads if applicable
    if [[ "$DB_TYPE" == "citus" && ${#CITUS_EXTRA_NAMES[@]} -gt 0 ]]; then
        all_suite_names+=("${CITUS_EXTRA_NAMES[@]}")
        all_suite_descriptions+=("${CITUS_EXTRA_DESCRIPTIONS[@]}")
    fi
    
    local total_tests=0
    local completed_tests=0
    local failed_tests=0
    
    # Calculate total tests
    IFS=',' read -ra clients_arr <<< "$CLIENTS_ARRAY"
    total_tests=$(( ${#all_suite_names[@]} * ${#clients_arr[@]} * REPEATS ))
    
    log "INFO" "Starting benchmark suite ($DB_TYPE):"
    log "INFO" "  • Base workloads (comparable): ${#BASE_SUITE_NAMES[@]}"
    if [[ "$DB_TYPE" == "citus" && ${#CITUS_EXTRA_NAMES[@]} -gt 0 ]]; then
        log "INFO" "  • Citus-specific workloads: ${#CITUS_EXTRA_NAMES[@]}"
    fi
    log "INFO" "  • Total suites: ${#all_suite_names[@]}"
    log "INFO" "  • Client configurations: ${#clients_arr[@]} (${clients_arr[*]})"
    log "INFO" "  • Repetitions: $REPEATS"
    log "INFO" "  • Total tests: $total_tests"
    echo ""
    
    for suite_idx in "${!all_suite_names[@]}"; do
        local suite="${all_suite_names[$suite_idx]}"
        local description="${all_suite_descriptions[$suite_idx]}"
        
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}Suite: $suite - $description${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        
        for clients in "${clients_arr[@]}"; do
            local jobs=$(( clients / JOBS_RATIO ))
            [[ $jobs -lt 1 ]] && jobs=1
            
            log "INFO" "Configuration: $clients clients, $jobs jobs"
            
            # Warmup
            local flags
            flags=$(get_workload_config "$suite")
            if ! run_warmup "$suite" "$flags" "$clients" "$jobs"; then
                log "WARN" "Warmup failed, continuing..."
            fi
            
            # Execute repetitions
            for run in $(seq 1 "$REPEATS"); do
                local progress="$(( completed_tests + 1 ))/$total_tests"
                log "INFO" "Progress: $progress - Run $run..."
                
                if run_benchmark_test "$suite" "$clients" "$jobs" "$run"; then
                    ((completed_tests++))
                    log "SUCCESS" "Run $run completed ($progress)"
                else
                    ((failed_tests++))
                    log "ERROR" "Run $run failed ($progress)"
                fi
                
                sleep 2
            done
            echo ""
        done
    done
    
    log "INFO" "Suite finished: $completed_tests/$total_tests completed, $failed_tests failed"
}

cleanup_on_exit() {
    local exit_code=$?
    log "INFO" "Executing cleanup..."
    
    # Save PID of background processes if they exist
    local bg_jobs
    bg_jobs=$(jobs -p 2>/dev/null || true)
    if [[ -n "$bg_jobs" ]]; then
        echo "$bg_jobs" | xargs kill 2>/dev/null || true
    fi
    
    # Generate report if there are results and it hasn't been generated yet
    if [[ -d "${RESULTS_DIR:-}" ]] && [[ $(find "${RESULTS_DIR:-}" -name "*.txt" 2>/dev/null | grep -v "citus_metrics" | wc -l) -gt 0 ]] && [[ "${REPORT_GENERATED:-0}" != "1" ]]; then
        log "INFO" "Generating final report..."
        generate_final_report 2>/dev/null || log "WARN" "Failed to generate final report"
        export REPORT_GENERATED=1
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Script finished with error (code: $exit_code)"
    else
        log "SUCCESS" "Script finished successfully"
    fi
    
    exit $exit_code
}

handle_interrupt() {
    log "WARN" "Interrupt detected. Finishing..."
    cleanup_on_exit
}

main() {
    # Configure signal handling
    trap handle_interrupt SIGINT SIGTERM
    trap cleanup_on_exit EXIT
    
    show_banner
    
    # Checks and setup
    check_dependencies
    detect_database_type
    setup_directories
    
    # Save configuration
    {
        echo "Universal Benchmark Configuration"
        echo "================================"
        echo "Timestamp: $(date)"
        echo "Database Type: $DB_TYPE"
        echo "Host: $DB_HOST:$DB_PORT"
        echo "Database: $DBNAME"
        echo "Scale Factor: $SCALE"
        echo "Duration: ${DURATION}s"
        echo "Warmup: ${WARMUP_DURATION}s"
        echo "Repetitions: $REPEATS"
        echo "Clients: $CLIENTS_ARRAY"
        echo ""
        if [[ "$DB_TYPE" == "citus" && ${#WORKER_HOSTS[@]} -gt 0 ]]; then
            echo "Citus Workers:"
            for worker in "${WORKER_HOSTS[@]}"; do
                echo "  - $worker:5432"
            done
            echo ""
        fi
    } > "$LOGS_DIR/benchmark_config.txt"
    
    # Check connection
    if ! check_database_connection; then
        exit 1
    fi
    
    # Database-specific setup
    setup_citus_cluster
    initialize_benchmark_data
    
    # Run benchmark
    run_benchmark_suite
    
    # Generate reports
    generate_final_report
    export REPORT_GENERATED=1
}

# Check if script is being executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi