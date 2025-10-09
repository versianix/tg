#!/bin/bash

# ██████╗  █████╗ ████████╗ █████╗     ██╗      ██████╗  █████╗ ██████╗ ███████╗██████╗ 
# ██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗    ██║     ██╔═══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗
# ██║  ██║███████║   ██║   ███████║    ██║     ██║   ██║███████║██║  ██║█████╗  ██████╔╝
# ██║  ██║██╔══██║   ██║   ██╔══██║    ██║     ██║   ██║██╔══██║██║  ██║██╔══╝  ██╔══██╗
# ██████╔╝██║  ██║   ██║   ██║  ██║    ███████╗╚██████╔╝██║  ██║██████╔╝███████╗██║  ██║
# ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝    ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝
#
# 📊 DATA LOADER: Carregador de CSVs fornecidos pelo usuário
# Objetivo: Carregar dados de arquivos CSV nas tabelas distribuídas

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
DATA_DIR="$CONFIG_DIR/data"
CSV_DIR="$CONFIG_DIR/csv"
SCENARIOS_DIR="$CONFIG_DIR/scenarios"
COORDINATOR_CONTAINER="citus_coordinator_primary"

# Função para logs formatados
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${CYAN}[$timestamp] 📊 $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] ✅ $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] ⚠️  $message${NC}" ;;
        "ERROR") echo -e "${RED}[$timestamp] ❌ $message${NC}" ;;
    esac
}

# Função para verificar dependências
check_dependencies() {
    log "INFO" "Verificando dependências..."
    
    if ! command -v yq &> /dev/null; then
        log "ERROR" "yq não encontrado. Instale com: brew install yq"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        log "ERROR" "Docker não encontrado"
        exit 1
    fi
    
    if ! docker compose ps &> /dev/null; then
        log "ERROR" "Docker Compose não disponível ou cluster não está rodando"
        exit 1
    fi
    
    log "SUCCESS" "Dependências verificadas"
}

# Função para verificar se cluster está rodando
check_cluster() {
    log "INFO" "Verificando se cluster Citus está rodando..."
    
    if ! docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d citus_platform -c "SELECT 1;" &> /dev/null; then
        log "ERROR" "Cluster Citus HA não está acessível"
        exit 1
    fi
    
    log "SUCCESS" "Cluster Citus está rodando"
}

# Função para listar tabelas disponíveis
list_tables() {
    log "INFO" "Tabelas disponíveis no tables.yml:"
    echo
    
    yq eval '.tables | keys' config/tables.yml | while read -r table; do
        if [[ "$table" != "null" && "$table" != "---" ]]; then
            local table_name=$(echo "$table" | sed 's/^- //')
            local table_type=$(yq eval ".tables.\"$table_name\".type" config/tables.yml)
            local shard_column=$(yq eval ".tables.\"$table_name\".distribution.column" config/tables.yml)
            
            echo -e "  ${BOLD}$table_name${NC} (${table_type})"
            if [[ "$shard_column" != "null" ]]; then
                echo -e "    └─ Sharding: $shard_column"
            fi
        fi
    done
    echo
}

# Função para verificar se CSV existe para uma tabela
check_csv_exists() {
    local table_name="$1"
    local csv_file="$CSV_DIR/${table_name}.csv"
    
    if [[ -f "$csv_file" ]]; then
        return 0
    else
        return 1
    fi
}

# Função para validar estrutura do CSV
validate_csv_structure() {
    local table_name="$1"
    local csv_file="$CSV_DIR/${table_name}.csv"
    
    log "INFO" "Validando estrutura do CSV para tabela '$table_name'..."
    
    if [[ ! -f "$csv_file" ]]; then
        log "ERROR" "Arquivo CSV não encontrado: $csv_file"
        return 1
    fi
    
    # Verifica se arquivo não está vazio
    if [[ ! -s "$csv_file" ]]; then
        log "ERROR" "Arquivo CSV está vazio: $csv_file"
        return 1
    fi
    
    # Lê o cabeçalho do CSV
    local csv_header=$(head -n 1 "$csv_file")
    log "INFO" "Cabeçalho encontrado: $csv_header"
    
    # Obtém colunas esperadas da configuração
    local expected_columns=$(yq eval ".tables.\"$table_name\".columns | keys | join(\", \")" config/tables.yml)
    log "INFO" "Colunas esperadas: $expected_columns"
    
    # Conta linhas de dados (excluindo cabeçalho)
    local data_lines=$(tail -n +2 "$csv_file" | wc -l | xargs)
    log "INFO" "Linhas de dados encontradas: $data_lines"
    
    return 0
}

# Função para carregar dados de uma tabela
load_table_data() {
    local table_name="$1"
    local csv_file="$CSV_DIR/${table_name}.csv"
    
    log "INFO" "Carregando dados da tabela '$table_name'..."
    
    # Valida estrutura do CSV
    if ! validate_csv_structure "$table_name"; then
        return 1
    fi
    
    # Copia o arquivo CSV para dentro do container
    docker cp "$csv_file" "$COORDINATOR_CONTAINER:/tmp/${table_name}.csv"
    
    # Executa COPY para carregar os dados
    local copy_command="\\COPY $table_name FROM '/tmp/${table_name}.csv' WITH (FORMAT csv, HEADER true);"
    
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d citus_platform -c "$copy_command"; then
        log "SUCCESS" "Dados carregados com sucesso para tabela '$table_name'"
        
        # Mostra estatísticas
        local count=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d citus_platform -t -c "SELECT COUNT(*) FROM $table_name;" | xargs)
        log "INFO" "Total de registros na tabela '$table_name': $count"
        
        # Remove arquivo temporário
        docker exec "$COORDINATOR_CONTAINER" rm -f "/tmp/${table_name}.csv"
        
        return 0
    else
        log "ERROR" "Falha ao carregar dados para tabela '$table_name'"
        return 1
    fi
}

# Função para carregar dados de todas as tabelas
load_all_data() {
    log "INFO" "Iniciando carregamento de dados de todas as tabelas..."
    echo
    
    # Verifica se diretório CSV existe
    if [[ ! -d "$CSV_DIR" ]]; then
        log "ERROR" "Diretório de CSVs não encontrado: $CSV_DIR"
        log "INFO" "Crie o diretório e adicione seus arquivos CSV:"
        log "INFO" "  mkdir -p $CSV_DIR"
        log "INFO" "  # Adicione seus arquivos: companies.csv, campaigns.csv, etc."
        return 1
    fi
    
    local success_count=0
    local error_count=0
    
    # Obtém lista de tabelas do config
    yq eval '.tables | keys' config/tables.yml | while read -r table; do
        if [[ "$table" != "null" && "$table" != "---" ]]; then
            local table_name=$(echo "$table" | sed 's/^- //')
            
            if check_csv_exists "$table_name"; then
                if load_table_data "$table_name"; then
                    ((success_count++))
                else
                    ((error_count++))
                fi
            else
                log "WARNING" "CSV não encontrado para tabela '$table_name' (esperado: $CSV_DIR/${table_name}.csv)"
                ((error_count++))
            fi
            echo
        fi
    done
    
    log "INFO" "Carregamento concluído: $success_count sucessos, $error_count erros"
}

# Função para listar arquivos CSV disponíveis
list_csv_files() {
    log "INFO" "Arquivos CSV disponíveis:"
    echo
    
    if [[ ! -d "$CSV_DIR" ]]; then
        log "WARNING" "Diretório $CSV_DIR não existe"
        log "INFO" "Para usar esta funcionalidade:"
        log "INFO" "  1. Crie o diretório: mkdir -p $CSV_DIR"
        log "INFO" "  2. Adicione seus arquivos CSV com nomes correspondentes às tabelas"
        log "INFO" "  3. Exemplo: companies.csv, campaigns.csv, ads.csv"
        return
    fi
    
    local csv_count=0
    
    for csv_file in "$CSV_DIR"/*.csv; do
        if [[ -f "$csv_file" ]]; then
            local filename=$(basename "$csv_file")
            local table_name="${filename%.csv}"
            local file_size=$(ls -lh "$csv_file" | awk '{print $5}')
            local line_count=$(wc -l < "$csv_file")
            
            echo -e "  ${BOLD}$filename${NC}"
            echo -e "    └─ Tabela: $table_name"
            echo -e "    └─ Tamanho: $file_size"
            echo -e "    └─ Linhas: $line_count"
            echo
            
            ((csv_count++))
        fi
    done
    
    if [[ $csv_count -eq 0 ]]; then
        log "WARNING" "Nenhum arquivo CSV encontrado em $CSV_DIR"
        log "INFO" "Adicione seus arquivos CSV neste diretório para usar o carregamento de dados"
    else
        log "INFO" "Total de arquivos CSV encontrados: $csv_count"
    fi
}

# Função para criar diretório CSV de exemplo
create_csv_template() {
    log "INFO" "Criando estrutura de diretório e templates de exemplo..."
    
    # Cria diretório
    mkdir -p "$CSV_DIR"
    
    # Cria arquivo README com instruções
    cat > "$CSV_DIR/README.md" << 'EOF'
# Diretório de Arquivos CSV

Este diretório contém os arquivos CSV que serão carregados nas tabelas do Citus.

## Estrutura

Cada arquivo CSV deve ter o mesmo nome da tabela correspondente:
- `companies.csv` → tabela `companies`
- `campaigns.csv` → tabela `campaigns`
- `ads.csv` → tabela `ads`

## Formato

Os arquivos devem ter:
1. **Cabeçalho**: Primeira linha com nomes das colunas
2. **Dados**: Linhas subsequentes com dados separados por vírgula
3. **Encoding**: UTF-8
4. **Separador**: Vírgula (,)

## Exemplo de companies.csv

```csv
id,name,industry,country,created_at
1,"Tech Solutions Inc","technology","Brazil","2024-01-15 10:30:00"
2,"Marketing Pro","marketing","USA","2024-01-16 14:20:00"
```

## Comando para carregar

```bash
./scripts/data_loader.sh --load-all
```
EOF
    
    log "SUCCESS" "Estrutura criada em $CSV_DIR"
    log "INFO" "Consulte $CSV_DIR/README.md para instruções detalhadas"
}

# Função principal com menu interativo
main_menu() {
    echo
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║              🗃️  DATA LOADER                     ║${NC}"
    echo -e "${BOLD}${BLUE}║          Carregamento de CSVs                    ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${BOLD}Opções disponíveis:${NC}"
    echo
    echo -e "  ${CYAN}1${NC} - 📋 Listar tabelas configuradas"
    echo -e "  ${CYAN}2${NC} - 📁 Listar arquivos CSV disponíveis"
    echo -e "  ${CYAN}3${NC} - 📊 Carregar dados de uma tabela específica"
    echo -e "  ${CYAN}4${NC} - 🚀 Carregar dados de todas as tabelas"
    echo -e "  ${CYAN}5${NC} - 📝 Criar estrutura de CSVs de exemplo"
    echo -e "  ${CYAN}0${NC} - 🚪 Voltar ao menu principal"
    echo
    
    read -p "$(echo -e ${CYAN}Escolha uma opção [0-5]: ${NC})" choice
    
    case $choice in
        1)
            list_tables
            read -p "Pressione Enter para continuar..."
            main_menu
            ;;
        2)
            list_csv_files
            read -p "Pressione Enter para continuar..."
            main_menu
            ;;
        3)
            echo
            read -p "$(echo -e ${CYAN}Nome da tabela: ${NC})" table_name
            if [[ -n "$table_name" ]]; then
                load_table_data "$table_name"
            else
                log "ERROR" "Nome da tabela é obrigatório"
            fi
            read -p "Pressione Enter para continuar..."
            main_menu
            ;;
        4)
            load_all_data
            read -p "Pressione Enter para continuar..."
            main_menu
            ;;
        5)
            create_csv_template
            read -p "Pressione Enter para continuar..."
            main_menu
            ;;
        0)
            log "INFO" "Voltando ao menu principal..."
            exit 0
            ;;
        *)
            log "ERROR" "Opção inválida: $choice"
            sleep 1
            main_menu
            ;;
    esac
}

# Função principal
main() {
    check_dependencies
    check_cluster
    
    # Se não há argumentos, mostra menu interativo
    if [[ $# -eq 0 ]]; then
        main_menu
        return
    fi
    
    # Processa argumentos da linha de comando
    case "$1" in
        "--list-tables")
            list_tables
            ;;
        "--list-csv")
            list_csv_files
            ;;
        "--load-all")
            load_all_data
            ;;
        "--load-table")
            if [[ -n "${2:-}" ]]; then
                load_table_data "$2"
            else
                log "ERROR" "Nome da tabela é obrigatório"
                exit 1
            fi
            ;;
        "--create-template")
            create_csv_template
            ;;
        "--help"|"-h")
            echo -e "${BOLD}Data Loader - Carregamento de CSVs${NC}"
            echo
            echo "Uso: $0 [opção] [argumentos]"
            echo
            echo "Opções:"
            echo "  --list-tables          Lista tabelas configuradas"
            echo "  --list-csv             Lista arquivos CSV disponíveis"
            echo "  --load-all             Carrega dados de todas as tabelas"
            echo "  --load-table <nome>    Carrega dados de uma tabela específica"
            echo "  --create-template      Cria estrutura de CSVs de exemplo"
            echo "  --help, -h             Mostra esta ajuda"
            echo
            echo "Sem argumentos: Executa menu interativo"
            ;;
        *)
            log "ERROR" "Opção inválida: $1"
            log "INFO" "Use --help para ver opções disponíveis"
            exit 1
            ;;
    esac
}

# Executa função principal
main "$@"
