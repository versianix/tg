#!/bin/bash

# ██████╗  █████╗ ███████╗██╗  ██╗██████╗  ██████╗  █████╗ ██████╗ ██╗██████╗ 
# ██╔══██╗██╔══██╗██╔════╝██║  ██║██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██║██╔══██╗
# ██║  ██║███████║███████╗███████║██████╔╝██║   ██║███████║██████╔╝██║██║  ██║
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

# Configurações
COMPOSE_PROJECT_NAME="adtech_cluster"
DB_NAME="adtech_platform"

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
║                    Bancos de Dados Distribuídos                             ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Função para mostrar status do cluster
show_cluster_status() {
    echo -e "${CYAN}📊 STATUS DO CLUSTER${NC}"
    echo "════════════════════"
    
    # Verificação mais robusta do master
    MASTER_RUNNING=$(docker ps --format "{{.Names}}" | grep "^${COMPOSE_PROJECT_NAME}_master$" | wc -l)
    
    if [ "$MASTER_RUNNING" -gt 0 ]; then
        echo -e "${GREEN}✅ Cluster: ATIVO${NC}"
        
        if docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
            echo -e "${GREEN}✅ PostgreSQL: RODANDO${NC}"
            
            # Verificar database primeiro
            if docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
                echo -e "${GREEN}✅ Database: $DB_NAME criado${NC}"
                
                # Verificar workers só se database existir
                worker_count=$(docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM master_get_active_worker_nodes();" 2>/dev/null | xargs 2>/dev/null || echo "0")
                echo -e "${GREEN}✅ Workers: $worker_count ativos${NC}"
                
                # Verificar tabelas
                table_count=$(docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | xargs 2>/dev/null || echo "0")
                echo -e "${GREEN}✅ Tabelas: $table_count criadas${NC}"
            else
                echo -e "${YELLOW}⚠️  Database: Não criado${NC}"
                echo -e "${YELLOW}⚠️  Workers: N/A (sem database)${NC}"
            fi
            # Verificar serviços de monitoramento apenas se PostgreSQL estiver respondendo
            prometheus_running=$(docker ps --format "{{.Names}}" | grep -c "prometheus" || echo "0")
            if [ "$prometheus_running" -gt 0 ]; then
                echo -e "${GREEN}✅ Prometheus: http://localhost:9090${NC}"
            else
                echo -e "${YELLOW}⚠️  Prometheus: Indisponível${NC}"
            fi
            
            grafana_running=$(docker ps --format "{{.Names}}" | grep -c "grafana" || echo "0")
            if [ "$grafana_running" -gt 0 ]; then
                echo -e "${GREEN}✅ Grafana: http://localhost:3000${NC}"
            else
                echo -e "${YELLOW}⚠️  Grafana: Indisponível${NC}"
            fi
        else
            echo -e "${RED}❌ PostgreSQL: Não responsivo${NC}"
        fi
    else
        echo -e "${RED}❌ Cluster: INATIVO${NC}"
        echo -e "${YELLOW}💡 Execute o Módulo 2 para inicializar${NC}"
    fi
    echo
}

# Função para mostrar estatísticas rápidas
show_quick_stats() {
    # Verificar se master está rodando
    if ! docker ps --format "{{.Names}}" | grep -q "^${COMPOSE_PROJECT_NAME}_master$"; then
        return
    fi
    
    # Verificar se PostgreSQL está respondende
    if ! docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
        return
    fi
    
    # Verificar se database existe
    if ! docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        return
    fi
    
    echo -e "${CYAN}📈 ESTATÍSTICAS RÁPIDAS${NC}"
    echo "══════════════════════"
    
    # Tentar obter estatísticas
    if docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
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
    echo -e "${YELLOW}4.${NC} 📈 Scaling Demo         - ${CYAN}Ver rebalanceamento em ação${NC}"
    echo -e "${YELLOW}5.${NC} 🎓 Advanced Features    - ${CYAN}Recursos para produção${NC}"
    echo -e "${YELLOW}6.${NC} 🛡️  HA & Failover        - ${CYAN}Alta disponibilidade e recuperação${NC}"
    echo
    echo -e "${PURPLE}Utilitários:${NC}"
    echo -e "${YELLOW}7.${NC} 💻 SQL Console          - ${CYAN}Conectar diretamente ao cluster${NC}"
    echo -e "${YELLOW}8.${NC} 📊 Cluster Monitor      - ${CYAN}Visualizar métricas em tempo real${NC}"
    echo -e "${YELLOW}9.${NC} 🧹 Cleanup             - ${CYAN}Parar e limpar ambiente${NC}"
    echo -e "${YELLOW}0.${NC} ❓ Help                 - ${CYAN}Ajuda e documentação${NC}"
    echo
    echo
    echo -e "${RED}q.${NC} 🚪 Sair"
    echo
    echo -n -e "${CYAN}Escolha uma opção [0-9,q]: ${NC}"
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
    
    if ! docker ps --format "{{.Names}}" | grep -q "^${COMPOSE_PROJECT_NAME}_master$"; then
        echo -e "${RED}❌ Cluster não está rodando!${NC}"
        echo "Execute o Módulo 2 primeiro."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    if ! docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}❌ Cluster não está rodando!${NC}"
        echo "Execute o Módulo 2 primeiro."
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    if ! docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
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
    docker exec -it "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME"
    
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
    
    if ! docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}❌ Cluster não está rodando!${NC}"
        echo
        echo "Pressione Enter para voltar..."
        read -r
        return
    fi
    
    echo -e "${CYAN}📈 Distribuição de Shards:${NC}"
    docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
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
    docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
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
        docker-compose down -v 2>/dev/null || true
        
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
    echo "1. Crisis Simulator - Entenda o problema"
    echo "2. Hands-on Setup - Configure o ambiente"
    echo "3. Query Experiments - Teste consultas"
    echo "4. Scaling Demo - Veja scaling em ação"
    echo "5. Advanced Features - Recursos avançados"
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
                echo -e "${CYAN}🔥 Executando Crisis Simulator...${NC}"
                ./01_crisis_simulator.sh
                ;;
            2)
                echo -e "${CYAN}🛠️ Executando Simple Setup...${NC}"
                ./02_simple_setup.sh
                ;;
            3)
                echo -e "${CYAN}🔍 Executando Query Experiments...${NC}"
                ./03_query_experiments.sh
                ;;
            4)
                echo -e "${CYAN}📈 Executando Scaling Demo...${NC}"
                ./04_scaling_demo.sh
                ;;
            5)
                echo -e "${CYAN}🎓 Executando Advanced Features...${NC}"
                ./05_advanced_features.sh
                ;;
            6)
                echo -e "${CYAN}🛡️ Executando HA & Failover...${NC}"
                ./06_ha_failover.sh
                ;;
            7)
                sql_console
                clear
                ;;
            8)
                cluster_monitor
                clear
                ;;
            9)
                cleanup_environment
                clear
                ;;
            0)
                show_help
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
if [[ ! -f "docker-compose.yml" ]]; then
    echo -e "${RED}❌ Execute este script do diretório citus!${NC}"
    exit 1
fi

# Executar menu principal
main
