#!/bin/bash

# SCHEMA MANAGER: Intelligent Schema Management System
# Purpose: Create tables and configure sharding based on YAML files

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
COMPOSE_PROJECT_NAME="citus"
CONFIG_DIR="config"
SCENARIOS_DIR="$CONFIG_DIR/scenarios"
COORDINATOR_CONTAINER=""  # Will be detected dynamically

# Function for formatted logging
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${CYAN}[$timestamp] INFO: $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] SUCCESS: $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] WARNING: $message${NC}" ;;
        "ERROR") echo -e "${RED}[$timestamp] ERROR: $message${NC}" ;;
        "DEBUG") echo -e "${PURPLE}[$timestamp] DEBUG: $message${NC}" ;;
    esac
}

# Function to detect active architecture
detect_architecture() {
    # Check if Patroni containers are running
    if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$"; then
        echo "patroni"
    # Check if simple container is running
    elif docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$"; then
        echo "simple"
    else
        echo "none"
    fi
}

# Function to detect coordinator based on architecture
detect_coordinator() {
    local arch=$(detect_architecture)
    
    case $arch in
        "patroni")
            detect_patroni_leader
            ;;
        "simple")
            detect_simple_coordinator
            ;;
        *)
            log "ERROR" "No Citus architecture detected"
            return 1
            ;;
    esac
}

# Function to detect Patroni leader coordinator via API
detect_patroni_leader() {
    log "INFO" "Detecting leader coordinator (Patroni)..."
    
    # Try to detect leader for up to 1 minute 
    local max_attempts=120  # 60 seconds (120 * 0.5s)
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Check for leader using multiple methods
        for coord in coordinator1 coordinator2 coordinator3; do
            container_name="citus_$coord"

            # Check if the container is running
            if ! docker ps --format "table {{.Names}}" | grep -q "^$container_name$"; then
                continue
            fi

            # Method 1: Check Patroni API for master role
            role=$(docker exec "$container_name" curl -s localhost:8008/ 2>/dev/null | grep -o '"role":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            if [[ "$role" == "master" ]]; then
                COORDINATOR_CONTAINER="$container_name"
                log "SUCCESS" "Leader coordinator detected: $coord"
                return 0
            fi
            
            # Method 2: Direct PostgreSQL check for master/replica status
            if docker exec "$container_name" pg_isready -U postgres >/dev/null 2>&1; then
                postgres_role=$(docker exec "$container_name" psql -U postgres -t -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'master' END;" 2>/dev/null | tr -d ' ')
                if [[ "$postgres_role" == "master" ]]; then
                    COORDINATOR_CONTAINER="$container_name"
                    log "SUCCESS" "Leader coordinator detected: $coord"
                    return 0
                fi
            fi
        done
        
        sleep 0.5
        attempt=$((attempt + 1))
    done

    log "WARNING" "Could not detect leader. Using coordinator1 (fallback)"
    COORDINATOR_CONTAINER="citus_coordinator1"
    return 1
}

# Function to detect simple coordinator
detect_simple_coordinator() {
    log "INFO" "Detecting coordinator (Simple Architecture)..."
    
    if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$"; then
        COORDINATOR_CONTAINER="citus_coordinator"
        log "SUCCESS" "Coordinator detected: citus_coordinator"
        return 0
    else
        log "ERROR" "Container citus_coordinator not found"
        return 1
    fi
}

# Function to check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    # Check if yq is installed (for YAML parsing)
    if ! command -v yq &> /dev/null; then
        log "WARNING" "yq not found. Attempting to install..."
        if command -v brew &> /dev/null; then
            brew install yq
        else
            log "ERROR" "Please install yq: https://github.com/mikefarah/yq"
            log "INFO" "macOS: brew install yq"
            log "INFO" "Linux: wget -qO- https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 > /usr/local/bin/yq && chmod +x /usr/local/bin/yq"
            return 1
        fi
    fi
    
    # Check Docker
    if ! docker ps > /dev/null 2>&1; then
        log "ERROR" "Docker is not running or not accessible"
        return 1
    fi
    
    # Detect and verify coordinator based on architecture
    detect_coordinator || return 1
    
    # Check if cluster is running
    if ! docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        log "ERROR" "Citus cluster is not running or leader coordinator is not accessible"
        return 1
    fi
    
    log "SUCCESS" "All dependencies verified"
}

# Function to list available scenarios
list_scenarios() {
    log "INFO" "Available scenarios:"
    echo
    
    for scenario_file in "$SCENARIOS_DIR"/*.yml; do
        if [[ -f "$scenario_file" ]]; then
            local scenario_name=$(basename "$scenario_file" .yml)
            local description=$(yq eval '.scenario.description // "No description"' "$scenario_file")
            local complexity=$(yq eval '.scenario.complexity // "unknown"' "$scenario_file")
            
            case $complexity in
                "beginner") complexity_level="[BASIC]" ;;
                "intermediate") complexity_level="[INTERMEDIATE]" ;;
                "advanced") complexity_level="[ADVANCED]" ;;
                *) complexity_level="[UNKNOWN]" ;;
            esac
            
            echo -e "  ${complexity_level} ${BOLD}${scenario_name}${NC}: $description"
        fi
    done
    echo
}

# Function to parse YAML configuration file
parse_yaml_config() {
    local config_file="$1"
    
    log "INFO" "Parsing configuration: $config_file"
    
    # Check if file exists
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "Configuration file not found: $config_file"
        return 1
    fi
    
    # Extract database name
    DB_NAME=$(yq eval '.database.name // "test_db"' "$config_file")
    log "DEBUG" "Database: $DB_NAME"
    
    # Check if there's a table import
    local import_file=$(yq eval '.import // ""' "$config_file")
    if [[ -n "$import_file" && "$import_file" != "null" ]]; then
        # Resolve relative path
        import_file="$CONFIG_DIR/$import_file"
        if [[ ! -f "$import_file" ]]; then
            import_file="$CONFIG_DIR/tables.yml"  # Fallback
        fi
        log "DEBUG" "Importing definitions from: $import_file"
        TABLES_CONFIG="$import_file"
    else
        TABLES_CONFIG="$config_file"
    fi
}

# Function to create database
create_database() {
    local db_name="$1"
    
    log "INFO" "Checking database: $db_name"
    
    # Check if database already exists
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
        log "INFO" "Database '$db_name' already exists. Reusing..."
    else
        log "INFO" "Creating database: $db_name"
        docker exec "$COORDINATOR_CONTAINER" psql -U postgres -c "CREATE DATABASE $db_name;"
    fi
    
    # Create Citus extension (if it doesn't exist)
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$db_name" -c "CREATE EXTENSION IF NOT EXISTS citus;"
    
    log "SUCCESS" "Database '$db_name' ready with Citus extension"
}

# Function to create a table based on YAML configuration
create_table() {
    local table_name="$1"
    local config_file="$2"
    
    log "INFO" "Creating table: $table_name"
    
    # Check if table already exists
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "\dt" | grep -qw "$table_name"; then
        log "WARNING" "Table '$table_name' already exists. Skipping creation..."
        return 0
    fi
    
    # Extract table configuration
    local table_type=$(yq eval ".tables.${table_name}.type" "$config_file")
    local description=$(yq eval ".tables.${table_name}.description" "$config_file")
    
    log "DEBUG" "Type: $table_type | Description: $description"
    
    # Build DDL
    local ddl="CREATE TABLE $table_name ("
    
    # Add columns
    local columns_count=$(yq eval ".tables.${table_name}.columns | length" "$config_file")
    for ((i=0; i<columns_count; i++)); do
        local col_name=$(yq eval ".tables.${table_name}.columns[$i].name" "$config_file")
        local col_type=$(yq eval ".tables.${table_name}.columns[$i].type" "$config_file")
        local col_desc=$(yq eval ".tables.${table_name}.columns[$i].description // \"\"" "$config_file")
        
        ddl="$ddl\n    $col_name $col_type"
        [[ $i -lt $((columns_count-1)) ]] && ddl="$ddl,"
        
        log "DEBUG" "  Column: $col_name ($col_type)"
    done
    
    # Check for custom primary key
    local pk=$(yq eval ".tables.${table_name}.primary_key // []" "$config_file")
    if [[ "$pk" != "[]" && "$pk" != "null" ]]; then
        local pk_cols=$(yq eval ".tables.${table_name}.primary_key | join(\", \")" "$config_file")
        ddl="$ddl,\n    PRIMARY KEY ($pk_cols)"
        log "DEBUG" "  Primary key: $pk_cols"
    fi
    
    ddl="$ddl\n);"
    
    # Execute DDL
    log "DEBUG" "Executing DDL for $table_name"
    echo -e "$ddl" | docker exec -i "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME"
    
    # Configure distribution
    configure_table_distribution "$table_name" "$config_file"
    
    # Create indexes
    create_table_indexes "$table_name" "$config_file"
    
    log "SUCCESS" "Table '$table_name' created successfully"
}

# Function to configure table distribution
configure_table_distribution() {
    local table_name="$1"
    local config_file="$2"
    
    local table_type=$(yq eval ".tables.${table_name}.type" "$config_file")
    
    case $table_type in
        "reference")
            log "INFO" "Configuring '$table_name' as reference table"
            docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                -c "SELECT create_reference_table('$table_name');"
            ;;
            
        "distributed")
            local shard_key=$(yq eval ".tables.${table_name}.shard_key" "$config_file")
            local shard_count=$(yq eval ".tables.${table_name}.shard_count // 4" "$config_file")
            
            # Check for co-location before creating
            local colocated_with=$(yq eval ".tables.${table_name}.colocated_with // \"\"" "$config_file")
            
            if [[ -n "$colocated_with" && "$colocated_with" != "null" ]]; then
                log "INFO" "Configuring '$table_name' as distributed table co-located with '$colocated_with'"
                docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                    -c "SELECT create_distributed_table('$table_name', '$shard_key', colocate_with => '$colocated_with');"
            else
                log "INFO" "Configuring '$table_name' as distributed table (shard_key: $shard_key, shards: $shard_count)"
                docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                    -c "SELECT create_distributed_table('$table_name', '$shard_key', shard_count => $shard_count);"
            fi
            ;;
            
        "local")
            log "INFO" "Keeping '$table_name' as local table (not distributed)"
            ;;
            
        *)
            log "WARNING" "Unknown table type: $table_type. Keeping as local"
            ;;
    esac
}

# Function to create indexes
create_table_indexes() {
    local table_name="$1"
    local config_file="$2"
    
    local indexes_count=$(yq eval ".tables.${table_name}.indexes | length" "$config_file" 2>/dev/null || echo "0")
    
    if [[ "$indexes_count" -gt 0 ]]; then
        log "INFO" "Creating indexes for '$table_name'"
        
        for ((i=0; i<indexes_count; i++)); do
            local idx_name=$(yq eval ".tables.${table_name}.indexes[$i].name" "$config_file")
            local idx_columns=$(yq eval ".tables.${table_name}.indexes[$i].columns | join(\", \")" "$config_file")
            
            log "DEBUG" "  Index: $idx_name ($idx_columns)"
            
            docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" \
                -c "CREATE INDEX IF NOT EXISTS $idx_name ON $table_name ($idx_columns);"
        done
    fi
}

# Main function to create complete schema
create_schema() {
    local scenario="$1"
    local config_file="$SCENARIOS_DIR/${scenario}.yml"
    
    log "INFO" "Starting schema creation for scenario: $scenario"
    
    # Check dependencies
    check_dependencies || return 1
    
    # Parse configuration
    parse_yaml_config "$config_file" || return 1
    
    # Create database
    create_database "$DB_NAME"
    
    # Get table list in correct order
    local tables=$(yq eval '.tables | keys | .[]' "$TABLES_CONFIG")
    
    log "INFO" "Tables to be created: $(echo $tables | tr '\n' ' ')"
    
    # Create tables in order (reference first, then distributed)
    echo "$tables" | while read -r table; do
        [[ -n "$table" && "$table" != "null" ]] && create_table "$table" "$TABLES_CONFIG"
    done
    
    # Show final summary
    show_schema_summary
    
    log "SUCCESS" "Schema created successfully"
}

# Function to show schema summary
show_schema_summary() {
    log "INFO" "Schema Summary"
    
    echo -e "\n${CYAN}Created tables:${NC}"
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        schemaname,
        tablename,
        CASE 
            WHEN tablename IN (SELECT logicalrelid::regclass::text FROM pg_dist_partition WHERE partmethod = 'n')
            THEN 'Reference'
            WHEN tablename IN (SELECT logicalrelid::regclass::text FROM pg_dist_partition WHERE partmethod = 'h')
            THEN 'Distributed'
            ELSE 'Local'
        END as type
    FROM pg_tables 
    WHERE schemaname = 'public' 
      AND tablename NOT LIKE 'pgbench_%'
    ORDER BY 
        CASE 
            WHEN tablename IN (SELECT logicalrelid::regclass::text FROM pg_dist_partition WHERE partmethod = 'n') THEN 1
            WHEN tablename IN (SELECT logicalrelid::regclass::text FROM pg_dist_partition WHERE partmethod = 'h') THEN 2
            ELSE 3
        END, tablename;
    "
    
    echo -e "\n${CYAN}Shard distribution:${NC}"
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        p.logicalrelid::regclass as table_name,
        CASE 
            WHEN p.partmethod = 'n' THEN 'Reference Table'
            ELSE COUNT(s.shardid)::text
        END as shards,
        CASE 
            WHEN p.partmethod = 'n' THEN 'N/A'
            WHEN p.partmethod = 'h' THEN 'company_id'
            ELSE 'Unknown'
        END as shard_key,
        CASE 
            WHEN p.partmethod = 'n' THEN 'Reference'
            WHEN p.partmethod = 'h' THEN 'Hash Distributed'
            ELSE 'Unknown'
        END as distribution_method,
        p.colocationid as colocation_group
    FROM pg_dist_partition p
    LEFT JOIN pg_dist_shard s ON s.logicalrelid = p.logicalrelid
    WHERE p.logicalrelid::regclass::text NOT LIKE 'pgbench_%'
    GROUP BY p.logicalrelid, p.partkey, p.partmethod, p.colocationid
    ORDER BY 
        CASE p.partmethod WHEN 'n' THEN 1 WHEN 'h' THEN 2 ELSE 3 END,
        p.logicalrelid::regclass;
    " 2>/dev/null || echo -e "    ${YELLOW}No Citus distributed tables found${NC}"
}

# Function to clean schema (drop all user tables)
clean_schema() {
    log "INFO" "Schema cleanup - removing all user tables"
    
    # Check dependencies
    check_dependencies || return 1
    
    # Detect database name (try citus_platform first, then citus)
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "citus_platform"; then
        DB_NAME="citus_platform"
    elif docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "citus"; then
        DB_NAME="citus"
    else
        log "ERROR" "Cannot find Citus database (citus_platform or citus)"
        return 1
    fi
    
    log "INFO" "Using database: $DB_NAME"
    
    echo -e "${YELLOW}WARNING: This will drop all user tables in database '$DB_NAME'${NC}"
    echo -e "${YELLOW}Tables to be dropped:${NC}"
    
    # Show tables that will be dropped
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "
    SELECT tablename FROM pg_tables 
    WHERE schemaname = 'public' 
    AND tablename NOT LIKE 'pg_%' 
    AND tablename NOT LIKE 'citus_%'
    ORDER BY tablename;
    "
    
    echo
    echo -n -e "${CYAN}Do you want to continue? [y/N]: ${NC}"
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        log "INFO" "Dropping all user tables..."
        
        # Drop all user tables (this handles distributed, reference, and local tables)
        docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "
        DO \$\$
        DECLARE
            rec RECORD;
        BEGIN
            FOR rec IN 
                SELECT tablename 
                FROM pg_tables 
                WHERE schemaname = 'public' 
                AND tablename NOT LIKE 'pg_%' 
                AND tablename NOT LIKE 'citus_%'
            LOOP
                EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(rec.tablename) || ' CASCADE';
                RAISE NOTICE 'Dropped table: %', rec.tablename;
            END LOOP;
        END
        \$\$;
        "
        
        log "SUCCESS" "All user tables dropped successfully"
    else
        log "INFO" "Schema cleanup cancelled"
    fi
}

# Function for interactive mode
interactive_mode() {
    while true; do
        echo -e "${PURPLE}=====================================================${NC}"
        echo -e "${PURPLE}           INTERACTIVE SCHEMA MANAGER               ${NC}"
        echo -e "${PURPLE}=====================================================${NC}"
        echo
        
        echo -e "${BOLD}Available options:${NC}"
        echo
        echo -e "  ${CYAN}1${NC} - List available scenarios"
        echo -e "  ${CYAN}2${NC} - Create schema from scenario"
        echo -e "  ${CYAN}3${NC} - Show current schema summary"
        echo -e "  ${CYAN}4${NC} - Clean schema (drop all tables)"
        echo -e "  ${CYAN}0${NC} - Return to main menu"
        echo
        
        echo -n -e "${CYAN}Choose an option [0-4]: ${NC}"
        read -r choice
        
        case $choice in
            1)
                list_scenarios
                echo "Press Enter to continue..."
                read -r
                ;;
            2)
                echo
                list_scenarios
                echo -n -e "${CYAN}Choose a scenario to create: ${NC}"
                read -r scenario
                
                if [[ -f "$SCENARIOS_DIR/${scenario}.yml" ]]; then
                    create_schema "$scenario"
                    echo "Press Enter to continue..."
                    read -r
                else
                    log "ERROR" "Scenario '$scenario' not found"
                    echo "Press Enter to continue..."
                    read -r
                fi
                ;;
            3)
                # Check if we can show summary
                if check_dependencies 2>/dev/null; then
                    # Detect database name for summary
                    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "citus_platform"; then
                        DB_NAME="citus_platform"
                    elif docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "citus"; then
                        DB_NAME="citus"
                    else
                        log "ERROR" "Cannot find Citus database"
                    fi
                    show_schema_summary
                else
                    log "ERROR" "Cannot connect to cluster to show summary"
                fi
                echo "Press Enter to continue..."
                read -r
                ;;
            4)
                clean_schema
                echo "Press Enter to continue..."
                read -r
                ;;
            0)
                log "INFO" "Returning to main menu..."
                return 0
                ;;
            *)
                log "ERROR" "Invalid option: $choice"
                sleep 1
                ;;
        esac
    done
}

# Main function
main() {
    case "${1:-}" in
        "list"|"ls")
            list_scenarios
            ;;
        "create")
            if [[ -n "${2:-}" ]]; then
                create_schema "$2"
            else
                log "ERROR" "Usage: $0 create <scenario>"
                list_scenarios
                return 1
            fi
            ;;
        "clean")
            clean_schema
            ;;
        "summary")
            if check_dependencies 2>/dev/null; then
                # Detect database name for summary
                if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "citus_platform"; then
                    DB_NAME="citus_platform"
                elif docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "citus"; then
                    DB_NAME="citus"
                else
                    log "ERROR" "Cannot find Citus database (citus_platform or citus)"
                    return 1
                fi
                show_schema_summary
            else
                log "ERROR" "Cannot connect to cluster"
                return 1
            fi
            ;;
        "interactive"|"")
            interactive_mode
            ;;
        "help"|"-h"|"--help")
            echo -e "${BOLD}Schema Manager - Citus Schema Management System${NC}"
            echo
            echo "Usage:"
            echo "  $0 [command] [options]"
            echo
            echo "Commands:"
            echo "  list, ls              List available scenarios"
            echo "  create <scenario>     Create schema for specified scenario"
            echo "  clean                 Clean schema (drop all user tables)"
            echo "  summary               Show current schema summary"
            echo "  interactive           Interactive mode (default)"
            echo "  help                  Show this help"
            echo
            echo "Examples:"
            echo "  $0 list"
            echo "  $0 create adtech"
            echo "  $0 clean"
            echo "  $0 summary"
            echo "  $0 interactive"
            ;;
        *)
            log "ERROR" "Unknown command: $1"
            echo "Use '$0 help' to see available commands"
            return 1
            ;;
    esac
}

# Execute main function with arguments
main "$@"
