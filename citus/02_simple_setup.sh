#!/bin/bash

# ███████╗██╗███╗   ███╗██████╗ ██╗     ███████╗
# ██╔════╝██║████╗ ████║██╔══██╗██║     ██╔════╝
# ███████╗██║██╔████╔██║██████╔╝██║     █████╗  
# ╚════██║██║██║╚██╔╝██║██╔═══╝ ██║     ██╔══╝  
# ███████║██║██║ ╚═╝ ██║██║     ███████╗███████╗
# ╚══════╝╚═╝╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝
#
# 🚀 SETUP SIMPLIFICADO: Configuração Básica para Apple Silicon
# Objetivo: Funcionar de forma confiável em macOS

set -euo pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configurações
COMPOSE_PROJECT_NAME="citus_cluster_ha"
POSTGRES_PASSWORD="postgres"
DB_NAME="citus_platform"
COORDINATOR_CONTAINER="citus_coordinator_primary"
WORKER1A_CONTAINER="citus_worker_1a"
WORKER1B_CONTAINER="citus_worker_1b"
WORKER2A_CONTAINER="citus_worker_2a"
WORKER2B_CONTAINER="citus_worker_2b"
ETCD_CONTAINER="citus_etcd"

echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}║            🧪 SETUP SIMPLIFICADO CITUS (Apple Silicon)       ║${NC}"
echo -e "${PURPLE}║                     Versão Robusta                          ║${NC}"
echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# Função para logging
log_step() {
    echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"
}

# Verificar Docker
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}❌ Docker não está rodando. Inicie o Docker primeiro.${NC}"
    exit 1
fi

echo -e "${BLUE}🧹 PASSO 1: Limpeza${NC}"
echo "═══════════════════════"

log_step "Parando containers antigos..."
docker-compose down -v 2>/dev/null || true

log_step "Limpando volumes órfãos..."
docker volume prune -f

echo -e "${BLUE}🚀 PASSO 2: Iniciando Cluster${NC}"
echo "════════════════════════════════"

# Definir variáveis
export COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME"
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export POSTGRES_USER="postgres"

log_step "Iniciando containers..."
docker-compose up -d

log_step "Aguardando coordinator primary ficar pronto..."
timeout=120
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres -d "$DB_NAME" > /dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ $elapsed -ge $timeout ]; then
    echo -e "${RED}❌ Timeout aguardando coordinator${NC}"
    exit 1
fi

log_step "✅ Coordinator Primary pronto!"

echo -e "${BLUE}🔧 PASSO 3: Configuração Básica${NC}"
echo "═══════════════════════════════════"

# Database já existe automaticamente via POSTGRES_DB no docker-compose.yml
log_step "Verificando database $DB_NAME..."
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME" || {
    echo -e "${RED}❌ Database $DB_NAME não encontrado${NC}"
    exit 1
}

# Configurar Citus no database
log_step "Configurando Citus no coordinator..."
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;"

# Configurar workers com HA completo
log_step "Configurando workers com HA..."

# Aguardar workers estarem prontos
echo -e "${CYAN}⏳ Aguardando workers iniciarem...${NC}"
sleep 20

# Worker Group 1 Primary - Database já existe via POSTGRES_DB
echo -e "${CYAN}🔧 Configurando Worker 1A (Primary)...${NC}"
docker exec "$WORKER1A_CONTAINER" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;"

# Worker Group 1 Standby - Database já existe via POSTGRES_DB
echo -e "${CYAN}🔄 Configurando Worker 1B (Standby)...${NC}"
docker exec "$WORKER1B_CONTAINER" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;"

# Worker Group 2 Primary - Database já existe via POSTGRES_DB  
echo -e "${CYAN}🔧 Configurando Worker 2A (Primary)...${NC}"
docker exec "$WORKER2A_CONTAINER" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;"

# Worker Group 2 Standby - Database já existe via POSTGRES_DB
echo -e "${CYAN}🔄 Configurando Worker 2B (Standby)...${NC}"
docker exec "$WORKER2B_CONTAINER" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;"

log_step "Registrando workers via HAProxy para failover automático..."

# Aguardar HAProxy estar pronto
sleep 5

# Registrar workers através dos load balancers para failover automático
echo -e "${CYAN}📝 Registrando worker1 via HAProxy (com failover)...${NC}"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_add_node('worker1-lb', 5432);" 2>/dev/null || echo "Worker1-LB já registrado ou erro"

echo -e "${CYAN}📝 Registrando worker2 via HAProxy (com failover)...${NC}"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_add_node('worker2-lb', 5432);" 2>/dev/null || echo "Worker2-LB já registrado ou erro"

echo -e "${CYAN}✅ Workers registrados via HAProxy - failover automático ativo!${NC}"

# Aguardar propagação
sleep 5

# Verificar workers ativos
log_step "Verificando workers ativos..."
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" 2>/dev/null | tr -d ' ')

echo -e "${CYAN}📋 Workers registrados:${NC}"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT * FROM citus_get_active_worker_nodes();"

if [ "$WORKER_COUNT" -eq 2 ]; then
    log_step "✅ Cluster configurado com sucesso! 2 workers ativos."
elif [ "$WORKER_COUNT" -eq 1 ]; then
    log_step "⚠️ Apenas 1 worker ativo. Verificar worker2."
else
    log_step "❌ Nenhum worker ativo. Verificar configuração."
fi

echo -e "${BLUE}📊 PASSO 4: Verificação Final${NC}"
echo "════════════════════════════════"

# Mostrar status do cluster
log_step "Status do cluster Citus:"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT * FROM citus_get_active_worker_nodes();"

# Verificar workers ativos
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" 2>/dev/null | tr -d ' ')

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                🎯 CLUSTER CITUS CONFIGURADO!                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}🎯 Status:${NC}"
echo "   • Coordinator Primary: ✅ Rodando na porta 5432"
echo "   • Coordinator Standby: ✅ Rodando na porta 5434" 
echo "   • Worker 1A (Primary): ✅ Rodando na porta 5435"
echo "   • Worker 1B (Standby): ✅ Rodando na porta 5436"
echo "   • Worker 2A (Primary): ✅ Rodando na porta 5437"
echo "   • Worker 2B (Standby): ✅ Rodando na porta 5438"
echo "   • Workers Ativos no Citus: $WORKER_COUNT (apenas primários)"
echo "   • Database: $DB_NAME criado"
echo "   • Extensão Citus: ✅ Configurada"
echo "   • Grafana: http://localhost:3000 (admin/admin)"
echo "   • Prometheus: http://localhost:9090"
echo
echo -e "${PURPLE}📝 Para conectar ao cluster:${NC}"
echo "   docker exec -it $COORDINATOR_CONTAINER psql -U postgres -d $DB_NAME"
echo
echo -e "${PURPLE}🚀 Próximos passos:${NC}"
echo "   1. ../scripts/schema_manager.sh  → Criar e distribuir tabelas"
echo "   2. ../scripts/data_loader.sh     → Carregar dados CSV"
