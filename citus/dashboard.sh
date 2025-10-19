#!/bin/bash

# ██████╗  █████╗ ███████╗██╗  ██╗██████╗  ██████╗  █████╗ ██████╗ ██╗██████╗ 
# ██╔══██╗██╔══██╗██╔════╝██║  ██║██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██║██╔══██╗
# ██║  ██║███████║███████╗███████║██████╔╝██║     echo -e "${BLUE}🎯 MÓDULOS DISPONÍVEIS${NC}"
    echo "════════════════════="
    echo
    echo -e "${YELLOW}1.${NC} 🛠️  Simple Setup         - ${CYAN}Configurar cluster (Apple Silicon)${NC}"
    echo -e "${YELLOW}2.${NC} 🔍 Query Experiments    - ${CYAN}Testar consultas distribuídas${NC}"
    echo -e "${YELLOW}3.${NC} 🛡️  HA & Failover        - ${CYAN}Alta disponibilidade e recuperação${NC}"
    echo -e "${YELLOW}4.${NC} 🏗️  Schema Manager       - ${CYAN}Criar schemas personalizados${NC}"████║██████╔╝██║██║  ██║
# ██║  ██║██╔══██║╚════██║██╔══██║██╔══██╗██║   ██║██╔══██║██╔══██╗██║██║  ██║
# ██████╔╝██║  ██║███████║██║  ██║██████╔╝╚██████╔╝██║  ██║██║  ██║██║██████╔╝
# ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═════╝ 
#
# 📊 DASHBOARD INTERATIVO: Menu Principal do Laboratório
# Objetivo: Interface amigável para navegação entre módulos

set -uo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configurações - Adaptado para Patroni
COMPOSE_PROJECT_NAME="citus"
COORDINATOR_CONTAINER="citus_coordinator1"
DB_NAME="citus"

# Função para limpar tela
clear_screen() {
    clear
    echo -e "${PURPLE}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║    ████████╗ ██████╗ ██████╗      ██████╗██╗████████╗██╗   ██╗███████╗      ║
║    ╚══██╔══╝██╔════╝██╔════╝     ██╔════╝██║╚══██╔══╝██║   ██║██╔════╝      ║
║       ██║   ██║     ██║          ██║     ██║   ██║   ██║   ██║███████╗      ║
║       ██║   ██║     ██║          ██║     ██║   ██║   ██║   ██║╚════██║      ║
║       ██║   ╚██████╗╚██████╗     ╚██████╗██║   ██║   ╚██████╔╝███████║      ║
║       ╚═╝    ╚═════╝ ╚═════╝      ╚═════╝╚═╝   ╚═╝    ╚═════╝ ╚══════╝      ║
║                                                                              ║
║               🎓 LABORATÓRIO EDUCACIONAL DE SHARDING                        ║
║                 🔄 Alta Disponibilidade com PATRONI + CITUS                 ║
║               📊 Arquitetura Distribuída com Consenso etcd                  ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Função para mostrar status do cluster
show_cluster_status() {
    echo -e "${CYAN}📊 STATUS DA ARQUITETURA PATRONI + CITUS${NC}"
    echo "═══════════════════════════════════════════"
    
    # Verificar se há containers rodando
    CLUSTER_RUNNING=$(docker ps --format "{{.Names}}" | grep -c "^citus_" || echo "0")
    
    if [ "$CLUSTER_RUNNING" -gt 0 ]; then
        echo -e "${GREEN}🏗️  CLUSTER: ATIVO (${CLUSTER_RUNNING} containers)${NC}"
        echo
        
        # === ETCD CONSENSUS CLUSTER ===
        echo -e "${PURPLE}⚖️  ETCD CONSENSUS (Raft Algorithm):${NC}"
        etcd1_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd1$" && echo "🟢 ATIVO" || echo "🔴 INATIVO")
        etcd2_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd2$" && echo "🟢 ATIVO" || echo "🔴 INATIVO")
        etcd3_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd3$" && echo "🟢 ATIVO" || echo "🔴 INATIVO")
        echo "   • etcd1: $etcd1_status"
        echo "   • etcd2: $etcd2_status"
        echo "   • etcd3: $etcd3_status"
        
        # === COORDINATORS PATRONI HA ===
        echo
        echo -e "${BLUE}🎯 COORDINATORS (Patroni HA):${NC}"
        
        # Verificar qual é o líder
        coord1_role="🔵 RÉPLICA"
        coord2_role="🔵 RÉPLICA"
        coord3_role="🔵 RÉPLICA"
        
        if docker logs citus_coordinator1 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
            coord1_role="🟢 LÍDER"
        fi
        if docker logs citus_coordinator2 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
            coord2_role="🟢 LÍDER"
        fi
        if docker logs citus_coordinator3 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
            coord3_role="🟢 LÍDER"
        fi
        
        coord1_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$" && echo "ATIVO" || echo "INATIVO")
        coord2_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator2$" && echo "ATIVO" || echo "INATIVO")
        coord3_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator3$" && echo "ATIVO" || echo "INATIVO")
        
        echo "   • coordinator1: $coord1_role - $coord1_status"
        echo "   • coordinator2: $coord2_role - $coord2_status"  
        echo "   • coordinator3: $coord3_role - $coord3_status"
        
        # === WORKERS PATRONI HA ===
        echo
        echo -e "${YELLOW}🔧 WORKERS (Patroni HA):${NC}"
        echo "   Grupo 1:"
        worker1p_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1_primary$" && echo "🟢 ATIVO" || echo "🔴 INATIVO")
        worker1s_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1_standby$" && echo "🟢 ATIVO" || echo "🔴 INATIVO")
        echo "     • worker1_primary: $worker1p_status"
        echo "     • worker1_standby: $worker1s_status"
        echo "   Grupo 2:"
        worker2p_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2_primary$" && echo "🟢 ATIVO" || echo "🔴 INATIVO")
        worker2s_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2_standby$" && echo "🟢 ATIVO" || echo "🔴 INATIVO")
        echo "     • worker2_primary: $worker2p_status"
        echo "     • worker2_standby: $worker2s_status"
        
        # === POSTGRESQL & CITUS STATUS ===
        echo
        if docker exec "citus_coordinator1" pg_isready -U postgres > /dev/null 2>&1; then
            echo -e "${GREEN}🐘 PostgreSQL: RESPONDENDO${NC}"
            
            # Verificar database primeiro
            if docker exec -i "citus_coordinator1" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
                echo -e "${GREEN}🗄️  Database: $DB_NAME ATIVO${NC}"
                
                # Verificar workers registrados no Citus
                worker_count=$(docker exec -i "citus_coordinator1" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" 2>/dev/null | xargs 2>/dev/null || echo "0")
                echo -e "${GREEN}📊 Workers Citus: $worker_count ativos (apenas primários)${NC}"
                
                # Verificar tabelas
                table_count=$(docker exec -i "citus_coordinator1" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | xargs 2>/dev/null || echo "0")
                echo -e "${GREEN}📋 Tabelas: $table_count criadas${NC}"
            else
                echo -e "${YELLOW}⚠️  Database: Não criado${NC}"
            fi
        else
            echo -e "${RED}❌ PostgreSQL: Não responsivo${NC}"
        fi
        
        # === MONITORAMENTO ===
        echo
        echo -e "${CYAN}📊 MONITORAMENTO:${NC}"
        prometheus_running=$(docker ps --format "{{.Names}}" | grep -c "prometheus" || echo "0")
        if [ "$prometheus_running" -gt 0 ]; then
            echo -e "${GREEN}   • Prometheus: ✅ http://localhost:9090${NC}"
        else
            echo -e "${YELLOW}   • Prometheus: ⚠️  Indisponível${NC}"
        fi
        
        grafana_running=$(docker ps --format "{{.Names}}" | grep -c "grafana" || echo "0")
        if [ "$grafana_running" -gt 0 ]; then
            echo -e "${GREEN}   • Grafana: ✅ http://localhost:3000${NC}"
        else
            echo -e "${YELLOW}   • Grafana: ⚠️  Indisponível${NC}"
        fi
        
        haproxy_running=$(docker ps --format "{{.Names}}" | grep -c "haproxy" || echo "0")
        if [ "$haproxy_running" -gt 0 ]; then
            echo -e "${GREEN}   • HAProxy: ✅ http://localhost:5432${NC}"
        else
            echo -e "${YELLOW}   • HAProxy: ⚠️  Indisponível${NC}"
        fi
        
    else
        echo -e "${RED}❌ CLUSTER: INATIVO${NC}"
        echo -e "${YELLOW}💡 Execute o Módulo 2 (Simple Setup) para inicializar${NC}"
    fi
    echo
}

# Função para mostrar estatísticas rápidas
show_quick_stats() {
    # Verificar se master está rodando
    if ! docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$"; then
        return
    fi
    
    # Verificar se PostgreSQL está respondende
    if ! docker exec "citus_coordinator1" pg_isready -U postgres > /dev/null 2>&1; then
        return
    fi
    
    # Verificar se database existe
    if ! docker exec -i "citus_coordinator1" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        return
    fi
    
    echo -e "${CYAN}📈 ESTATÍSTICAS RÁPIDAS${NC}"
    echo "══════════════════════"
    
    # Tentar obter estatísticas
    if docker exec -i "citus_coordinator1" psql -U postgres -d "$DB_NAME" -c "
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
    
    echo -e "${BLUE}🎯 MÓDULOS DISPONÍVEIS${NC}"
    echo "════════════════════="
    echo
    echo -e "${YELLOW}1.${NC} 🔥 Crisis Simulator     - ${CYAN}Por que precisamos de sharding?${NC}"
    echo -e "${YELLOW}2.${NC} 🛠️  Simple Setup         - ${CYAN}Configurar cluster (Apple Silicon)${NC}"
    echo -e "${YELLOW}3.${NC} 🔍 Query Experiments    - ${CYAN}Testar consultas distribuídas${NC}"
    echo -e "${YELLOW}4.${NC} ️  HA & Failover        - ${CYAN}Alta disponibilidade e recuperação${NC}"
    echo -e "${YELLOW}5.${NC} 🏗️  Schema Manager       - ${CYAN}Criar schemas personalizados${NC}"
    echo
    echo -e "${PURPLE}Utilitários:${NC}"
    echo -e "${YELLOW}5.${NC} 💻 SQL Console          - ${CYAN}Conectar diretamente ao cluster${NC}"
    echo -e "${YELLOW}6.${NC} 📊 Cluster Monitor      - ${CYAN}Visualizar métricas em tempo real${NC}"
    echo -e "${YELLOW}0.${NC} 🧹 Cleanup             - ${CYAN}Parar e limpar ambiente${NC}"
    echo
    echo
    echo -e "${RED}q.${NC} 🚪 Sair"
    echo
    echo -n -e "${CYAN}Escolha uma opção [0-6,q]: ${NC}"
}

# Função para Schema Manager
schema_manager_menu() {
    clear_screen
    echo -e "${PURPLE}🏗️  SCHEMA MANAGER${NC}"
    echo "═══════════════════"
    echo
    
    echo -e "${CYAN}📋 Funcionalidades Disponíveis:${NC}"
    echo "1. 📊 Listar cenários disponíveis"
    echo "2. 🏗️  Criar schema completo"
    echo "3. 📊 Gerar dados de exemplo"
    echo "4. 📥 Carregar dados no banco" 
    echo "5. 🎯 Processo completo (schema + dados)"
    echo "0. ⬅️  Voltar"
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
    echo -e "${PURPLE}💻 SQL CONSOLE INTERATIVO${NC}"
    echo "═══════════════════════════"
    echo
    
    # Verificações básicas
    if ! docker ps > /dev/null 2>&1; then
        echo -e "${RED}❌ Docker não está rodando!${NC}"
        echo "Inicie o Docker Desktop primeiro."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    if ! docker ps --format "{{.Names}}" | grep -q "^adtech_coordinator_primary$"; then
        echo -e "${RED}❌ Cluster não está rodando!${NC}"
        echo "Execute o Módulo 2 primeiro."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    if ! docker exec "adtech_coordinator_primary" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}❌ Cluster não está rodando!${NC}"
        echo "Execute o Módulo 2 primeiro."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    if ! docker exec "adtech_coordinator_primary" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}❌ PostgreSQL não está respondendo!${NC}"
        echo "Aguarde alguns segundos e tente novamente."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    echo -e "${GREEN}✅ PostgreSQL está rodando!${NC}"
    echo -e "${CYAN}🐚 Conectando ao console PostgreSQL...${NC}"
    echo -e "${YELLOW}💡 Para sair, digite \\q e pressione Enter${NC}"
    echo
    
    # Conectar diretamente ao PostgreSQL
    docker exec -it "adtech_coordinator_primary" psql -U postgres -d "$DB_NAME"
    
    # Mensagem após sair do psql
    echo
    echo -e "${GREEN}✅ Sessão SQL finalizada${NC}"
    echo -e "${CYAN}Pressione Enter para voltar ao menu...${NC}"
    read -r
}

# Função para monitoramento
cluster_monitor() {
    clear_screen
    echo -e "${PURPLE}📊 MONITOR DO CLUSTER${NC}"
    echo "════════════════════════"
    echo
    
    if ! docker exec "adtech_coordinator_primary" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}❌ Cluster não está rodando!${NC}"
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    echo -e "${CYAN}📈 Distribuição de Shards:${NC}"
    docker exec -i "adtech_coordinator_primary" psql -U postgres -d "$DB_NAME" -c "
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
    echo -e "${CYAN}🔍 Tamanho das Tabelas:${NC}"
    docker exec -i "adtech_coordinator_primary" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        schemaname, 
        tablename, 
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
    FROM pg_tables 
    WHERE schemaname = 'public'
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
    "
    
    echo
    echo -e "${CYAN}📊 Links de Monitoramento:${NC}"
    echo "• Grafana: http://localhost:3000"
    echo "• Prometheus: http://localhost:9090"
    echo "• Postgres Metrics: http://localhost:9187/metrics"
    echo
    echo "Pressione Enter para voltar..."
    read -r
}

# Função para cleanup
cleanup_environment() {
    clear_screen
    echo -e "${PURPLE}🧹 LIMPEZA DO AMBIENTE${NC}"
    echo "═══════════════════════"
    echo
    
    echo -e "${YELLOW}⚠️  Esta operação irá:${NC}"
    echo "• Parar todos os containers"
    echo "• Remover volumes de dados"
    echo "• Limpar configurações"
    echo
    echo -n "Deseja continuar? [y/N]: "
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo
        echo -e "${CYAN}🛑 Parando containers...${NC}"
        docker-compose -f docker-compose-patroni.yml down -v 2>/dev/null || true
        
        echo -e "${CYAN}🧹 Limpando volumes órfãos...${NC}"
        docker volume prune -f
        
        echo -e "${GREEN}✅ Ambiente limpo!${NC}"
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
                echo -e "${CYAN}️ Executando Simple Setup...${NC}"
                ./02_simple_setup.sh
                ;;
            2)
                echo -e "${CYAN}🔍 Executando Query Experiments...${NC}"
                ./03_query_experiments.sh
                ;;
            3)
                echo -e "${CYAN}️ Executando HA & Failover...${NC}"
                ./06_ha_failover.sh
                ;;
            4)
                schema_manager_menu
                ;;
            5)
                sql_console
                clear
                ;;
            6)
                cluster_monitor
                clear
                ;;
            0)
                cleanup_environment
                clear
                ;;
            q|Q|quit|exit)
                echo -e "${GREEN}👋 Obrigado por usar o laboratório!${NC}"
                echo -e "${CYAN}Boa sorte com seu TCC! 🎓${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Opção inválida!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Verificar se está no diretório correto
if [[ ! -f "docker-compose-patroni.yml" ]]; then
    echo -e "${RED}❌ Execute este script do diretório citus!${NC}"
    echo -e "${YELLOW}💡 Certifique-se que o arquivo docker-compose-patroni.yml existe${NC}"
    exit 1
fi

# Executar menu principal
main
