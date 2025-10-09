#!/bin/bash

# ██████╗ ███████╗ ██████╗██╗  ██╗███████╗███╗   ███╗ █████╗ 
# ██╔════╝██╔════╝██╔════╝██║  ██║██╔════╝████╗ ████║██╔══██╗
# ███████╗██║     ██║     ███████║█████╗  ██╔████╔██║███████║
# ╚════██║██║     ██║     ██╔══██║██╔══╝  ██║╚██╔╝██║██╔══██║
# ███████║╚██████╗╚██████╗██║  ██║███████╗██║ ╚═╝ ██║██║  ██║
# ╚══════╝ ╚═════╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═╝
#
# 🏗️ SCHEMA MANAGER: Gerenciador Inteligente de Schemas
# Objetivo: Criar tabelas e configurar sharding baseado em arquivos YAML

set -euo pipefail

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
COMPOSE_PROJECT_NAME="citus_cluster_ha"
CONFIG_DIR="config"
SCENARIOS_DIR="$CONFIG_DIR/scenarios"
COORDINATOR_CONTAINER="citus_coordinator_primary"

# Função para logs formatados
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${CYAN}[$timestamp] ℹ️  $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] ✅ $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] ⚠️  $message${NC}" ;;
        "ERROR") echo -e "${RED}[$timestamp] ❌ $message${NC}" ;;
        "DEBUG") echo -e "${PURPLE}[$timestamp] 🔍 $message${NC}" ;;
    esac
}

# Função para verificar dependências
check_dependencies() {
    log "INFO" "Verificando dependências..."
    
    # Verificar se yq está instalado (para parsing YAML)
    if ! command -v yq &> /dev/null; then
        log "WARNING" "yq não encontrado. Tentando instalar..."
        if command -v brew &> /dev/null; then
            brew install yq
        else
            log "ERROR" "Por favor, instale yq: https://github.com/mikefarah/yq"
            log "INFO" "macOS: brew install yq"
            log "INFO" "Linux: wget -qO- https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 > /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
            return 1
        fi
    fi
    
    # Verificar Docker
    if ! docker ps > /dev/null 2>&1; then
        log "ERROR" "Docker não está rodando ou não está acessível"
        return 1
    fi
    
    # Verificar se cluster está rodando
    if ! docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        log "ERROR" "Cluster Citus não está rodando. Execute docker-compose up primeiro"
        return 1
    fi
    
    log "SUCCESS" "Todas as dependências verificadas"
}

# Função para listar cenários disponíveis
list_scenarios() {
    log "INFO" "Cenários disponíveis:"
    echo
    
    for scenario_file in "$SCENARIOS_DIR"/*.yml; do
        if [[ -f "$scenario_file" ]]; then
            local scenario_name=$(basename "$scenario_file" .yml)
            local description=$(yq eval '.scenario.description // "Sem descrição"' "$scenario_file")
            local complexity=$(yq eval '.scenario.complexity // "unknown"' "$scenario_file")
            
            case $complexity in
                "beginner") complexity_icon="🟢" ;;
                "intermediate") complexity_icon="🟡" ;;
                "advanced") complexity_icon="🔴" ;;
                *) complexity_icon="⚪" ;;
            esac
            
            echo -e "  ${complexity_icon} ${BOLD}${scenario_name}${NC}: $description"
        fi
    done
    echo
}

# Função para parsing do arquivo YAML
parse_yaml_config() {
    local config_file="$1"
    
    log "INFO" "Analisando configuração: $config_file"
    
    # Verificar se arquivo existe
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "Arquivo de configuração não encontrado: $config_file"
        return 1
    fi
    
    # Extrair nome do banco
    DB_NAME=$(yq eval '.database.name // "test_db"' "$config_file")
    log "DEBUG" "Database: $DB_NAME"
    
    # Verificar se tem import de tabelas
    local import_file=$(yq eval '.import // ""' "$config_file")
    if [[ -n "$import_file" && "$import_file" != "null" ]]; then
        # Resolver caminho relativo
        import_file="$CONFIG_DIR/$import_file"
        if [[ ! -f "$import_file" ]]; then
            import_file="$CONFIG_DIR/tables.yml"  # Fallback
        fi
        log "DEBUG" "Importando definições de: $import_file"
        TABLES_CONFIG="$import_file"
    else
        TABLES_CONFIG="$config_file"
    fi
}

# Função para criar database
create_database() {
    local db_name="$1"
    
    log "INFO" "Criando database: $db_name"
    
    # Verificar se database já existe
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
        log "WARNING" "Database '$db_name' já existe. Removendo..."
        docker exec "$COORDINATOR_CONTAINER" psql -U postgres -c "DROP DATABASE IF EXISTS $db_name;"
    fi
    
    # Criar database
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -c "CREATE DATABASE $db_name;"
    
    # Criar extensão Citus
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$db_name" -c "CREATE EXTENSION IF NOT EXISTS citus;"
    
    log "SUCCESS" "Database '$db_name' criado com extensão Citus"
}

# Função para criar uma tabela baseada na configuração YAML
create_table() {
    local table_name="$1"
    local config_file="$2"
    
    log "INFO" "Criando tabela: $table_name"
    
    # Extrair configuração da tabela
    local table_type=$(yq eval ".tables.${table_name}.type" "$config_file")
    local description=$(yq eval ".tables.${table_name}.description" "$config_file")
    
    log "DEBUG" "Tipo: $table_type | Descrição: $description"
    
    # Construir DDL
    local ddl="CREATE TABLE $table_name ("
    
    # Adicionar colunas
    local columns_count=$(yq eval ".tables.${table_name}.columns | length" "$config_file")
    for ((i=0; i<columns_count; i++)); do
        local col_name=$(yq eval ".tables.${table_name}.columns[$i].name" "$config_file")
        local col_type=$(yq eval ".tables.${table_name}.columns[$i].type" "$config_file")
        local col_desc=$(yq eval ".tables.${table_name}.columns[$i].description // \"\"" "$config_file")
        
        ddl="$ddl\n    $col_name $col_type"
        [[ $i -lt $((columns_count-1)) ]] && ddl="$ddl,"
        
        log "DEBUG" "  Coluna: $col_name ($col_type)"
    done
    
    # Verificar chave primária personalizada
    local pk=$(yq eval ".tables.${table_name}.primary_key // []" "$config_file")
    if [[ "$pk" != "[]" && "$pk" != "null" ]]; then
        local pk_cols=$(yq eval ".tables.${table_name}.primary_key | join(\", \")" "$config_file")
        ddl="$ddl,\n    PRIMARY KEY ($pk_cols)"
        log "DEBUG" "  Chave primária: $pk_cols"
    fi
    
    ddl="$ddl\n);"
    
    # Executar DDL
    log "DEBUG" "Executando DDL para $table_name"
    echo -e "$ddl" | docker exec -i "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME"
    
    # Configurar distribuição
    configure_table_distribution "$table_name" "$config_file"
    
    # Criar índices
    create_table_indexes "$table_name" "$config_file"
    
    log "SUCCESS" "Tabela '$table_name' criada com sucesso"
}

# Função para configurar distribuição da tabela
configure_table_distribution() {
    local table_name="$1"
    local config_file="$2"
    
    local table_type=$(yq eval ".tables.${table_name}.type" "$config_file")
    
    case $table_type in
        "reference")
            log "INFO" "Configurando '$table_name' como tabela de referência"
            docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                -c "SELECT create_reference_table('$table_name');"
            ;;
            
        "distributed")
            local shard_key=$(yq eval ".tables.${table_name}.shard_key" "$config_file")
            local shard_count=$(yq eval ".tables.${table_name}.shard_count // 4" "$config_file")
            
            # Verificar co-localização antes de criar
            local colocated_with=$(yq eval ".tables.${table_name}.colocated_with // \"\"" "$config_file")
            
            if [[ -n "$colocated_with" && "$colocated_with" != "null" ]]; then
                log "INFO" "Configurando '$table_name' como tabela distribuída co-localizada com '$colocated_with'"
                docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                    -c "SELECT create_distributed_table('$table_name', '$shard_key', colocate_with => '$colocated_with');"
            else
                log "INFO" "Configurando '$table_name' como tabela distribuída (shard_key: $shard_key, shards: $shard_count)"
                docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                    -c "SELECT create_distributed_table('$table_name', '$shard_key', shard_count => $shard_count);"
            fi
            ;;
            
        "local")
            log "INFO" "Mantendo '$table_name' como tabela local (não distribuída)"
            ;;
            
        *)
            log "WARNING" "Tipo de tabela desconhecido: $table_type. Mantendo como local"
            ;;
    esac
}

# Função para criar índices
create_table_indexes() {
    local table_name="$1"
    local config_file="$2"
    
    local indexes_count=$(yq eval ".tables.${table_name}.indexes | length" "$config_file" 2>/dev/null || echo "0")
    
    if [[ "$indexes_count" -gt 0 ]]; then
        log "INFO" "Criando índices para '$table_name'"
        
        for ((i=0; i<indexes_count; i++)); do
            local idx_name=$(yq eval ".tables.${table_name}.indexes[$i].name" "$config_file")
            local idx_columns=$(yq eval ".tables.${table_name}.indexes[$i].columns | join(\", \")" "$config_file")
            
            log "DEBUG" "  Índice: $idx_name ($idx_columns)"
            
            docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                -c "CREATE INDEX IF NOT EXISTS $idx_name ON $table_name ($idx_columns);"
        done
    fi
}

# Função principal para criar schema completo
create_schema() {
    local scenario="$1"
    local config_file="$SCENARIOS_DIR/${scenario}.yml"
    
    log "INFO" "🚀 Iniciando criação de schema para cenário: $scenario"
    
    # Verificar dependências
    check_dependencies || return 1
    
    # Parse da configuração
    parse_yaml_config "$config_file" || return 1
    
    # Criar database
    create_database "$DB_NAME"
    
    # Obter lista de tabelas na ordem correta
    local tables=$(yq eval '.tables | keys | .[]' "$TABLES_CONFIG")
    
    log "INFO" "Tabelas a serem criadas: $(echo $tables | tr '\n' ' ')"
    
    # Criar tabelas em ordem (referência primeiro, depois distribuídas)
    echo "$tables" | while read -r table; do
        [[ -n "$table" && "$table" != "null" ]] && create_table "$table" "$TABLES_CONFIG"
    done
    
    # Mostrar resumo final
    show_schema_summary
    
    log "SUCCESS" "🎉 Schema criado com sucesso!"
}

# Função para mostrar resumo do schema
show_schema_summary() {
    log "INFO" "📊 Resumo do Schema"
    
    echo -e "\n${CYAN}Tabelas criadas:${NC}"
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        schemaname,
        tablename,
        CASE 
            WHEN tablename IN (SELECT logicalrelid::regclass::text FROM pg_dist_partition) 
            THEN 'Distribuída'
            WHEN tablename IN (SELECT logicalrelid::regclass::text FROM pg_dist_partition WHERE partmethod = 'n')
            THEN 'Referência'  
            ELSE 'Local'
        END as tipo
    FROM pg_tables 
    WHERE schemaname = 'public'
    ORDER BY tablename;
    "
    
    echo -e "\n${CYAN}Distribuição de shards:${NC}"
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        p.logicalrelid::regclass as tabela,
        COUNT(s.shardid) as shards,
        CASE 
            WHEN p.partkey IS NULL THEN 'N/A (tabela de referência)'
            ELSE 'company_id'  -- Assumindo que todas usam company_id como shard key
        END as shard_key
    FROM pg_dist_shard s
    JOIN pg_dist_partition p ON s.logicalrelid = p.logicalrelid
    GROUP BY p.logicalrelid, p.partkey
    ORDER BY p.logicalrelid;
    " 2>/dev/null || log "DEBUG" "Nenhuma tabela distribuída encontrada"
}

# Função para modo interativo
interactive_mode() {
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║              🏗️  SCHEMA MANAGER INTERATIVO            ║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════╝${NC}"
    echo
    
    list_scenarios
    
    echo -n -e "${CYAN}Escolha um cenário para criar: ${NC}"
    read -r scenario
    
    if [[ -f "$SCENARIOS_DIR/${scenario}.yml" ]]; then
        create_schema "$scenario"
    else
        log "ERROR" "Cenário '$scenario' não encontrado"
        return 1
    fi
}

# Função principal
main() {
    case "${1:-}" in
        "list"|"ls")
            list_scenarios
            ;;
        "create")
            if [[ -n "${2:-}" ]]; then
                create_schema "$2"
            else
                log "ERROR" "Uso: $0 create <cenario>"
                list_scenarios
                return 1
            fi
            ;;
        "interactive"|"")
            interactive_mode
            ;;
        "help"|"-h"|"--help")
            echo -e "${BOLD}Schema Manager - Gerenciador de Schemas Citus${NC}"
            echo
            echo "Uso:"
            echo "  $0 [comando] [opções]"
            echo
            echo "Comandos:"
            echo "  list, ls              Lista cenários disponíveis"
            echo "  create <cenario>      Cria schema para o cenário especificado"
            echo "  interactive           Modo interativo (padrão)"
            echo "  help                  Mostra esta ajuda"
            echo
            echo "Exemplos:"
            echo "  $0 list"
            echo "  $0 create adtech"
            echo "  $0 interactive"
            ;;
        *)
            log "ERROR" "Comando desconhecido: $1"
            echo "Use '$0 help' para ver comandos disponíveis"
            return 1
            ;;
    esac
}

# Executar função principal com argumentos
main "$@"
