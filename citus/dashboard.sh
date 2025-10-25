#!/bin/bash

# ================================================================================
#                    LABORATÓRIO DE SHARDING DISTRIBUÍDO
#                      PostgreSQL + Citus + Patroni + etcd
#                         Trabalho de Conclusão de Curso
# ================================================================================
#
# Dashboard Interativo - Menu Principal do Laboratório
# Objetivo: Interface de controle para navegação entre módulos experimentais

set -uo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configurações - Adaptado para suportar ambas arquiteturas
COMPOSE_PROJECT_NAME="citus"
DB_NAME="citus_platform"

# Função para detectar arquitetura ativa
detect_architecture() {
    # Verificar se há containers Patroni rodando
    if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$"; then
        echo "patroni"
    elif docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$"; then
        echo "simple"
    else
        echo "none"
    fi
}

# Função para detectar coordinator leader na arquitetura Patroni
detect_leader_coordinator() {
    for i in 1 2 3; do
        local container="citus_coordinator$i"
        if docker ps --format "{{.Names}}" | grep -q "^$container$"; then
            # Verificar se é o leader via API do Patroni
            local role=$(docker exec "$container" curl -s http://localhost:8008/ 2>/dev/null | grep -o '"role":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            if [[ "$role" == "master" ]]; then
                echo "$container"
                return
            fi
        fi
    done
    # Fallback: retorna o primeiro coordinator disponível
    echo "citus_coordinator1"
}

# Função para obter container do coordinator baseado na arquitetura
get_coordinator_container() {
    local arch=$(detect_architecture)
    case $arch in
        "patroni")
            detect_leader_coordinator
            ;;
        "simple")
            echo "citus_coordinator"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Função para limpar tela
clear_screen() {
    clear
    echo -e "${BLUE}"
    echo "================================================================================"
    echo "                    LABORATÓRIO DE SHARDING DISTRIBUÍDO"
    echo "                      PostgreSQL + Citus + Patroni + etcd"
    echo "                         Trabalho de Conclusão de Curso"
    echo "================================================================================"
    echo -e "${NC}"
    echo
}

# Função para mostrar status do cluster
show_cluster_status() {
    echo -e "${CYAN}STATUS DO CLUSTER${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    # Detectar arquitetura ativa
    local arch=$(detect_architecture)
    local coordinator_container=$(get_coordinator_container)
    
    # Verificar se há containers rodando
    CLUSTER_RUNNING=$(docker ps --format "{{.Names}}" | grep "^citus_" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    
    if [ "$CLUSTER_RUNNING" -gt 0 ]; then
        case $arch in
            "patroni")
                echo -e "${GREEN}CLUSTER: ATIVO (${CLUSTER_RUNNING} containers) - Arquitetura PATRONI${NC}"
                show_patroni_status
                ;;
            "simple")
                echo -e "${GREEN}CLUSTER: ATIVO (${CLUSTER_RUNNING} containers) - Arquitetura SIMPLES${NC}"
                show_simple_status
                ;;
            *)
                echo -e "${YELLOW}CLUSTER: PARCIAL (${CLUSTER_RUNNING} containers) - Arquitetura DESCONHECIDA${NC}"
                ;;
        esac
        
        # Status PostgreSQL e Citus (comum para ambas arquiteturas)
        show_postgresql_status "$coordinator_container"
        show_monitoring_status "$arch"
        
    else
        echo -e "${RED}CLUSTER: INATIVO${NC}"
        echo -e "${YELLOW}Execute o módulo Simple Setup para inicializar o ambiente${NC}"
    fi
    echo
}

# Função para mostrar status da arquitetura Patroni
show_patroni_status() {
    echo
    
    # === ETCD CONSENSUS CLUSTER ===
    echo -e "${PURPLE}ETCD Consensus Cluster (Algoritmo Raft):${NC}"
    etcd1_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd1$" && echo "ATIVO" || echo "INATIVO")
    etcd2_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd2$" && echo "ATIVO" || echo "INATIVO")
    etcd3_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd3$" && echo "ATIVO" || echo "INATIVO")
    echo "  - etcd1: $etcd1_status"
    echo "  - etcd2: $etcd2_status"
    echo "  - etcd3: $etcd3_status"
    
    # === COORDINATORS PATRONI HA ===
    echo
    echo -e "${BLUE}Coordinators (Alta Disponibilidade com Patroni):${NC}"
    
    # Verificar qual é o líder
    coord1_role="REPLICA"
    coord2_role="REPLICA"
    coord3_role="REPLICA"
    
    if docker logs citus_coordinator1 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
        coord1_role="LIDER"
    fi
    if docker logs citus_coordinator2 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
        coord2_role="LIDER"
    fi
    if docker logs citus_coordinator3 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
        coord3_role="LIDER"
    fi
    
    coord1_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$" && echo "ATIVO" || echo "INATIVO")
    coord2_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator2$" && echo "ATIVO" || echo "INATIVO")
    coord3_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator3$" && echo "ATIVO" || echo "INATIVO")
    
    echo "  - coordinator1: $coord1_role - $coord1_status"
    echo "  - coordinator2: $coord2_role - $coord2_status"  
    echo "  - coordinator3: $coord3_role - $coord3_status"
    
    # === WORKERS PATRONI HA ===
    echo
    echo -e "${YELLOW}Workers (Alta Disponibilidade com Patroni):${NC}"
    echo "  Grupo 1:"
    worker1p_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1_primary$" && echo "ATIVO" || echo "INATIVO")
    worker1s_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1_standby$" && echo "ATIVO" || echo "INATIVO")
    echo "    - worker1_primary: $worker1p_status"
    echo "    - worker1_standby: $worker1s_status"
    echo "  Grupo 2:"
    worker2p_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2_primary$" && echo "ATIVO" || echo "INATIVO")
    worker2s_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2_standby$" && echo "ATIVO" || echo "INATIVO")
    echo "    - worker2_primary: $worker2p_status"
    echo "    - worker2_standby: $worker2s_status"
}

# Função para mostrar status da arquitetura simples
show_simple_status() {
    echo
    
    # === COORDINATOR SIMPLES ===
    echo -e "${BLUE}Coordinator (Versão Mínima):${NC}"
    coord_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$" && echo "ATIVO" || echo "INATIVO")
    echo "  - coordinator: $coord_status"
    
    # === WORKERS SIMPLES ===
    echo
    echo -e "${YELLOW}Workers (Sem Replicação):${NC}"
    worker1_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1$" && echo "ATIVO" || echo "INATIVO")
    worker2_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2$" && echo "ATIVO" || echo "INATIVO")
    echo "  - worker1: $worker1_status"
    echo "  - worker2: $worker2_status"
}

# Função para mostrar status PostgreSQL (comum para ambas arquiteturas)
show_postgresql_status() {
    local coordinator_container="$1"
    
    echo
    if [[ -n "$coordinator_container" ]] && docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}PostgreSQL: OPERACIONAL${NC}"
        
        # Verificar database primeiro
        if docker exec -i "$coordinator_container" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
            echo -e "${GREEN}Database: $DB_NAME ATIVO${NC}"
            
            # Verificar workers registrados no Citus
            worker_count=$(docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" 2>/dev/null | xargs 2>/dev/null || echo "0")
            echo -e "${GREEN}Workers Citus: $worker_count ativos${NC}"
            
            # Verificar tabelas
            table_count=$(docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | xargs 2>/dev/null || echo "0")
            echo -e "${GREEN}Tabelas: $table_count criadas${NC}"
        else
            echo -e "${YELLOW}Database: Aguardando criação${NC}"
        fi
    else
        echo -e "${RED}PostgreSQL: NÃO RESPONSIVO${NC}"
    fi
}

# Função para mostrar status de monitoramento (adaptado para ambas arquiteturas)
show_monitoring_status() {
    local arch="$1"
    
    echo
    echo -e "${CYAN}Ferramentas de Monitoramento:${NC}"
    
    # Prometheus (nomes diferentes por arquitetura)
    if [[ "$arch" == "patroni" ]]; then
        prometheus_running=$(docker ps --format "{{.Names}}" | grep "citus_prometheus_patroni" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    else
        prometheus_running=$(docker ps --format "{{.Names}}" | grep "citus_prometheus" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    fi
    
    if [ "$prometheus_running" -gt 0 ]; then
        echo -e "${GREEN}  - Prometheus: ATIVO (http://localhost:9090)${NC}"
    else
        echo -e "${YELLOW}  - Prometheus: INDISPONÍVEL${NC}"
    fi
    
    # Grafana (nomes diferentes por arquitetura)
    if [[ "$arch" == "patroni" ]]; then
        grafana_running=$(docker ps --format "{{.Names}}" | grep "citus_grafana_patroni" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    else
        grafana_running=$(docker ps --format "{{.Names}}" | grep "citus_grafana" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    fi
    
    if [ "$grafana_running" -gt 0 ]; then
        echo -e "${GREEN}  - Grafana: ATIVO (http://localhost:3000)${NC}"
    else
        echo -e "${YELLOW}  - Grafana: INDISPONÍVEL${NC}"
    fi
    
    # HAProxy
    haproxy_running=$(docker ps --format "{{.Names}}" | grep "haproxy" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    if [ "$haproxy_running" -gt 0 ]; then
        echo -e "${GREEN}  - HAProxy: ATIVO (http://localhost:5432)${NC}"
    else
        echo -e "${YELLOW}  - HAProxy: INDISPONÍVEL${NC}"
    fi
}

# Função para mostrar estatísticas rápidas
show_quick_stats() {
    local coordinator_container=$(get_coordinator_container)
    
    # Verificar se coordinator está rodando
    if [[ -z "$coordinator_container" ]] || ! docker ps --format "{{.Names}}" | grep -q "^${coordinator_container}$"; then
        return
    fi
    
    # Verificar se PostgreSQL está respondendo
    if ! docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        return
    fi
    
    # Determinar nome do database baseado na arquitetura
    # Verificar se database existe
    if ! docker exec -i "$coordinator_container" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        return
    fi
    
    echo -e "${CYAN}ESTATÍSTICAS DO BANCO DE DADOS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    # Tentar obter estatísticas
    if docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        'Empresas'::text as item,
        COUNT(*)::text as quantidade
    FROM companies
    UNION ALL
    SELECT 
        'Campanhas',
        COUNT(*)::text
    FROM campaigns
    UNION ALL
    SELECT 
        'Anúncios',
        COUNT(*)::text  
    FROM ads;
    " 2>/dev/null; then
        echo
    else
        echo "Dados ainda não carregados"
        echo
    fi
}

# Função principal do menu
show_menu() {
    clear_screen
    show_cluster_status
    show_quick_stats
    
    echo -e "${BLUE}MÓDULOS DISPONÍVEIS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    echo -e "${YELLOW}[1]${NC} Simple Setup (Básico)   - Configurar cluster simples"
    echo -e "${YELLOW}[2]${NC} Simple Setup (Patroni)  - Configurar cluster com Patroni + etcd"
    echo -e "${YELLOW}[3]${NC} Query Experiments       - Testar consultas distribuídas"
    echo -e "${YELLOW}[4]${NC} HA & Failover           - Alta disponibilidade e recuperação"
    echo -e "${YELLOW}[5]${NC} Schema Manager          - Criar schemas personalizados"
    echo
    echo -e "${PURPLE}UTILITÁRIOS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo -e "${YELLOW}[6]${NC} SQL Console             - Conectar diretamente ao cluster"
    echo -e "${YELLOW}[7]${NC} Cluster Monitor         - Visualizar métricas em tempo real"
    echo -e "${YELLOW}[0]${NC} Cleanup                 - Parar e limpar ambiente"
    echo
    echo -e "${RED}[q]${NC} Sair"
    echo
    echo -n -e "${CYAN}Selecione uma opção [0-7,q]: ${NC}"
}

# Função para Schema Manager
schema_manager_menu() {
    clear_screen
    echo -e "${PURPLE}SCHEMA MANAGER${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    echo -e "${CYAN}Funcionalidades Disponíveis:${NC}"
    echo "[1] Listar cenários disponíveis"
    echo "[2] Criar schema completo"
    echo "[3] Gerar dados de exemplo"
    echo "[4] Carregar dados no banco" 
    echo "[5] Processo completo (schema + dados)"
    echo "[0] Voltar"
    echo
    echo -n -e "${CYAN}Escolha uma opção [0-5]: ${NC}"
    read -r schema_choice
    
    case $schema_choice in
        1)
            echo -e "${CYAN}📋 Cenários disponíveis:${NC}"
            ./scripts/schema_manager.sh list
            echo
            echo "Pressione Enter para continuar..."
            read -r
            ;;
        2)
            echo -e "${CYAN}🏗️ Criar schema:${NC}"
            ./scripts/schema_manager.sh interactive
            echo
            echo "Pressione Enter para continuar..."
            read -r
            ;;
        3)
            echo -n -e "${CYAN}Digite o cenário para gerar dados: ${NC}"
            read -r scenario
            if [[ -n "$scenario" ]]; then
                ./scripts/data_loader.sh generate "$scenario"
            fi
            echo
            echo "Pressione Enter para continuar..."
            read -r
            ;;
        4)
            echo -n -e "${CYAN}Digite o cenário para carregar dados: ${NC}"
            read -r scenario
            if [[ -n "$scenario" ]]; then
                ./scripts/data_loader.sh load "$scenario"
            fi
            echo
            echo "Pressione Enter para continuar..."
            read -r
            ;;
        5)
            echo -n -e "${CYAN}Digite o cenário para processo completo: ${NC}"
            read -r scenario
            if [[ -n "$scenario" ]]; then
                echo -e "${YELLOW}🚀 Executando processo completo...${NC}"
                ./scripts/schema_manager.sh create "$scenario"
                ./scripts/data_loader.sh full "$scenario"
            fi
            echo
            echo "Pressione Enter para continuar..."
            read -r
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}❌ Opção inválida!${NC}"
            sleep 1
            schema_manager_menu
            ;;
    esac
    
    # Recursiva para manter o menu ativo
    if [[ "$schema_choice" != "0" ]]; then
        schema_manager_menu
    fi
}

# Função para console SQL
sql_console() {
    clear_screen
    echo -e "${PURPLE}CONSOLE SQL INTERATIVO${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    # Verificações básicas
    if ! docker ps > /dev/null 2>&1; then
        echo -e "${RED}Docker não está rodando!${NC}"
        echo "Inicie o Docker Desktop primeiro."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    local coordinator_container=$(get_coordinator_container)
    if [[ -z "$coordinator_container" ]]; then
        echo -e "${RED}Cluster não está rodando!${NC}"
        echo "Execute o módulo Simple Setup primeiro."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    if ! docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}PostgreSQL não está respondendo!${NC}"
        echo "Aguarde alguns segundos e tente novamente."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    echo -e "${GREEN}PostgreSQL está rodando!${NC}"
    echo -e "${CYAN}Conectando ao console PostgreSQL (banco: $DB_NAME)...${NC}"
    echo -e "${YELLOW}Para sair, digite \\q e pressione Enter${NC}"
    echo
    
    # Conectar diretamente ao PostgreSQL
    docker exec -it "$coordinator_container" psql -U postgres -d "$DB_NAME"
    
    # Mensagem após sair do psql
    echo
    echo -e "${GREEN}Sessão SQL finalizada${NC}"
    echo -e "${CYAN}Pressione Enter para voltar ao menu...${NC}"
    read -r
}

# Função para monitoramento
cluster_monitor() {
    clear_screen
    echo -e "${PURPLE}MONITOR DO CLUSTER${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    local coordinator_container=$(get_coordinator_container)
    if [[ -z "$coordinator_container" ]] || ! docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}Cluster não está rodando!${NC}"
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    echo -e "${CYAN}Distribuição de Shards:${NC}"
    docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        n.nodename,
        n.nodeport,
        COUNT(p.shardid) as shard_count,
        ROUND(COUNT(p.shardid) * 100.0 / SUM(COUNT(p.shardid)) OVER(), 1) as percentage
    FROM pg_dist_node n
    LEFT JOIN pg_dist_shard_placement p ON n.groupid = p.groupid
    WHERE n.noderole = 'primary'
    GROUP BY n.groupid, n.nodename, n.nodeport
    ORDER BY shard_count DESC;
    "
    
    echo
    echo -e "${CYAN}Tamanho das Tabelas:${NC}"
    docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        schemaname, 
        tablename, 
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
    FROM pg_tables 
    WHERE schemaname = 'public'
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
    "
    
    echo
    echo -e "${CYAN}Links de Monitoramento:${NC}"
    echo "- Grafana: http://localhost:3000"
    echo "- Prometheus: http://localhost:9090"
    echo "- Postgres Metrics: http://localhost:9187/metrics"
    echo
    echo "Pressione Enter para voltar..."
    read -r
}

# Função para cleanup
cleanup_environment() {
    clear_screen
    echo -e "${PURPLE}LIMPEZA DO AMBIENTE${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    echo -e "${YELLOW}ATENÇÃO: Esta operação irá:${NC}"
    echo "- Parar todos os containers"
    echo "- Remover volumes de dados"
    echo "- Limpar configurações"
    echo
    echo -n "Deseja continuar? [y/N]: "
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo
        echo -e "${CYAN}Parando containers...${NC}"
        
        # Parar ambas arquiteturas
        docker-compose -f docker-compose-patroni.yml down -v 2>/dev/null || true
        docker-compose down -v 2>/dev/null || true
        
        echo -e "${CYAN}Limpando volumes órfãos...${NC}"
        docker volume prune -f
        
        echo -e "${GREEN}Ambiente limpo com sucesso!${NC}"
    else
        echo -e "${YELLOW}Operação cancelada.${NC}"
    fi
    
    echo
    echo "Pressione Enter para voltar..."
    read -r
}

# Função de ajuda
show_help() {
    clear_screen
    echo -e "${PURPLE}❓ AJUDA E DOCUMENTAÇÃO${NC}"
    echo "═══════════════════════"
    echo
    echo -e "${CYAN}📚 Ordem Recomendada:${NC}"
    echo "1. Simple Setup - Configure o ambiente (ou use Schema Manager)"
    echo "2. Schema Manager - Crie schemas personalizados"
    echo "3. Query Experiments - Teste consultas"
    echo "4. HA & Failover - Alta disponibilidade"
    echo
    echo -e "${CYAN}🛠️  Pré-requisitos:${NC}"
    echo "• Docker & Docker Compose instalados"
    echo "• 8GB+ RAM disponível"
    echo "• Portas livres: 5432, 3000, 9090, 9187, 9100"
    echo
    echo -e "${CYAN}🔗 Links Úteis:${NC}"
    echo "• README.md - Documentação completa"
    echo "• Citus Docs: https://docs.citusdata.com/"
    echo "• PostgreSQL: https://www.postgresql.org/docs/"
    echo
    echo -e "${CYAN}🐛 Troubleshooting:${NC}"
    echo "• Se ports estão ocupadas: docker-compose down"
    echo "• Se falta memória: feche outras aplicações"
    echo "• Para reset completo: use a opção Cleanup"
    echo
    echo "Pressione Enter para voltar..."
    read -r
}

# Loop principal
main() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                echo -e "${CYAN}Executando Simple Setup (Básico)...${NC}"
                echo -e "${YELLOW}Iniciando cluster com arquitetura simples${NC}"
                # Verificar se já existe um cluster Patroni rodando
                if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$"; then
                    echo -e "${RED}ATENÇÃO: Cluster Patroni detectado! Faça cleanup primeiro.${NC}"
                    echo "Pressione Enter para continuar..."
                    read -r
                    return
                fi
                
                echo -e "${CYAN}Iniciando containers...${NC}"
                docker-compose up -d
                
                echo -e "${CYAN}Aguardando PostgreSQL inicializar...${NC}"
                sleep 10
                
                # Aguardar coordinator estar pronto
                echo -e "${CYAN}Verificando se coordinator está pronto...${NC}"
                for i in {1..30}; do
                    if docker exec citus_coordinator pg_isready -U postgres > /dev/null 2>&1; then
                        echo -e "${GREEN}Coordinator está pronto!${NC}"
                        break
                    fi
                    echo "Aguardando... ($i/30)"
                    sleep 2
                done
                
                # Registrar workers no Citus
                echo -e "${CYAN}Registrando workers no Citus...${NC}"
                
                # Aguardar workers estarem prontos
                sleep 5
                
                # Registrar worker 1
                echo "Registrando worker1..."
                docker exec citus_coordinator psql -U postgres -d citus_platform -c "SELECT citus_add_node('worker1', 5432);" 2>/dev/null || echo "Worker1 já registrado ou erro"
                
                # Registrar worker 2
                echo "Registrando worker2..."
                docker exec citus_coordinator psql -U postgres -d citus_platform -c "SELECT citus_add_node('worker2', 5432);" 2>/dev/null || echo "Worker2 já registrado ou erro"
                
                # Verificar workers registrados
                echo -e "${CYAN}Verificando workers registrados:${NC}"
                docker exec citus_coordinator psql -U postgres -d citus_platform -c "SELECT * FROM citus_get_active_worker_nodes();"
                
                echo -e "${GREEN}Setup simples concluído!${NC}"
                echo "Pressione Enter para continuar..."
                read -r
                ;;
            2)
                echo -e "${CYAN}Executando Simple Setup (Patroni)...${NC}"
                echo -e "${YELLOW}Iniciando cluster com Patroni + etcd${NC}"
                # Verificar se já existe um cluster simples rodando
                if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$"; then
                    echo -e "${RED}ATENÇÃO: Cluster simples detectado! Faça cleanup primeiro.${NC}"
                    echo "Pressione Enter para continuar..."
                    read -r
                    return
                fi
                ./02_simple_setup.sh
                ;;
            3)
                echo -e "${CYAN}Executando Query Experiments...${NC}"
                ./03_query_experiments.sh
                ;;
            4)
                echo -e "${CYAN}Executando HA & Failover...${NC}"
                ./06_ha_failover.sh
                ;;
            5)
                schema_manager_menu
                ;;
            6)
                sql_console
                clear
                ;;
            7)
                cluster_monitor
                clear
                ;;
            0)
                cleanup_environment
                clear
                ;;
            q|Q|quit|exit)
                echo -e "${GREEN}Obrigado por usar o laboratório!${NC}"
                echo -e "${CYAN}Trabalho de Conclusão de Curso finalizado.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida. Tente novamente.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Verificar se está no diretório correto
if [[ ! -f "docker-compose-patroni.yml" ]]; then
    echo -e "${RED}ERRO: Execute este script do diretório citus${NC}"
    echo -e "${YELLOW}Certifique-se que o arquivo docker-compose-patroni.yml existe${NC}"
    exit 1
fi

# Executar menu principal
main
