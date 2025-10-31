#!/usr/bin/env bash

# ===================================================================
# PostgreSQL Benchmark Analysis & Configuration Tool
# Ferramenta auxiliar para análise de resultados e configuração
# ===================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DIR="${SCRIPT_DIR}/benchmark"

# Cores
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

show_help() {
    cat << EOF
PostgreSQL Benchmark Analysis Tool

USAGE:
    $(basename "$0") [COMMAND] [OPTIONS]

COMMANDS:
    analyze [RESULT_DIR]     Analisa resultados de benchmark específico
    latest                   Analisa os resultados mais recentes
    compare DIR1 DIR2        Compara dois conjuntos de resultados
    clean                    Limpa resultados antigos
    setup                    Configura ambiente inicial
    status                   Mostra status dos serviços
    
OPTIONS:
    -h, --help              Mostra esta ajuda
    -v, --verbose           Modo verboso
    
EXAMPLES:
    $(basename "$0") latest                    # Analisa resultados mais recentes
    $(basename "$0") analyze results_20250903  # Analisa resultado específico
    $(basename "$0") compare results_20250903_120000 results_20250903_130000
    $(basename "$0") setup                     # Configuração inicial

EOF
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%H:%M:%S')"
    
    case "$level" in
        "INFO")  echo -e "${CYAN}[INFO ]${NC} ${timestamp} - $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN ]${NC} ${timestamp} - $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" >&2 ;;
        "SUCCESS") echo -e "${GREEN}[OK   ]${NC} ${timestamp} - $message" ;;
    esac
}

check_dependencies() {
    local deps=("bc" "awk" "jq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Dependências faltando: ${missing[*]}"
        log "INFO" "Instale com: brew install ${missing[*]}"
        exit 1
    fi
}

analyze_results() {
    local result_dir="$1"
    
    if [[ ! -d "$result_dir" ]]; then
        log "ERROR" "Diretório não encontrado: $result_dir"
        exit 1
    fi
    
    local results_path="$result_dir"
    if [[ ! "$result_dir" =~ ^/ ]]; then
        results_path="$BASE_DIR/$result_dir"
    fi
    
    log "INFO" "Analisando resultados em: $results_path"
    
    if [[ ! -d "$results_path" ]]; then
        log "ERROR" "Diretório não encontrado: $results_path"
        exit 1
    fi
    
    # Contar arquivos de resultado
    local result_count
    result_count=$(find "$results_path" -name "*.txt" 2>/dev/null | wc -l)
    
    if [[ $result_count -eq 0 ]]; then
        log "WARN" "Nenhum arquivo de resultado encontrado em $results_path"
        return 1
    fi
    
    log "INFO" "Encontrados $result_count arquivos de resultado"
    
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                    ANÁLISE DETALHADA DE PERFORMANCE${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Análise por suite
    local suites
    suites=$(find "$results_path" -name "*.txt" -exec basename {} \; | cut -d'_' -f3 | sort -u)
    
    for suite in $suites; do
        echo -e "${BOLD}Suite: $suite${NC}"
        echo "┌─────────────────────────────────────────────────────────────"
        
        # Análise por número de clientes
        local clients
        clients=$(find "$results_path" -name "*_${suite}_c*" -exec basename {} \; | sed -n 's/.*_c\([0-9]*\)_.*/\1/p' | sort -n -u)
        
        for client in $clients; do
            local files
            files=$(find "$results_path" -name "*_${suite}_c${client}_*")
            
            if [[ -n "$files" ]]; then
                local tps_values=()
                local latency_values=()
                
                while IFS= read -r file; do
                    if [[ -f "$file" ]]; then
                        local tps
                        tps=$(grep "tps = " "$file" | awk '{print $3}' | sed 's/[^0-9.]//g' 2>/dev/null || echo "0")
                        local latency
                        latency=$(grep "latency average" "$file" | awk '{print $4}' | sed 's/[^0-9.]//g' 2>/dev/null || echo "0")
                        
                        if [[ "$tps" != "0" && -n "$tps" ]]; then
                            tps_values+=("$tps")
                        fi
                        if [[ "$latency" != "0" && -n "$latency" ]]; then
                            latency_values+=("$latency")
                        fi
                    fi
                done <<< "$files"
                
                if [[ ${#tps_values[@]} -gt 0 ]]; then
                    # Calcular estatísticas
                    local tps_avg tps_min tps_max tps_std
                    local latency_avg latency_min latency_max latency_std
                    
                    read -r tps_avg tps_min tps_max tps_std <<< "$(
                        printf '%s\n' "${tps_values[@]}" | awk '
                        {sum+=$1; sumsq+=$1*$1; if($1>max || NR==1) max=$1; if($1<min || NR==1) min=$1}
                        END {
                            avg=sum/NR;
                            stddev=sqrt((sumsq-sum*sum/NR)/NR);
                            printf "%.2f %.2f %.2f %.2f", avg, min, max, stddev
                        }'
                    )"
                    
                    read -r latency_avg latency_min latency_max latency_std <<< "$(
                        printf '%s\n' "${latency_values[@]}" | awk '
                        {sum+=$1; sumsq+=$1*$1; if($1>max || NR==1) max=$1; if($1<min || NR==1) min=$1}
                        END {
                            avg=sum/NR;
                            stddev=sqrt((sumsq-sum*sum/NR)/NR);
                            printf "%.2f %.2f %.2f %.2f", avg, min, max, stddev
                        }'
                    )"
                    
                    echo "├─ $client clients (${#tps_values[@]} runs):"
                    echo "│  ├─ TPS:     Avg: $tps_avg     (Min: $tps_min, Max: $tps_max, StdDev: $tps_std)"
                    echo "│  └─ Latency: Avg: ${latency_avg}ms (Min: $latency_min, Max: $latency_max, StdDev: $latency_std)"
                    
                    # Identificar variabilidade alta
                    local cv_tps cv_latency
                    cv_tps=$(echo "scale=2; $tps_std / $tps_avg * 100" | bc 2>/dev/null || echo "0")
                    cv_latency=$(echo "scale=2; $latency_std / $latency_avg * 100" | bc 2>/dev/null || echo "0")
                    
                    if (( $(echo "$cv_tps > 10" | bc -l 2>/dev/null || echo "0") )); then
                        echo "│     ⚠️  Alta variabilidade de TPS (CV: ${cv_tps}%)"
                    fi
                    if (( $(echo "$cv_latency > 15" | bc -l 2>/dev/null || echo "0") )); then
                        echo "│     ⚠️  Alta variabilidade de latência (CV: ${cv_latency}%)"
                    fi
                fi
            fi
        done
        echo "└─────────────────────────────────────────────────────────────"
        echo ""
    done
    
    # Encontrar configuração ótima
    find_optimal_configuration "$results_path"
    
    # Recomendações de scaling
    generate_scaling_recommendations "$results_path"
}

find_optimal_configuration() {
    local results_path="$1"
    
    echo -e "${BOLD}${GREEN}CONFIGURAÇÃO ÓTIMA${NC}"
    echo "┌─────────────────────────────────────────────────────────────"
    
    local max_tps=0
    local optimal_config=""
    local optimal_file=""
    
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local tps
            tps=$(grep "tps = " "$file" | awk '{print $3}' | sed 's/[^0-9.]//g' 2>/dev/null || echo "0")
            
            if [[ -n "$tps" && "$tps" != "0" ]] && (( $(echo "$tps > $max_tps" | bc -l 2>/dev/null || echo "0") )); then
                max_tps="$tps"
                optimal_file="$file"
                
                local basename_file
                basename_file=$(basename "$file")
                if [[ $basename_file =~ ([^_]+)_c([0-9]+)_j([0-9]+) ]]; then
                    local suite="${BASH_REMATCH[1]}"
                    local clients="${BASH_REMATCH[2]}"
                    local jobs="${BASH_REMATCH[3]}"
                    optimal_config="$suite com $clients clients, $jobs jobs"
                fi
            fi
        fi
    done < <(find "$results_path" -name "*.txt")
    
    if [[ -n "$optimal_config" ]]; then
        echo "├─ Melhor performance: $max_tps TPS"
        echo "├─ Configuração: $optimal_config"
        
        if [[ -f "$optimal_file" ]]; then
            local latency
            latency=$(grep "latency average" "$optimal_file" | awk '{print $4}' | sed 's/[^0-9.]//g' 2>/dev/null || echo "N/A")
            echo "├─ Latência média: ${latency}ms"
            
            local failed
            failed=$(grep "number of failed transactions" "$optimal_file" | awk '{print $6}' | sed 's/[^0-9.]//g' 2>/dev/null || echo "0")
            echo "└─ Transações falharam: $failed"
        fi
    else
        echo "└─ Nenhum resultado válido encontrado"
    fi
    echo ""
}

generate_scaling_recommendations() {
    local results_path="$1"
    
    echo -e "${BOLD}${YELLOW}RECOMENDAÇÕES DE SCALING${NC}"
    echo "┌─────────────────────────────────────────────────────────────"
    
    # Análise de escalabilidade por suite
    local suites
    suites=$(find "$results_path" -name "*.txt" -exec basename {} \; | cut -d'_' -f3 | sort -u)
    
    for suite in $suites; do
        echo "├─ Suite: $suite"
        
        local clients_tps=()
        local clients_list=()
        
        # Coletar TPS médio por número de clientes
        local clients
        clients=$(find "$results_path" -name "*_${suite}_c*" -exec basename {} \; | sed -n 's/.*_c\([0-9]*\)_.*/\1/p' | sort -n -u)
        
        for client in $clients; do
            local files
            files=$(find "$results_path" -name "*_${suite}_c${client}_*")
            local tps_sum=0
            local tps_count=0
            
            while IFS= read -r file; do
                if [[ -f "$file" ]]; then
                    local tps
                    tps=$(grep "tps = " "$file" | awk '{print $3}' | sed 's/[^0-9.]//g' 2>/dev/null || echo "0")
                    if [[ "$tps" != "0" && -n "$tps" ]]; then
                        tps_sum=$(echo "$tps_sum + $tps" | bc 2>/dev/null || echo "$tps_sum")
                        ((tps_count++))
                    fi
                fi
            done <<< "$files"
            
            if [[ $tps_count -gt 0 ]]; then
                local avg_tps
                avg_tps=$(echo "scale=2; $tps_sum / $tps_count" | bc 2>/dev/null || echo "0")
                clients_tps+=("$avg_tps")
                clients_list+=("$client")
            fi
        done
        
        # Analisar padrão de escalabilidade
        if [[ ${#clients_tps[@]} -gt 1 ]]; then
            local scaling_pattern="linear"
            local peak_index=0
            local peak_tps=0
            
            for i in "${!clients_tps[@]}"; do
                local tps="${clients_tps[$i]}"
                if (( $(echo "$tps > $peak_tps" | bc -l 2>/dev/null || echo "0") )); then
                    peak_tps="$tps"
                    peak_index="$i"
                fi
            done
            
            local peak_clients="${clients_list[$peak_index]}"
            
            # Determinar se há degradação após o pico
            local has_degradation=false
            if [[ $peak_index -lt $((${#clients_tps[@]} - 1)) ]]; then
                local last_index=$((${#clients_tps[@]} - 1))
                local last_tps="${clients_tps[$last_index]}"
                if (( $(echo "$last_tps < $peak_tps * 0.9" | bc -l 2>/dev/null || echo "0") )); then
                    has_degradation=true
                fi
            fi
            
            echo "│  ├─ Pico de performance: $peak_tps TPS com $peak_clients clients"
            
            if [[ "$has_degradation" == "true" ]]; then
                echo "│  ├─ ⚠️  Degradação detectada com mais clientes"
                echo "│  └─ 💡 RECOMENDAÇÃO: Scaling VERTICAL (CPU/RAM) ou Connection Pooling"
            else
                if [[ $peak_clients -le 16 ]]; then
                    echo "│  └─ 💡 RECOMENDAÇÃO: Scaling VERTICAL (aumentar CPU/RAM)"
                else
                    echo "│  └─ 💡 RECOMENDAÇÃO: Scaling HORIZONTAL (read replicas/sharding)"
                fi
            fi
        fi
    done
    
    echo "└─────────────────────────────────────────────────────────────"
    echo ""
    
    # Recomendações gerais
    echo -e "${BOLD}${CYAN}AÇÕES RECOMENDADAS${NC}"
    echo "┌─────────────────────────────────────────────────────────────"
    echo "├─ 📊 Monitore as métricas no Grafana: http://localhost:3000"
    echo "├─ 🔧 Ajuste postgresql.conf baseado nos resultados"
    echo "├─ 💾 Considere SSD para melhor I/O se latência for alta"
    echo "├─ 🔗 Implemente PgBouncer para connection pooling"
    echo "└─ 📈 Execute benchmarks periódicos para acompanhar mudanças"
    echo ""
}

compare_results() {
    local dir1="$1"
    local dir2="$2"
    
    log "INFO" "Comparando $dir1 vs $dir2"
    
    # Implementar comparação detalhada
    echo "Funcionalidade de comparação em desenvolvimento..."
}

clean_old_results() {
    log "INFO" "Limpando resultados antigos..."
    
    if [[ ! -d "$BASE_DIR" ]]; then
        log "INFO" "Nenhum diretório de benchmark encontrado"
        return
    fi
    
    # Manter apenas os 5 resultados mais recentes
    local old_dirs
    old_dirs=$(find "$BASE_DIR" -maxdepth 1 -name "results_*" -type d | sort | head -n -5)
    
    if [[ -n "$old_dirs" ]]; then
        echo "$old_dirs" | while IFS= read -r dir; do
            log "INFO" "Removendo: $(basename "$dir")"
            rm -rf "$dir"
        done
        log "SUCCESS" "Limpeza concluída"
    else
        log "INFO" "Nenhum resultado antigo para remover"
    fi
}

setup_environment() {
    log "INFO" "Configurando ambiente..."
    
    # Verificar docker-compose
    if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
        log "ERROR" "docker-compose.yml não encontrado"
        exit 1
    fi
    
    # Criar diretórios base
    mkdir -p "$BASE_DIR"
    
    # Verificar se os serviços estão rodando
    if docker-compose -f "$SCRIPT_DIR/docker-compose.yml" ps | grep -q "Up"; then
        log "SUCCESS" "Serviços Docker estão rodando"
    else
        log "INFO" "Iniciando serviços Docker..."
        docker-compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
    fi
    
    log "SUCCESS" "Ambiente configurado com sucesso"
}

show_status() {
    log "INFO" "Status dos serviços..."
    
    echo ""
    echo -e "${BOLD}Docker Services:${NC}"
    docker-compose -f "$SCRIPT_DIR/docker-compose.yml" ps 2>/dev/null || {
        log "ERROR" "Falha ao verificar status do Docker Compose"
        return 1
    }
    
    echo ""
    echo -e "${BOLD}URLs de Acesso:${NC}"
    echo "  • Grafana:    http://localhost:3000"
    echo "  • Prometheus: http://localhost:9090"
    echo "  • PostgreSQL: localhost:5432"
    
    echo ""
    echo -e "${BOLD}Resultados Disponíveis:${NC}"
    if [[ -d "$BASE_DIR" ]]; then
        find "$BASE_DIR" -maxdepth 1 -name "results_*" -type d | sort -r | head -5 | while IFS= read -r dir; do
            local count
            count=$(find "$dir" -name "*.txt" 2>/dev/null | wc -l)
            echo "  • $(basename "$dir"): $count resultados"
        done
    else
        echo "  • Nenhum resultado encontrado"
    fi
}

main() {
    check_dependencies
    
    case "${1:-help}" in
        "analyze")
            if [[ -n "${2:-}" ]]; then
                analyze_results "$2"
            else
                log "ERROR" "Especifique o diretório de resultados"
                show_help
            fi
            ;;
        "latest")
            local latest_dir
            latest_dir=$(find "$BASE_DIR" -maxdepth 1 -name "results_*" -type d 2>/dev/null | sort -r | head -1)
            if [[ -n "$latest_dir" ]]; then
                analyze_results "$latest_dir"
            else
                log "ERROR" "Nenhum resultado encontrado"
            fi
            ;;
        "compare")
            if [[ -n "${2:-}" && -n "${3:-}" ]]; then
                compare_results "$2" "$3"
            else
                log "ERROR" "Especifique dois diretórios para comparação"
                show_help
            fi
            ;;
        "clean")
            clean_old_results
            ;;
        "setup")
            setup_environment
            ;;
        "status")
            show_status
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            log "ERROR" "Comando inválido: $1"
            show_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
