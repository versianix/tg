#!/bin/bash

# 🎯 DEMONSTRAÇÃO: High Availability & Failover Automático
# Objetivo: Mostrar como Citus mantém disponibilidade mesmo com falhas

set -uo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configurações
COMPOSE_PROJECT_NAME="adtech_cluster"
DB_NAME="adtech_platform"

echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}║              🛡️  HIGH AVAILABILITY & FAILOVER                ║${NC}"
echo -e "${PURPLE}║      Demonstrando resiliência em ambiente distribuído       ║${NC}"
echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# Verificar se cluster está rodando
if ! docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
    echo -e "${RED}❌ Cluster básico não está rodando!${NC}"
    echo -e "${YELLOW}💡 Execute ./02_simple_setup.sh primeiro${NC}"
    exit 1
fi

# Função para mostrar topologia atual
show_topology() {
    local step="$1"
    echo -e "${CYAN}🏗️  $step - TOPOLOGIA ATUAL${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    
    echo -e "${BOLD}📊 COORDINATOR:${NC}"
    if docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Master: ${COMPOSE_PROJECT_NAME}_master (PRIMARY)${NC}"
    else
        echo -e "${RED}❌ Master: ${COMPOSE_PROJECT_NAME}_master (DOWN)${NC}"
    fi
    
    echo -e "${BOLD}🔄 WORKERS:${NC}"
    docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        nodename as worker,
        nodeport as port,
        CASE WHEN isactive THEN '✅ ACTIVE' ELSE '❌ INACTIVE' END as status
    FROM pg_dist_node 
    WHERE noderole = 'primary'
    ORDER BY nodename;
    " 2>/dev/null || echo "Não foi possível conectar ao master"
    
    echo
}

# Função para executar query de teste
test_query() {
    local description="$1"
    echo -e "${YELLOW}🔍 $description${NC}"
    
    start_time=$(date +%s.%N)
    if docker exec -i "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        COUNT(*) as total_companies,
        SUM(CASE WHEN name LIKE 'Empresa Teste %' THEN 1 ELSE 0 END) as test_companies
    FROM companies;
    " 2>/dev/null; then
        end_time=$(date +%s.%N)
        duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "N/A")
        echo -e "${GREEN}✅ Query executada com sucesso (${duration}s)${NC}"
    else
        echo -e "${RED}❌ Query falhou - cluster pode estar indisponível${NC}"
    fi
    echo
}

# Função para simular falha
simulate_failure() {
    local target="$1"
    local description="$2"
    
    echo -e "${RED}💥 SIMULANDO FALHA: $description${NC}"
    echo -e "${RED}═══════════════════════════════════════════════${NC}"
    
    case $target in
        "worker1")
            echo -e "${YELLOW}🔌 Desconectando Worker 1...${NC}"
            docker pause "${COMPOSE_PROJECT_NAME}_worker1" 2>/dev/null || true
            ;;
        "worker2")
            echo -e "${YELLOW}🔌 Desconectando Worker 2...${NC}"
            docker pause "${COMPOSE_PROJECT_NAME}_worker2" 2>/dev/null || true
            ;;
        "master")
            echo -e "${YELLOW}🔌 Desconectando Master...${NC}"
            docker pause "${COMPOSE_PROJECT_NAME}_master" 2>/dev/null || true
            ;;
    esac
    
    sleep 3
    echo -e "${RED}💥 Falha simulada!${NC}"
    echo
}

# Função para recuperar serviço
recover_service() {
    local target="$1"
    local description="$2"
    
    echo -e "${GREEN}🔧 RECUPERANDO SERVIÇO: $description${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    
    case $target in
        "worker1")
            echo -e "${CYAN}🔄 Reconectando Worker 1...${NC}"
            docker unpause "${COMPOSE_PROJECT_NAME}_worker1" 2>/dev/null || true
            ;;
        "worker2")
            echo -e "${CYAN}🔄 Reconectando Worker 2...${NC}"
            docker unpause "${COMPOSE_PROJECT_NAME}_worker2" 2>/dev/null || true
            ;;
        "master")
            echo -e "${CYAN}🔄 Reconectando Master...${NC}"
            docker unpause "${COMPOSE_PROJECT_NAME}_master" 2>/dev/null || true
            ;;
    esac
    
    sleep 5
    echo -e "${GREEN}✅ Serviço recuperado!${NC}"
    echo
}

echo -e "${BLUE}🎯 CENÁRIO INICIAL${NC}"
echo "═══════════════════════"

show_topology "PASSO 1"
test_query "Query baseline (sistema saudável)"

echo -e "${CYAN}Pressione Enter para simular falha no Worker 1...${NC}"
read -r

echo -e "${BLUE}💥 CENÁRIO 1: FALHA DE WORKER${NC}"
echo "═══════════════════════════════════"

simulate_failure "worker1" "Worker 1 indisponível"
show_topology "PASSO 2"

echo -e "${YELLOW}🤔 O que acontece com queries que dependem dos shards do Worker 1?${NC}"
test_query "Query durante falha de worker"

echo -e "${CYAN}Pressione Enter para recuperar Worker 1...${NC}"
read -r

recover_service "worker1" "Worker 1 voltando online"
show_topology "PASSO 3"
test_query "Query após recuperação do worker"

echo -e "${CYAN}Pressione Enter para simular falha mais severa...${NC}"
read -r

echo -e "${BLUE}💥 CENÁRIO 2: MÚLTIPLAS FALHAS${NC}"
echo "════════════════════════════════"

simulate_failure "worker1" "Worker 1 down"
sleep 2
simulate_failure "worker2" "Worker 2 down (disaster!)"

show_topology "PASSO 4"

echo -e "${YELLOW}🚨 ATENÇÃO: Ambos workers falharam!${NC}"
echo "Isso representa um cenário de disaster recovery"
echo

test_query "Query durante disaster (esperado: falha total)"

echo -e "${CYAN}Pressione Enter para iniciar recuperação de disaster...${NC}"
read -r

echo -e "${GREEN}🆘 RECUPERAÇÃO DE DISASTER${NC}"
echo "══════════════════════════════"

recover_service "worker1" "Primeiro worker de volta"
test_query "Query com 1 worker recuperado (dados parciais)"

recover_service "worker2" "Segundo worker de volta"
show_topology "PASSO 5"
test_query "Query com cluster totalmente recuperado"

echo -e "${CYAN}Pressione Enter para demonstrar failover de coordinator...${NC}"
read -r

echo -e "${BLUE}💥 CENÁRIO 3: FALHA DO COORDINATOR${NC}"
echo "═══════════════════════════════════════"

echo -e "${YELLOW}⚠️  Este é o cenário mais crítico!${NC}"
echo "O coordinator é o ponto central do cluster Citus"
echo

simulate_failure "master" "Coordinator indisponível"

echo -e "${RED}🚨 SEM COORDINATOR = SEM CLUSTER${NC}"
echo "- Não é possível executar queries distribuídas"
echo "- Workers ficam órfãos"
echo "- Aplicações param de funcionar"
echo

test_query "Query sem coordinator (falha esperada)"

echo -e "${CYAN}Pressione Enter para recuperar coordinator...${NC}"
read -r

recover_service "master" "Coordinator voltando online"

# Aguardar coordinator se estabilizar
echo -e "${CYAN}⏳ Aguardando coordinator se estabilizar...${NC}"
sleep 10

show_topology "PASSO 6"
test_query "Query após recuperação do coordinator"

echo -e "${BLUE}📊 ANÁLISE DE RESILIÊNCIA${NC}"
echo "═══════════════════════════"

echo -e "${CYAN}🎯 Lições Aprendidas:${NC}"
echo
echo -e "${GREEN}✅ CENÁRIOS QUE CITUS SUPORTA BEM:${NC}"
echo "• Falha de worker individual - queries continuam funcionando"
echo "• Recuperação automática de workers"
echo "• Redistribuição de carga entre workers saudáveis"
echo
echo -e "${YELLOW}⚠️  PONTOS DE ATENÇÃO:${NC}"
echo "• Múltiplas falhas simultâneas podem causar indisponibilidade"
echo "• Dados em workers falhados ficam temporariamente inacessíveis"
echo "• Queries cross-shard são mais vulneráveis"
echo
echo -e "${RED}❌ PONTOS CRÍTICOS:${NC}"
echo "• Falha do coordinator para todo o cluster"
echo "• Sem replicação, dados podem ser perdidos"
echo "• Recovery manual pode ser necessário"

echo -e "${BLUE}🏗️  SOLUÇÕES PARA PRODUÇÃO${NC}"
echo "══════════════════════════════"

echo -e "${CYAN}📋 Recomendações Arquiteturais:${NC}"
echo
echo "1. 🔄 **COORDINATOR HA**"
echo "   • pg_auto_failover para coordinator"
echo "   • Streaming replication"
echo "   • VIP/Load balancer"
echo
echo "2. 🏭 **WORKER REPLICATION**"
echo "   • Cada worker com standby"
echo "   • Replicação síncrona/assíncrona"
echo "   • Auto-failover por worker group"
echo
echo "3. 📊 **MONITORING**"
echo "   • Health checks contínuos"
echo "   • Alertas proativos"
echo "   • Métricas de replication lag"
echo
echo "4. 🛠️  **OPERATIONAL**"
echo "   • Backups regulares"
echo "   • Disaster recovery testado"
echo "   • Runbooks documentados"

echo -e "${BLUE}🧪 IMPLEMENTAÇÃO HA AVANÇADA${NC}"
echo "════════════════════════════════"

echo -e "${YELLOW}💡 Para implementar HA real, seria necessário:${NC}"
echo

cat << 'EOF'
# docker-compose-ha.yml (exemplo conceitual)
services:
  # Monitor para pg_auto_failover
  monitor:
    image: citusdata/pg_auto_failover
    command: pg_autoctl create monitor
    
  # Coordinator Primary
  coordinator-primary:
    image: citusdata/citus:12.1
    command: pg_autoctl create coordinator
    
  # Coordinator Standby  
  coordinator-standby:
    image: citusdata/citus:12.1
    command: pg_autoctl create coordinator --monitor monitor:5432
    
  # Worker Group 1
  worker-1a:
    image: citusdata/citus:12.1
    command: pg_autoctl create worker --group 1
    
  worker-1b:
    image: citusdata/citus:12.1
    command: pg_autoctl create worker --group 1 --monitor monitor:5432
EOF

echo
echo -e "${CYAN}🔗 Recursos Adicionais:${NC}"
echo "• pg_auto_failover docs: https://pg-auto-failover.readthedocs.io/"
echo "• Citus HA Guide: https://docs.citusdata.com/en/stable/admin_guide/high_availability.html"
echo "• Production Checklist: https://docs.citusdata.com/en/stable/admin_guide/cluster_management.html"

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                 🏆 DEMONSTRAÇÃO HA COMPLETA                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}🎯 O que os alunos aprenderam:${NC}"
echo "   ✅ Como diferentes tipos de falha afetam o cluster"
echo "   ✅ Importância do coordinator para disponibilidade"
echo "   ✅ Estratégias de recuperação manual"
echo "   ✅ Necessidade de arquitetura HA em produção"
echo "   ✅ Ferramentas como pg_auto_failover"
echo
echo -e "${PURPLE}📚 Próximo: Explore arquiteturas HA reais em produção!${NC}"
echo -e "${PURPLE}Considere implementar pg_auto_failover em ambiente de teste${NC}"
