#!/bin/bash

# ================================================================================
# PostgreSQL Standard Dashboard
# Desenvolvido para Trabalho de Graduação
# 
# Dashboard interativo para ambiente PostgreSQL padrão (baseline)
# Permite comparação com ambiente Citus distribuído
# ================================================================================

set -euo pipefail

# ================================================================================
# CONFIGURAÇÕES E CONSTANTES
# ================================================================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Configurações do banco
DATABASE_NAME="benchmark_db"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="postgres"

# ================================================================================
# FUNÇÕES DE UTILIDADE
# ================================================================================

# Função para logging com timestamp
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${GREEN}[${timestamp}]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[${timestamp}]${NC} $message" ;;
        "ERROR") echo -e "${RED}[${timestamp}]${NC} $message" ;;
        "DEBUG") echo -e "${CYAN}[${timestamp}]${NC} $message" ;;
        *)       echo -e "[${timestamp}] $message" ;;
    esac
}

# Função para verificar se container está rodando
is_container_running() {
    local container_name=$1
    docker ps --format "{{.Names}}" | grep -q "^${container_name}$"
}

# Função para aguardar PostgreSQL estar pronto
wait_for_postgres() {
    log "INFO" "Aguardando PostgreSQL estar pronto..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker exec pg_standard pg_isready -U postgres >/dev/null 2>&1; then
            log "INFO" "✅ PostgreSQL pronto!"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    log "ERROR" "❌ PostgreSQL não ficou pronto após ${max_attempts} tentativas"
    return 1
}

# ================================================================================
# FUNÇÕES DE STATUS
# ================================================================================

# Mostrar status dos containers
show_containers_status() {
    echo -e "\n${BLUE}📦 STATUS DOS CONTAINERS${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    local containers=("pg_standard" "postgres_exporter" "node_exporter" "prometheus_pg" "grafana_pg" "pgbench")
    
    for container in "${containers[@]}"; do
        if is_container_running "$container"; then
            local status="🟢 ATIVO"
            local uptime=$(docker ps --format "{{.Status}}" --filter "name=^${container}$")
            echo -e "   ${container}: ${GREEN}${status}${NC} (${uptime})"
        else
            echo -e "   ${container}: ${RED}🔴 INATIVO${NC}"
        fi
    done
}

# Mostrar status do banco de dados
show_database_status() {
    echo -e "\n${BLUE}🗄️  STATUS DO BANCO DE DADOS${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    if ! is_container_running "pg_standard"; then
        echo -e "   ${RED}❌ PostgreSQL não está rodando${NC}"
        return
    fi
    
    # Verificar se o database existe
    local db_exists=$(docker exec pg_standard psql -U postgres -t -c "SELECT 1 FROM pg_database WHERE datname='${DATABASE_NAME}'" 2>/dev/null | grep -c "1" || echo "0")
    
    if [ "$db_exists" = "1" ]; then
        echo -e "   Database: ${GREEN}✅ ${DATABASE_NAME}${NC}"
        
        # Verificar tabelas
        local tables_count=$(docker exec pg_standard psql -U postgres -d "${DATABASE_NAME}" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || echo "0")
        echo -e "   Tabelas: ${GREEN}${tables_count} tabelas criadas${NC}"
        
        # Verificar dados
        if [ "$tables_count" -gt "0" ]; then
            local total_records=0
            local tables=("companies" "campaigns" "ads" "system_metrics")
            
            for table in "${tables[@]}"; do
                local count=$(docker exec pg_standard psql -U postgres -d "${DATABASE_NAME}" -t -c "SELECT COUNT(*) FROM ${table}" 2>/dev/null || echo "0")
                if [ "$count" -gt "0" ]; then
                    echo -e "   • ${table}: ${GREEN}${count} registros${NC}"
                    ((total_records += count))
                else
                    echo -e "   • ${table}: ${YELLOW}vazia${NC}"
                fi
            done
            
            echo -e "   Total de registros: ${GREEN}${total_records}${NC}"
        fi
    else
        echo -e "   Database: ${YELLOW}⚠️  ${DATABASE_NAME} não criado${NC}"
    fi
}

# Mostrar status dos serviços de monitoramento
show_monitoring_status() {
    echo -e "\n${BLUE}📊 SERVIÇOS DE MONITORAMENTO${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    # Prometheus
    if is_container_running "prometheus_pg"; then
        echo -e "   Prometheus: ${GREEN}✅ Ativo${NC} - http://localhost:9090"
    else
        echo -e "   Prometheus: ${RED}❌ Inativo${NC}"
    fi
    
    # Grafana
    if is_container_running "grafana_pg"; then
        echo -e "   Grafana: ${GREEN}✅ Ativo${NC} - http://localhost:3000 (admin/admin)"
    else
        echo -e "   Grafana: ${RED}❌ Inativo${NC}"
    fi
    
    # Postgres Exporter
    if is_container_running "postgres_exporter"; then
        echo -e "   Postgres Exporter: ${GREEN}✅ Ativo${NC} - http://localhost:9187"
    else
        echo -e "   Postgres Exporter: ${RED}❌ Inativo${NC}"
    fi
    
    # Node Exporter
    if is_container_running "node_exporter"; then
        echo -e "   Node Exporter: ${GREEN}✅ Ativo${NC} - http://localhost:9100"
    else
        echo -e "   Node Exporter: ${RED}❌ Inativo${NC}"
    fi
}

# ================================================================================
# FUNÇÕES DE OPERAÇÃO
# ================================================================================

# Iniciar ambiente
start_environment() {
    echo -e "\n${PURPLE}🚀 INICIANDO AMBIENTE POSTGRESQL${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    log "INFO" "Iniciando containers com docker-compose..."
    
    if docker-compose up -d; then
        log "INFO" "✅ Containers iniciados com sucesso!"
        
        # Aguardar PostgreSQL
        if wait_for_postgres; then
            echo -e "\n${GREEN}✅ Ambiente PostgreSQL iniciado com sucesso!${NC}"
            echo -e "\n📝 Para conectar ao banco:"
            echo -e "   docker exec -it pg_standard psql -U postgres -d ${DATABASE_NAME}"
        fi
    else
        log "ERROR" "❌ Falha ao iniciar containers"
        return 1
    fi
}

# Parar ambiente
stop_environment() {
    echo -e "\n${PURPLE}⏹️  PARANDO AMBIENTE${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    log "INFO" "Parando todos os containers..."
    
    if docker-compose down; then
        log "INFO" "✅ Ambiente parado com sucesso!"
    else
        log "ERROR" "❌ Falha ao parar containers"
        return 1
    fi
}

# Limpar ambiente completamente
cleanup_environment() {
    echo -e "\n${PURPLE}🧹 LIMPEZA COMPLETA DO AMBIENTE${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    read -p "⚠️  Isso irá remover TODOS os dados. Confirma? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Parando e removendo containers e volumes..."
        
        docker-compose down -v 2>/dev/null || true
        
        log "INFO" "✅ Limpeza concluída!"
    else
        log "INFO" "Operação cancelada"
    fi
}

# Criar schema do banco
setup_database() {
    echo -e "\n${PURPLE}🏗️  CONFIGURANDO BANCO DE DADOS${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "❌ PostgreSQL não está rodando. Execute 'start' primeiro."
        return 1
    fi
    
    log "INFO" "Criando database ${DATABASE_NAME}..."
    
    # Criar database se não existir
    docker exec pg_standard psql -U postgres -c "CREATE DATABASE ${DATABASE_NAME}" 2>/dev/null || log "INFO" "Database já existe"
    
    log "INFO" "Executando script de schema..."
    
        # Execute schema script
    if [ -f "schema.sql" ]; then
        docker exec -i pg_standard psql -U postgres -d "${DATABASE_NAME}" < schema.sql
        log "INFO" "✅ Schema created successfully!"
    else
        log "ERROR" "❌ Arquivo schema.sql não encontrado"
        return 1
    fi
}

# Carregar dados
load_data() {
    echo -e "\n${PURPLE}📥 CARREGANDO DADOS${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "❌ PostgreSQL não está rodando. Execute 'start' primeiro."
        return 1
    fi
    
    # Verificar se database e tabelas existem
    local db_exists=$(docker exec pg_standard psql -U postgres -t -c "SELECT 1 FROM pg_database WHERE datname='${DATABASE_NAME}'" 2>/dev/null | grep -c "1" || echo "0")
    
    if [ "$db_exists" = "0" ]; then
        log "ERROR" "❌ Database ${DATABASE_NAME} não existe. Execute 'setup' primeiro."
        return 1
    fi
    
    if [ -f "load_data.sh" ]; then
        log "INFO" "Executando carregamento de dados..."
        bash load_data.sh "${DATABASE_NAME}"
        log "INFO" "✅ Dados carregados com sucesso!"
    else
        log "ERROR" "❌ Script load_data.sh não encontrado"
        return 1
    fi
}

# Executar benchmark
run_benchmark() {
    echo -e "\n${PURPLE}⚡ EXECUTANDO BENCHMARK${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "❌ PostgreSQL não está rodando. Execute 'start' primeiro."
        return 1
    fi
    
    if [ -f "pgbench_professional.sh" ]; then
        log "INFO" "Iniciando benchmark profissional..."
        bash pgbench_professional.sh
        log "INFO" "✅ Benchmark concluído! Verifique os resultados em benchmark/"
    else
        log "ERROR" "❌ Script pgbench_professional.sh não encontrado"
        return 1
    fi
}

# ================================================================================
# MENU PRINCIPAL
# ================================================================================

show_main_menu() {
    clear
    echo -e "${WHITE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              🐘 POSTGRESQL STANDARD DASHBOARD               ║"
    echo "║                    Ambiente de Baseline                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    show_containers_status
    show_database_status
    show_monitoring_status
    
    echo -e "\n${YELLOW}🎯 OPERAÇÕES DISPONÍVEIS:${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo -e "   ${GREEN}1.${NC} start      → Iniciar ambiente completo"
    echo -e "   ${GREEN}2.${NC} setup      → Criar database e tabelas"
    echo -e "   ${GREEN}3.${NC} load-data  → Carregar dados CSV"
    echo -e "   ${GREEN}4.${NC} benchmark  → Executar benchmark"
    echo -e "   ${GREEN}5.${NC} stop       → Parar ambiente"
    echo -e "   ${GREEN}6.${NC} cleanup    → Limpeza completa"
    echo -e "   ${GREEN}7.${NC} logs       → Ver logs dos containers"
    echo -e "   ${GREEN}8.${NC} connect    → Conectar ao PostgreSQL"
    echo -e "   ${GREEN}r.${NC} refresh    → Atualizar status"
    echo -e "   ${GREEN}q.${NC} quit       → Sair"
    
    echo -e "\n${BLUE}📖 FLUXO RECOMENDADO:${NC}"
    echo -e "   1. start → 2. setup → 3. load-data → 4. benchmark"
    
    echo -e "\n${CYAN}🔗 ACESSO RÁPIDO:${NC}"
    echo -e "   • PostgreSQL: docker exec -it pg_standard psql -U postgres -d ${DATABASE_NAME}"
    echo -e "   • Grafana: http://localhost:3000 (admin/admin)"
    echo -e "   • Prometheus: http://localhost:9090"
    
    echo -e "\n────────────────────────────────────────────────────────────────"
}

# Ver logs dos containers
show_logs() {
    echo -e "\n${PURPLE}📋 LOGS DOS CONTAINERS${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    echo -e "Escolha o container:"
    echo -e "   ${GREEN}1.${NC} pg_standard (PostgreSQL)"
    echo -e "   ${GREEN}2.${NC} prometheus_pg"
    echo -e "   ${GREEN}3.${NC} grafana_pg"
    echo -e "   ${GREEN}4.${NC} postgres_exporter"
    
    read -p "Opção (1-4): " -n 1 -r
    echo
    
    case $REPLY in
        1) docker logs --tail 50 pg_standard ;;
        2) docker logs --tail 50 prometheus_pg ;;
        3) docker logs --tail 50 grafana_pg ;;
        4) docker logs --tail 50 postgres_exporter ;;
        *) log "ERROR" "Opção inválida" ;;
    esac
    
    read -p "Pressione Enter para continuar..."
}

# Conectar ao PostgreSQL
connect_to_postgres() {
    echo -e "\n${PURPLE}🔌 CONECTANDO AO POSTGRESQL${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "❌ PostgreSQL não está rodando"
        read -p "Pressione Enter para continuar..."
        return 1
    fi
    
    log "INFO" "Conectando ao database ${DATABASE_NAME}..."
    docker exec -it pg_standard psql -U postgres -d "${DATABASE_NAME}"
}

# ================================================================================
# LOOP PRINCIPAL
# ================================================================================

main() {
    # Verificar se estamos no diretório correto
    if [[ ! -f "docker-compose.yml" ]]; then
        log "ERROR" "Arquivo docker-compose.yml não encontrado!"
        log "ERROR" "Execute este script no diretório /postgre"
        exit 1
    fi
    
    # Loop principal do menu interativo
    while true; do
        show_main_menu
        
        echo -ne "\n${YELLOW}Digite sua opção: ${NC}"
        read -r choice
        
        case $choice in
            "1"|"start")
                start_environment
                read -p "Pressione Enter para continuar..."
                ;;
            "2"|"setup")
                setup_database
                read -p "Pressione Enter para continuar..."
                ;;
            "3"|"load-data")
                load_data
                read -p "Pressione Enter para continuar..."
                ;;
            "4"|"benchmark")
                run_benchmark
                read -p "Pressione Enter para continuar..."
                ;;
            "5"|"stop")
                stop_environment
                read -p "Pressione Enter para continuar..."
                ;;
            "6"|"cleanup")
                cleanup_environment
                read -p "Pressione Enter para continuar..."
                ;;
            "7"|"logs")
                show_logs
                ;;
            "8"|"connect")
                connect_to_postgres
                ;;
            "r"|"refresh")
                # Apenas atualiza o menu
                ;;
            "q"|"quit")
                echo -e "\n${GREEN}👋 Até logo!${NC}"
                exit 0
                ;;
            "")
                # Enter vazio apenas atualiza
                ;;
            *)
                log "ERROR" "Opção inválida: $choice"
                read -p "Pressione Enter para continuar..."
                ;;
        esac
    done
}

# Verificar se foi chamado com parâmetro (modo não-interativo)
if [ $# -gt 0 ]; then
    case "$1" in
        "start") start_environment ;;
        "setup") setup_database ;;
        "load-data") load_data ;;
        "benchmark") run_benchmark ;;
        "stop") stop_environment ;;
        "cleanup") cleanup_environment ;;
        "status") 
            show_containers_status
            show_database_status
            show_monitoring_status
            ;;
        *)
            echo "Uso: $0 [start|setup|load-data|benchmark|stop|cleanup|status]"
            echo "Ou execute sem parâmetros para modo interativo"
            exit 1
            ;;
    esac
else
    # Modo interativo
    main
fi