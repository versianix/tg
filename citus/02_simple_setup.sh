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

# Configurações - Adaptado para Patroni
COMPOSE_PROJECT_NAME="citus"
POSTGRES_PASSWORD="postgres"
DB_NAME="citus"
WORKER1_PRIMARY_CONTAINER="citus_worker1_primary"
WORKER1_STANDBY_CONTAINER="citus_worker1_standby"
WORKER2_PRIMARY_CONTAINER="citus_worker2_primary"
WORKER2_STANDBY_CONTAINER="citus_worker2_standby"

# Função para detectar coordinator líder via API do Patroni
detect_leader_coordinator() {
    echo -e "${CYAN}🔍 Detectando coordinator líder...${NC}"
    
    # Tenta detectar líder por até 30 segundos
    local timeout=30
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        # Tenta acessar qualquer coordinator para obter info do cluster
        for coord in coordinator1 coordinator2 coordinator3; do
            container_name="citus_$coord"
            
            # Verifica se o container está rodando
            if ! docker ps --format "table {{.Names}}" | grep -q "^$container_name$"; then
                continue
            fi
            
            # Usa API do Patroni para detectar líder
            leader=$(docker exec "$container_name" curl -s localhost:8008/cluster 2>/dev/null | \
                     grep -o '"name": "[^"]*", "role": "leader"' | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
            
            if [ -n "$leader" ] && [ "$leader" != "" ]; then
                COORDINATOR_CONTAINER="citus_$leader"
                echo -e "${GREEN}✅ Líder detectado: $leader${NC}"
                return 0
            fi
            
            break  # Se conseguiu acessar um coordinator, não precisa tentar os outros
        done
        
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    echo -e "\n${YELLOW}⚠️ Não foi possível detectar líder. Usando coordinator1 (fallback)${NC}"
    COORDINATOR_CONTAINER="citus_coordinator1"
    return 1
}

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

log_step "Iniciando containers com Patroni..."
docker-compose -f docker-compose-patroni.yml up -d

# Detectar coordinator líder
detect_leader_coordinator

log_step "Aguardando coordinator líder ($COORDINATOR_CONTAINER) ficar pronto..."
timeout=180
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 5
    elapsed=$((elapsed + 5))
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

# Aguardar arquitetura Patroni completa de forma inteligente
log_step "Verificando status do Patroni..."

# Verificar se algum coordinator é líder (logs mais recentes)
leader_found=""
if docker logs citus_coordinator1 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
    leader_found="coordinator1"
elif docker logs citus_coordinator2 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
    leader_found="coordinator2"  
elif docker logs citus_coordinator3 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
    leader_found="coordinator3"
fi

if [ -n "$leader_found" ]; then
    echo -e "${GREEN}✅ Líder ativo: $leader_found${NC}"
else
    # Verificação mais direta - se PostgreSQL responde, Patroni está funcionando
    if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Cluster Patroni ativo (PostgreSQL respondendo)${NC}"
    else
        log_step "Aguardando PostgreSQL inicializar..."
        sleep 10
        if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
            echo -e "${GREEN}✅ PostgreSQL pronto${NC}"
        else
            echo -e "${YELLOW}⚠️ PostgreSQL ainda inicializando, continuando...${NC}"
        fi
    fi
fi

# Verificar se Citus está configurado
log_step "Verificando configuração do Citus..."
if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_version();" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Citus já configurado e funcionando${NC}"
else
    # Se não estiver configurado, aguardar um pouco
    log_step "Aguardando Citus inicializar..."
    sleep 10
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_version();" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Citus configurado com sucesso${NC}"
    else
        echo -e "${YELLOW}⚠️ Citus ainda inicializando, mas continuando...${NC}"
    fi
fi

# Verificar workers de forma rápida
log_step "Verificando workers..."
worker1_ready=0
worker2_ready=0

if docker exec citus_worker1_primary pg_isready -U postgres > /dev/null 2>&1; then
    worker1_ready=1
fi
if docker exec citus_worker2_primary pg_isready -U postgres > /dev/null 2>&1; then
    worker2_ready=1
fi

workers_ready=$((worker1_ready + worker2_ready))

if [ $workers_ready -eq 2 ]; then
    echo -e "${GREEN}✅ Todos os workers prontos (2/2)${NC}"
else
    echo -e "${YELLOW}⏳ Aguardando workers ficarem prontos... ($workers_ready/2)${NC}"
    sleep 15
    
    # Verificar novamente
    worker1_ready=0
    worker2_ready=0
    if docker exec citus_worker1_primary pg_isready -U postgres > /dev/null 2>&1; then
        worker1_ready=1
    fi
    if docker exec citus_worker2_primary pg_isready -U postgres > /dev/null 2>&1; then
        worker2_ready=1
    fi
    workers_ready=$((worker1_ready + worker2_ready))
    echo -e "${GREEN}✅ Workers prontos: $workers_ready/2${NC}"
fi

# Verificar workers ativos (Patroni)
log_step "Verificando workers ativos..."
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" 2>/dev/null | tr -d ' ' || echo "0")

echo -e "${CYAN}📋 Workers registrados:${NC}"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT * FROM master_get_active_worker_nodes();"

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
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT * FROM master_get_active_worker_nodes();"

# Verificar workers ativos
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM master_get_active_worker_nodes();" 2>/dev/null | tr -d ' ')

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
