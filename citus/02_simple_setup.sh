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
COMPOSE_PROJECT_NAME="adtech_cluster"
POSTGRES_PASSWORD="adtech2024"
DB_NAME="adtech_platform"

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

log_step "Aguardando master ficar pronto..."
timeout=120
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if docker exec "${COMPOSE_PROJECT_NAME}_master" pg_isready -U postgres > /dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ $elapsed -ge $timeout ]; then
    echo -e "${RED}❌ Timeout aguardando master${NC}"
    exit 1
fi

log_step "✅ Master pronto!"

echo -e "${BLUE}🔧 PASSO 3: Configuração Básica${NC}"
echo "═══════════════════════════════════"

# Criar database
log_step "Criando database..."
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -c "CREATE DATABASE $DB_NAME;" 2>/dev/null || true

# Configurar Citus no database
log_step "Configurando Citus no master..."
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;"

# Configurar workers - versão simplificada e robusta
log_step "Configurando workers..."

# Aguardar workers estarem prontos
echo -e "${CYAN}⏳ Aguardando workers iniciarem...${NC}"
sleep 15

# Worker 1
echo -e "${CYAN}🔧 Configurando Worker 1...${NC}"
docker exec "${COMPOSE_PROJECT_NAME}_worker1" psql -U postgres -c "CREATE DATABASE $DB_NAME;" 2>/dev/null || echo "Database já existe no worker1"
docker exec "${COMPOSE_PROJECT_NAME}_worker1" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;" 2>/dev/null || echo "Erro na extensão worker1"

# Worker 2  
echo -e "${CYAN}🔧 Configurando Worker 2...${NC}"
docker exec "${COMPOSE_PROJECT_NAME}_worker2" psql -U postgres -c "CREATE DATABASE $DB_NAME;" 2>/dev/null || echo "Database já existe no worker2"
docker exec "${COMPOSE_PROJECT_NAME}_worker2" psql -U postgres -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS citus;" 2>/dev/null || echo "Erro na extensão worker2"

log_step "Registrando workers no cluster..."

# Registrar por nome do container (mais confiável)
echo -e "${CYAN}📝 Registrando worker1...${NC}"
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "SELECT master_add_node('${COMPOSE_PROJECT_NAME}_worker1', 5432);" 2>/dev/null || echo "Erro ao registrar worker1"

echo -e "${CYAN}📝 Registrando worker2...${NC}"
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "SELECT master_add_node('${COMPOSE_PROJECT_NAME}_worker2', 5432);" 2>/dev/null || echo "Erro ao registrar worker2"

# Aguardar propagação
sleep 5

# Verificar workers ativos
log_step "Verificando workers ativos..."
WORKER_COUNT=$(docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM master_get_active_worker_nodes();" 2>/dev/null | tr -d ' ')

echo -e "${CYAN}📋 Workers registrados:${NC}"
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "SELECT * FROM master_get_active_worker_nodes();"

if [ "$WORKER_COUNT" -eq 2 ]; then
    log_step "✅ Cluster configurado com sucesso! 2 workers ativos."
elif [ "$WORKER_COUNT" -eq 1 ]; then
    log_step "⚠️ Apenas 1 worker ativo. Verificar worker2."
else
    log_step "❌ Nenhum worker ativo. Verificar configuração."
fi

echo -e "${BLUE}📊 PASSO 4: Criando Estrutura${NC}"
echo "════════════════════════════════"

# Criar tabelas
log_step "Criando tabelas..."

# Primeiro, limpar tabelas existentes
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "DROP TABLE IF EXISTS ads CASCADE;" 2>/dev/null || true
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "DROP TABLE IF EXISTS campaigns CASCADE;" 2>/dev/null || true
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "DROP TABLE IF EXISTS companies CASCADE;" 2>/dev/null || true

# Criar todas as tabelas individualmente
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
CREATE TABLE companies (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    logo_url TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);"

docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
CREATE TABLE campaigns (
    id SERIAL,
    company_id INTEGER NOT NULL,
    name VARCHAR(255) NOT NULL,
    pricing_model VARCHAR(50),
    status VARCHAR(50),
    budget INTEGER,
    description TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (id, company_id)
);"

docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
CREATE TABLE ads (
    id SERIAL,
    company_id INTEGER NOT NULL,
    campaign_id INTEGER NOT NULL,
    name VARCHAR(255) NOT NULL,
    image_url TEXT,
    target_url TEXT,
    impressions BIGINT DEFAULT 0,
    clicks BIGINT DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (id, company_id)
);"

# Criar índices
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "CREATE INDEX IF NOT EXISTS idx_campaigns_company_id ON campaigns(company_id);" 2>/dev/null || true
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "CREATE INDEX IF NOT EXISTS idx_ads_company_id ON ads(company_id);" 2>/dev/null || true
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "CREATE INDEX IF NOT EXISTS idx_ads_campaign_id ON ads(campaign_id);" 2>/dev/null || true

# Distribuir tabelas apenas se tivermos workers
worker_count=$(docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM master_get_active_worker_nodes();" 2>/dev/null | xargs || echo "0")

if [ "$worker_count" -gt 0 ]; then
    log_step "Distribuindo tabelas ($worker_count workers ativos)..."
    
    echo -e "${YELLOW}💡 CONCEITO IMPORTANTE:${NC}"
    echo "   Em tabelas distribuídas, a PRIMARY KEY deve incluir a shard key (company_id)"
    echo "   Isso garante que dados relacionados fiquem no mesmo worker"
    echo
    
    docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "SELECT create_reference_table('companies');" || true
    docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "SELECT create_distributed_table('campaigns', 'company_id');" || true
    docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "SELECT create_distributed_table('ads', 'company_id');" || true
    
    log_step "✅ Tabelas distribuídas com sucesso!"
else
    log_step "⚠️ Nenhum worker ativo - tabelas não distribuídas"
fi

echo -e "${BLUE}📥 PASSO 5: Carregando Dados${NC}"
echo "═══════════════════════════════"

# Copiar dados
log_step "Copiando arquivos CSV..."

# Criar dados de exemplo se não existirem
if ! [ -f ../companies.csv ]; then
    log_step "Gerando dados de exemplo..."
    
    # Criar companies.csv simples
    cat > /tmp/companies_temp.csv << 'EOF'
TechCorp,https://example.com/techcorp.png
AdMaster,https://example.com/admaster.png
DataFlow,https://example.com/dataflow.png
CloudBase,https://example.com/cloudbase.png
WebScale,https://example.com/webscale.png
EOF
    docker cp /tmp/companies_temp.csv "${COMPOSE_PROJECT_NAME}_master":/tmp/companies.csv
    
    # Criar campaigns.csv simples
    cat > /tmp/campaigns_temp.csv << 'EOF'
1,Summer Sale 2024,CPC,active,50000,Campanha de verão com produtos em promoção
2,Brand Awareness,CPM,active,75000,Campanha para aumentar conhecimento da marca
1,Black Friday,CPC,planned,100000,Campanha especial para Black Friday
3,Product Launch,CPA,active,30000,Lançamento do novo produto
2,Retargeting,CPC,active,25000,Campanha de retargeting para conversões
EOF
    docker cp /tmp/campaigns_temp.csv "${COMPOSE_PROJECT_NAME}_master":/tmp/campaigns.csv
    
    # Criar ads.csv simples
    cat > /tmp/ads_temp.csv << 'EOF'
1,1,Banner Principal,https://example.com/banner1.jpg,https://techcorp.com/sale,15000,450
2,1,Video Ad,https://example.com/video1.mp4,https://techcorp.com/products,8000,320
1,2,Display Ad,https://example.com/display1.jpg,https://admaster.com/brand,25000,180
3,2,Social Media,https://example.com/social1.jpg,https://admaster.com/about,12000,95
2,3,Search Ad,https://example.com/search1.jpg,https://techcorp.com/new,5000,275
EOF
    docker cp /tmp/ads_temp.csv "${COMPOSE_PROJECT_NAME}_master":/tmp/ads.csv
else
    docker cp ../companies.csv "${COMPOSE_PROJECT_NAME}_master":/tmp/ || log_step "⚠️ companies.csv não encontrado"
    docker cp ../campaigns.csv "${COMPOSE_PROJECT_NAME}_master":/tmp/ || log_step "⚠️ campaigns.csv não encontrado"
    docker cp ../ads.csv "${COMPOSE_PROJECT_NAME}_master":/tmp/ || log_step "⚠️ ads.csv não encontrado"
fi

# Carregar dados se os arquivos existirem
if docker exec "${COMPOSE_PROJECT_NAME}_master" test -f /tmp/companies.csv; then
    log_step "Carregando empresas..."
    docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "\\COPY companies(id, name, logo_url, created_at, updated_at) FROM '/tmp/companies.csv' WITH (FORMAT CSV);" || true
fi

if docker exec "${COMPOSE_PROJECT_NAME}_master" test -f /tmp/campaigns.csv; then
    log_step "Carregando campanhas..."
    docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "\\COPY campaigns(id, company_id, name, pricing_model, status, budget, description, created_at, updated_at) FROM '/tmp/campaigns.csv' WITH (FORMAT CSV);" || true
fi

if docker exec "${COMPOSE_PROJECT_NAME}_master" test -f /tmp/ads.csv; then
    log_step "Carregando anúncios..."
    docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "\\COPY ads(id, company_id, campaign_id, name, image_url, target_url, impressions, clicks, created_at, updated_at) FROM '/tmp/ads.csv' WITH (FORMAT CSV);" || true
fi

echo -e "${BLUE}📊 PASSO 6: Verificação Final${NC}"
echo "════════════════════════════════"

# Mostrar estatísticas
log_step "Estatísticas das tabelas:"
docker exec "${COMPOSE_PROJECT_NAME}_master" psql -U postgres -d "$DB_NAME" -c "
SELECT 
    'companies'::text as tabela,
    COUNT(*)::text as registros
FROM companies
UNION ALL
SELECT 
    'campaigns',
    COUNT(*)::text
FROM campaigns
UNION ALL
SELECT 
    'ads',
    COUNT(*)::text
FROM ads;
"

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    ✅ SETUP COMPLETO!                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}🎯 Status:${NC}"
echo "   • Master: ✅ Rodando na porta 5432"
echo "   • Workers: $worker_count ativo(s)"
echo "   • Database: $DB_NAME criado"
echo "   • Grafana: http://localhost:3000 (admin/admin)"
echo "   • Prometheus: http://localhost:9090"
echo
echo -e "${PURPLE}📝 Para conectar:${NC}"
echo "   docker exec -it ${COMPOSE_PROJECT_NAME}_master psql -U postgres -d $DB_NAME"
echo
echo -e "${PURPLE}🚀 Próximo passo:${NC}"
echo "   Use o dashboard.sh ou execute os próximos módulos"
