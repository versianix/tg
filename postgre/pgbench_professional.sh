#!/usr/bin/env bash

# ===================================================================
# PostgreSQL Professional Benchmark Suite
# Desenvolvido para Trabalho de Graduação
# 
# Este script executa benchmarks robustos com:
# - Múltiplos workloads (TPC-B, Select-Only, Prepared Statements)
# - Integração com Prometheus/Grafana para monitoramento
# - Tratamento de erros e recovery automático
# - Relatórios detalhados e análise estatística
# - Suporte para decisões de scaling horizontal/vertical
# ===================================================================

set -euo pipefail
IFS=$'\n\t'

# ===================================================================
# CONFIGURAÇÕES GLOBAIS
# ===================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_CMD="${COMPOSE_CMD:-docker-compose}"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Serviços Docker
readonly PG_SERVICE="postgres"
readonly PGBENCH_SERVICE="pgbench"

# Configurações de Banco
readonly DBNAME="${POSTGRES_DB:-mydb}"
readonly DBUSER="${POSTGRES_USER:-postgres}"
readonly PGPASSWORD="${POSTGRES_PASSWORD:-postgres}"

# Configurações de Benchmark
readonly SCALE="${SCALE:-50}"
readonly DURATION="${DURATION:-60}"
readonly WARMUP_DURATION="${WARMUP_DURATION:-20}"
readonly REPEATS="${REPEATS:-5}"
readonly CLIENTS_ARRAY="${CLIENTS:-4,16,32,64}"
readonly JOBS_RATIO="${JOBS_RATIO:-2}"

# Diretórios
readonly BASE_DIR="${SCRIPT_DIR}/benchmark"
readonly RESULTS_DIR="${BASE_DIR}/results_${TIMESTAMP}"
readonly LOGS_DIR="${BASE_DIR}/logs_${TIMESTAMP}"
readonly REPORTS_DIR="${BASE_DIR}/reports_${TIMESTAMP}"

# Prometheus
readonly PROM_URL="${PROM_URL:-http://localhost:9090}"
readonly PROM_STEP="${PROM_STEP:-15}"

# Cores para output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# ===================================================================
# CONFIGURAÇÕES DE WORKLOAD
# ===================================================================

declare -ra SUITE_NAMES=("tpcb" "select_only" "simple_update")
declare -ra SUITE_FLAGS=("" "-S" "-N")
declare -ra SUITE_DESCRIPTIONS=(
    "TPC-B: Mixed read/write workload (OLTP)"
    "Select-Only: Read-heavy workload (OLAP)"
    "Simple Update: Write-heavy workload"
)

# ===================================================================
# FUNÇÕES UTILITÁRIAS
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
║                     Trabalho de Graduação                       ║
╠══════════════════════════════════════════════════════════════════╣
║  • Múltiplos workloads para análise completa                    ║
║  • Integração com Prometheus/Grafana                            ║
║  • Relatórios detalhados para decisão de scaling                ║
║  • Recovery automático em caso de falhas                        ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_dependencies() {
    log "INFO" "Verificando dependências..."
    
    local deps=("docker" "curl" "jq")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Dependências faltando: ${missing_deps[*]}"
        log "INFO" "Instale com: brew install ${missing_deps[*]}"
        exit 1
    fi
    
    # Verificar se docker-compose existe
    if ! command -v "$COMPOSE_CMD" &> /dev/null; then
        log "ERROR" "Docker Compose não encontrado: $COMPOSE_CMD"
        exit 1
    fi
    
    log "SUCCESS" "Todas as dependências verificadas"
}

setup_directories() {
    log "INFO" "Configurando diretórios..."
    
    mkdir -p "$RESULTS_DIR" "$LOGS_DIR" "$REPORTS_DIR"
    
    # Criar link simbólico para latest
    local latest_results="${BASE_DIR}/latest_results"
    local latest_logs="${BASE_DIR}/latest_logs" 
    local latest_reports="${BASE_DIR}/latest_reports"
    
    [[ -L "$latest_results" ]] && rm "$latest_results"
    [[ -L "$latest_logs" ]] && rm "$latest_logs"
    [[ -L "$latest_reports" ]] && rm "$latest_reports"
    
    ln -sf "$(basename "$RESULTS_DIR")" "$latest_results"
    ln -sf "$(basename "$LOGS_DIR")" "$latest_logs"
    ln -sf "$(basename "$REPORTS_DIR")" "$latest_reports"
    
    log "SUCCESS" "Diretórios configurados:"
    log "INFO" "  Resultados: $RESULTS_DIR"
    log "INFO" "  Logs:       $LOGS_DIR"
    log "INFO" "  Relatórios: $REPORTS_DIR"
}

cleanup_on_exit() {
    local exit_code=$?
    log "INFO" "Executando limpeza..."
    
    # Salvar PID dos processos em background se existirem (compatível macOS)
    local bg_jobs
    bg_jobs=$(jobs -p 2>/dev/null || true)
    if [[ -n "$bg_jobs" ]]; then
        echo "$bg_jobs" | xargs kill 2>/dev/null || true
    fi
    
    # Gerar relatório apenas se há resultados E as funções estão disponíveis E não foi gerado ainda
    if [[ -d "${RESULTS_DIR:-}" ]] && [[ $(find "${RESULTS_DIR:-}" -name "*.txt" 2>/dev/null | wc -l) -gt 0 ]] && declare -f generate_final_report >/dev/null 2>&1 && [[ "${REPORT_GENERATED:-0}" != "1" ]]; then
        log "INFO" "Gerando relatório final..."
        generate_final_report 2>/dev/null || log "WARN" "Falha ao gerar relatório final"
        export REPORT_GENERATED=1
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Script finalizado com erro (código: $exit_code)"
        log "INFO" "Verifique os logs em: ${LOGS_DIR:-./logs}"
    else
        log "SUCCESS" "Script finalizado com sucesso"
    fi
    
    exit $exit_code
}

handle_interrupt() {
    log "WARN" "Interrupção detectada (Ctrl+C). Finalizando gracefully..."
    cleanup_on_exit
}

# ===================================================================
# FUNÇÕES DE DOCKER
# ===================================================================

check_docker_services() {
    log "INFO" "Verificando serviços Docker..."
    
    if ! docker info &>/dev/null; then
        log "ERROR" "Docker não está rodando"
        exit 1
    fi
    
    # Verificar se docker-compose.yml existe
    if [[ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        log "ERROR" "docker-compose.yml não encontrado em ${SCRIPT_DIR}"
        exit 1
    fi
    
    log "SUCCESS" "Docker configurado corretamente"
}

start_services() {
    log "INFO" "Iniciando serviços necessários..."
    
    # Subir somente o serviço pgbench (mantém outros como estão)
    if ! $COMPOSE_CMD up -d "$PGBENCH_SERVICE" 2>"$LOGS_DIR/docker_startup.log"; then
        log "ERROR" "Falha ao iniciar serviço $PGBENCH_SERVICE"
        cat "$LOGS_DIR/docker_startup.log"
        exit 1
    fi
    
    # Aguardar serviços ficarem prontos
    log "INFO" "Aguardando serviços ficarem prontos..."
    sleep 5
    
    # Verificar se PostgreSQL está respondendo
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if $COMPOSE_CMD exec -T "$PGBENCH_SERVICE" pg_isready -h "$PG_SERVICE" -U "$DBUSER" &>/dev/null; then
            log "SUCCESS" "PostgreSQL está pronto"
            break
        fi
        
        log "INFO" "Tentativa $attempt/$max_attempts - Aguardando PostgreSQL..."
        sleep 2
        ((attempt++))
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        log "ERROR" "PostgreSQL não respondeu após $max_attempts tentativas"
        exit 1
    fi
}

# ===================================================================
# FUNÇÕES DE BENCHMARK
# ===================================================================

initialize_pgbench() {
    log "INFO" "Inicializando dados do pgbench (scale: $SCALE)..."
    
    local init_log="$LOGS_DIR/pgbench_init.log"
    
    if ! $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
        pgbench -i -s "$SCALE" -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" \
        > "$init_log" 2>&1; then
        
        log "ERROR" "Falha na inicialização do pgbench"
        tail -n 20 "$init_log"
        exit 1
    fi
    
    log "SUCCESS" "Dados inicializados com sucesso"
    log "DEBUG" "Log de inicialização: $init_log"
    
    # Mostrar estatísticas da inicialização
    local init_stats
    init_stats=$(tail -n 5 "$init_log" | grep -E "(done in|tables)" || true)
    if [[ -n "$init_stats" ]]; then
        log "INFO" "Estatísticas de inicialização:"
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
    
    log "INFO" "Executando warmup - Suite: $suite, Clients: $clients, Jobs: $jobs"
    
    local warmup_log="$LOGS_DIR/warmup_${suite}_c${clients}_j${jobs}.log"
    
    $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
        pgbench ${flags} -c "$clients" -j "$jobs" -T "$WARMUP_DURATION" \
        -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" \
        > "$warmup_log" 2>&1 || {
        
        log "WARN" "Warmup falhou - continuando mesmo assim"
        log "DEBUG" "Log do warmup: $warmup_log"
        return 1
    }
    
    log "SUCCESS" "Warmup concluído"
    return 0
}

collect_prometheus_metrics() {
    local start_ts="$1"
    local end_ts="$2"
    local output_prefix="$3"
    
    log "DEBUG" "Coletando métricas do Prometheus..."
    
    # Definir queries como variáveis separadas para evitar problema com arrays associativos
    local queries_names=("transactions_per_sec" "cpu_usage" "disk_io" "active_connections" "memory_usage" "disk_read_bytes" "disk_write_bytes" "pg_locks")
    local queries_values=(
        'sum(rate(pg_stat_database_xact_commit_total[1m]))'
        '100 * (1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[1m])))'
        '100 * sum by(instance) (rate(node_disk_io_time_seconds_total[1m]))'
        'pg_stat_activity_count'
        '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100'
        'sum(rate(node_disk_read_bytes_total[1m]))'
        'sum(rate(node_disk_written_bytes_total[1m]))'
        'pg_locks_count'
    )
    
    for i in "${!queries_names[@]}"; do
        local metric_name="${queries_names[$i]}"
        local query="${queries_values[$i]}"
        local output_file="${output_prefix}_${metric_name}.json"
        
        # Usar timeout para evitar travamento
        if timeout 30 curl -s --get \
            --data-urlencode "query=$query" \
            --data-urlencode "start=$start_ts" \
            --data-urlencode "end=$end_ts" \
            --data-urlencode "step=$PROM_STEP" \
            "$PROM_URL/api/v1/query_range" \
            -o "$output_file" 2>/dev/null; then
            
            log "DEBUG" "Métrica coletada: $metric_name"
        else
            log "WARN" "Falha ao coletar métrica: $metric_name"
        fi
    done
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
    
    log "INFO" "Executando teste $run_number - $suite (c:$clients, j:$jobs)"
    
    # Timestamp de início
    local start_ts
    start_ts=$(date +%s)
    
    # Executar pgbench
    if $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
        pgbench ${flags} -c "$clients" -j "$jobs" -T "$DURATION" -r \
        -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" \
        > "$result_file" 2> "$log_file"; then
        
        local end_ts
        end_ts=$(date +%s)
        
        # Coletar métricas do Prometheus
        collect_prometheus_metrics "$start_ts" "$end_ts" "$metrics_prefix"
        
        # Extrair TPS do resultado
        local tps
        tps=$(grep "tps = " "$result_file" | awk '{print $3}' || echo "N/A")
        
        log "SUCCESS" "Teste concluído - TPS: $tps"
        return 0
    else
        log "ERROR" "Falha no teste $run_id"
        log "DEBUG" "Log de erro: $log_file"
        return 1
    fi
}

# ===================================================================
# FUNÇÕES DE RELATÓRIO
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
    
    log "INFO" "Gerando relatório CSV..."
    
    # Cabeçalho
    echo "Suite,Clients,Jobs,Run,TPS,Latency_Avg_ms,Failed_Trans,Duration_s,Timestamp" > "$csv_file"
    
    # Processar resultados
    for result_file in "$RESULTS_DIR"/*.txt; do
        [[ ! -f "$result_file" ]] && continue
        
        local filename
        filename=$(basename "$result_file" .txt)
        
        # Extrair informações do nome do arquivo
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
    
    log "SUCCESS" "Relatório CSV gerado: $csv_file"
}

generate_summary_statistics() {
    local summary_file="$REPORTS_DIR/summary_statistics.txt"
    
    log "INFO" "Gerando estatísticas resumidas..."
    
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "                    RESUMO ESTATÍSTICO DO BENCHMARK"
        echo "═══════════════════════════════════════════════════════════════"
        echo "Timestamp: $(date)"
        echo "Scale Factor: $SCALE"
        echo "Duration per test: ${DURATION}s"
        echo "Warmup duration: ${WARMUP_DURATION}s"
        echo "Repetitions: $REPEATS"
        echo ""
        
        # Análise por suite e configuração de clientes
        for suite_idx in "${!SUITE_NAMES[@]}"; do
            local suite="${SUITE_NAMES[$suite_idx]}"
            local description="${SUITE_DESCRIPTIONS[$suite_idx]}"
            
            echo "┌─ $suite: $description"
            
            IFS=',' read -ra clients_arr <<< "$CLIENTS_ARRAY"
            for clients in "${clients_arr[@]}"; do
                echo "├── $clients clients:"
                
                # Encontrar arquivos para esta configuração
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
                    # Calcular estatísticas básicas usando awk
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
                    echo "│   └─ Nenhum resultado válido encontrado"
                fi
            done
            echo ""
        done
        
        echo "═══════════════════════════════════════════════════════════════"
        echo "                    RECOMENDAÇÕES DE SCALING"
        echo "═══════════════════════════════════════════════════════════════"
        
        # Análise automática para recomendações
        echo "Baseado nos resultados do benchmark:"
        echo ""
        
        # Encontrar o pico de performance
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
        
        echo "• Pico de performance: $max_tps TPS com $optimal_clients clients ($optimal_suite)"
        echo ""
        
        if (( optimal_clients <= 16 )); then
            echo "• RECOMENDAÇÃO: SCALING VERTICAL"
            echo "  - Performance máxima com poucos clients sugere limitação de CPU/RAM"
            echo "  - Considere aumentar CPU cores e memória RAM"
            echo "  - Otimize configurações do PostgreSQL (shared_buffers, work_mem)"
        else
            echo "• RECOMENDAÇÃO: SCALING HORIZONTAL"
            echo "  - Performance máxima com muitos clients sugere boa paralelização"
            echo "  - Considere implementar read replicas ou sharding"
            echo "  - Implemente connection pooling (PgBouncer)"
        fi
        
        echo ""
        echo "• Para análise detalhada, consulte os gráficos no Grafana:"
        echo "  http://localhost:3000"
        echo ""
        
    } > "$summary_file"
    
    log "SUCCESS" "Estatísticas geradas: $summary_file"
}

generate_final_report() {
    log "INFO" "Gerando relatório final..."
    
    generate_csv_report
    generate_summary_statistics
    
    # Criar arquivo de índice HTML simples
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
    
    log "SUCCESS" "Relatório HTML gerado: $html_file"
    log "INFO" "════════════════════════════════════════════════════════════════"
    log "INFO" "                     BENCHMARK CONCLUÍDO"
    log "INFO" "════════════════════════════════════════════════════════════════"
    log "INFO" "Resultados disponíveis em:"
    log "INFO" "  • Relatório: file://$html_file"
    log "INFO" "  • CSV: $REPORTS_DIR/benchmark_results.csv"
    log "INFO" "  • Estatísticas: $REPORTS_DIR/summary_statistics.txt"
    log "INFO" "  • Grafana: http://localhost:3000"
    log "INFO" "════════════════════════════════════════════════════════════════"
}

# ===================================================================
# FUNÇÃO PRINCIPAL
# ===================================================================

run_benchmark_suite() {
    local total_tests=0
    local completed_tests=0
    local failed_tests=0
    
    # Calcular total de testes
    IFS=',' read -ra clients_arr <<< "$CLIENTS_ARRAY"
    total_tests=$(( ${#SUITE_NAMES[@]} * ${#clients_arr[@]} * REPEATS ))
    
    log "INFO" "Iniciando suite de benchmark:"
    log "INFO" "  • Suites: ${#SUITE_NAMES[@]} (${SUITE_NAMES[*]})"
    log "INFO" "  • Configurações de clientes: ${#clients_arr[@]} (${clients_arr[*]})"
    log "INFO" "  • Repetições por configuração: $REPEATS"
    log "INFO" "  • Total de testes: $total_tests"
    log "INFO" "  • Tempo estimado: $(( total_tests * (DURATION + WARMUP_DURATION + 10) / 60 )) minutos"
    echo ""
    
    for suite_idx in "${!SUITE_NAMES[@]}"; do
        local suite="${SUITE_NAMES[$suite_idx]}"
        local flags="${SUITE_FLAGS[$suite_idx]}"
        local description="${SUITE_DESCRIPTIONS[$suite_idx]}"
        
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}Suite: $suite - $description${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        
        # Limpeza adicional entre suites diferentes
        if [[ $suite_idx -gt 0 ]]; then
            log "INFO" "Executando limpeza entre workloads..."
            $COMPOSE_CMD exec -T -e PGPASSWORD="$PGPASSWORD" "$PGBENCH_SERVICE" \
                psql -U "$DBUSER" -h "$PG_SERVICE" "$DBNAME" -c "VACUUM ANALYZE;" >/dev/null 2>&1 || true
        fi
        
        for clients in "${clients_arr[@]}"; do
            local jobs=$(( clients / JOBS_RATIO ))
            [[ $jobs -lt 1 ]] && jobs=1
            
            log "INFO" "Configuração: $clients clients, $jobs jobs"
            
            # Warmup
            if ! run_warmup "$suite" "$flags" "$clients" "$jobs"; then
                log "WARN" "Warmup falhou, mas continuando..."
            fi
            
            # Executar repetições
            for run in $(seq 1 "$REPEATS"); do
                local progress="$(( completed_tests + 1 ))/$total_tests"
                log "INFO" "Progresso: $progress - Executando run $run..."
                
                if run_benchmark_test "$suite" "$flags" "$clients" "$jobs" "$run"; then
                    ((completed_tests++))
                    log "SUCCESS" "Run $run concluído ($progress)"
                else
                    ((failed_tests++))
                    log "ERROR" "Run $run falhou ($progress)"
                fi
                
                # Breve pausa entre testes
                sleep 3
            done
            
            echo ""
        done
    done
    
    log "INFO" "Suite de benchmark finalizada:"
    log "INFO" "  • Testes completados: $completed_tests/$total_tests"
    log "INFO" "  • Testes falharam: $failed_tests"
    
    if [[ $failed_tests -gt 0 ]]; then
        log "WARN" "Alguns testes falharam. Verifique os logs em $LOGS_DIR"
    fi
}

# ===================================================================
# MAIN
# ===================================================================

main() {
    # Configurar tratamento de sinais
    trap handle_interrupt SIGINT SIGTERM
    trap cleanup_on_exit EXIT
    
    show_banner
    
    # Verificações iniciais com tratamento de erro
    if ! check_dependencies; then
        log "ERROR" "Falha na verificação de dependências"
        exit 1
    fi
    
    if ! check_docker_services; then
        log "ERROR" "Falha na verificação dos serviços Docker"
        exit 1
    fi
    
    if ! setup_directories; then
        log "ERROR" "Falha na configuração dos diretórios"
        exit 1
    fi
    
    # Salvar configuração atual
    {
        echo "Configuração do Benchmark"
        echo "========================"
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
        echo "Suites Configuradas:"
        for i in "${!SUITE_NAMES[@]}"; do
            echo "  ${SUITE_NAMES[$i]}: ${SUITE_DESCRIPTIONS[$i]}"
        done
    } > "$LOGS_DIR/benchmark_config.txt"
    
    # Inicializar ambiente com tratamento de erro
    if ! start_services; then
        log "ERROR" "Falha ao iniciar serviços"
        exit 1
    fi
    
    if ! initialize_pgbench; then
        log "ERROR" "Falha na inicialização do pgbench"
        exit 1
    fi
    
    # Executar benchmark
    run_benchmark_suite
    
    # Gerar relatórios
    generate_final_report
    export REPORT_GENERATED=1
}

# Verificar se o script está sendo executado diretamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
