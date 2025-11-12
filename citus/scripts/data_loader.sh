#!/bin/bash

# DATA LOADER: CSV Data Loading System
# Purpose: Load data from CSV files into distributed tables

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
DATA_DIR="$CONFIG_DIR/data"
CSV_DIR="$CONFIG_DIR/csv"
SCENARIOS_DIR="$CONFIG_DIR/scenarios"
COORDINATOR_CONTAINER=""  # Will be detected dynamically
DATABASE_NAME=""  # Will be detected dynamically (citus_platform or citus)

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
    
    # Try each coordinator directly
    for coord in coordinator1 coordinator2 coordinator3; do
        container_name="citus_$coord"
        
        # Check if container is running
        docker_output=$(docker ps | grep "$container_name" || true)
        if [ -z "$docker_output" ]; then
            continue
        fi
        
        # Use Patroni API to detect leader
        leader=$(docker exec "$container_name" curl -s --connect-timeout 2 localhost:8008/cluster 2>/dev/null | \
                 grep -o '"name": "[^"]*", "role": "leader"' | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
        
        if [ -n "$leader" ]; then
            COORDINATOR_CONTAINER="citus_$leader"
            log "SUCCESS" "Leader coordinator detected: $leader"
            return 0
        fi
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
    
    if ! command -v yq &> /dev/null; then
        log "ERROR" "yq not found. Install with: brew install yq"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        log "ERROR" "Docker not found"
        exit 1
    fi
    
    if ! docker compose ps &> /dev/null; then
        log "ERROR" "Docker Compose not available or cluster not running"
        exit 1
    fi
    
    log "SUCCESS" "Dependencies verified"
}

# Function to check if cluster is running
check_cluster() {
    log "INFO" "Checking if Citus cluster is running..."
    
    # Detect leader coordinator
    detect_coordinator || return 1
    
    # Check connectivity - try citus_platform first, then citus
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d citus_platform -c "SELECT 1;" &> /dev/null; then
        DATABASE_NAME="citus_platform"
    elif docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d citus -c "SELECT 1;" &> /dev/null; then
        DATABASE_NAME="citus"
    else
        log "ERROR" "Cannot connect to Citus cluster"
        exit 1
    fi
    
    log "SUCCESS" "Citus cluster is running (database: $DATABASE_NAME)"
}

# Function to list available tables
list_tables() {
    log "INFO" "Available tables in tables.yml:"
    echo
    
    yq eval '.tables | keys' config/tables.yml | grep '^-' | sed 's/^- //' | while read -r table; do
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

# Function to check if CSV exists for a table
check_csv_exists() {
    local table_name="$1"
    local csv_file="$CSV_DIR/${table_name}.csv"
    
    if [[ -f "$csv_file" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate CSV structure
validate_csv_structure() {
    local table_name="$1"
    local csv_file="$CSV_DIR/${table_name}.csv"
    
    log "INFO" "Validating CSV structure for table '$table_name'..."
    
    if [[ ! -f "$csv_file" ]]; then
        log "ERROR" "CSV file not found: $csv_file"
        return 1
    fi
    
    # Check if file is not empty
    if [[ ! -s "$csv_file" ]]; then
        log "ERROR" "CSV file is empty: $csv_file"
        return 1
    fi
    
    # Read CSV header
    local csv_header=$(head -n 1 "$csv_file")
    log "INFO" "Header found: $csv_header"
    
    # Get expected columns from configuration
    local expected_columns=$(yq eval ".tables.\"$table_name\".columns | keys | join(\", \")" config/tables.yml)
    log "INFO" "Expected columns: $expected_columns"
    
    # Count data lines (excluding header)
    local data_lines=$(tail -n +2 "$csv_file" | wc -l | xargs)
    log "INFO" "Data lines found: $data_lines"
    
    return 0
}

# Function to load data from a table
load_table_data() {
    local table_name="$1"
    local csv_file="$CSV_DIR/${table_name}.csv"
    
    log "INFO" "Loading data for table '$table_name'..."
    
    # Validate CSV structure
    if ! validate_csv_structure "$table_name"; then
        return 1
    fi
    
    # Copy CSV file to container
    docker cp "$csv_file" "$COORDINATOR_CONTAINER:/tmp/${table_name}.csv"
    
    # Clear existing data to avoid conflicts
    log "INFO" "Clearing existing data from table '$table_name'..."
    docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DATABASE_NAME" -c "TRUNCATE TABLE $table_name CASCADE;" 2>/dev/null || true
    
    # Execute COPY to load data
    local copy_command="\\COPY $table_name FROM '/tmp/${table_name}.csv' WITH (FORMAT csv, HEADER true);"
    
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DATABASE_NAME" -c "$copy_command"; then
        log "SUCCESS" "Data loaded successfully for table '$table_name'"
        
        # Show statistics
        local count=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DATABASE_NAME" -t -c "SELECT COUNT(*) FROM $table_name;" | xargs)
        log "INFO" "Total records in table '$table_name': $count"
        
        # Remove temporary file
        docker exec "$COORDINATOR_CONTAINER" rm -f "/tmp/${table_name}.csv"
        
        return 0
    else
        log "ERROR" "Failed to load data for table '$table_name'"
        return 1
    fi
}

# Function to load data from all tables with available CSVs
load_all_data() {
    check_dependencies
    check_cluster
    
    log "INFO" "Loading data from all available tables..."
    
    # List available CSV files
    if [[ ! -d "$CSV_DIR" ]]; then
        log "WARNING" "CSV directory not found: $CSV_DIR"
        return 1
    fi
    
    # For each CSV found, try to load into corresponding table
    for csv_file in "$CSV_DIR"/*.csv; do
        if [[ -f "$csv_file" ]]; then
            local table_name=$(basename "$csv_file" .csv)
            log "INFO" "Processing table: $table_name"
            load_table_data "$table_name"
        fi
    done
    
    log "SUCCESS" "Complete loading finished!"
}

# Function to load data from a specific scenario
load_scenario_data() {
    local scenario="$1"
    
    check_dependencies
    check_cluster
    
    log "INFO" "Loading data from scenario: $scenario"
    
    # List available CSV files
    if [[ ! -d "$CSV_DIR" ]]; then
        log "WARNING" "CSV directory not found: $CSV_DIR"
        return 1
    fi
    
    # For each CSV found, try to load into corresponding table
    local loaded_count=0
    for csv_file in "$CSV_DIR"/*.csv; do
        if [[ -f "$csv_file" ]]; then
            local table_name=$(basename "$csv_file" .csv)
            log "INFO" "Processing table: $table_name"
            if load_table_data "$table_name"; then
                loaded_count=$((loaded_count + 1))
            fi
        fi
    done
    
    if [ $loaded_count -gt 0 ]; then
        log "SUCCESS" "Scenario '$scenario' loading finished! ($loaded_count tables loaded)"
    else
        log "WARNING" "No tables were loaded for scenario '$scenario'"
    fi
}

# Function to list available CSV files
list_csv_files() {
    log "INFO" "Available CSV files:"
    echo
    
    if [[ ! -d "$CSV_DIR" ]]; then
        log "WARNING" "Directory $CSV_DIR does not exist"
        log "INFO" "To use this functionality:"
        log "INFO" "  1. Create directory: mkdir -p $CSV_DIR"
        log "INFO" "  2. Add your CSV files with names corresponding to tables"
        log "INFO" "  3. Example: companies.csv, campaigns.csv, ads.csv"
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
            echo -e "    └─ Table: $table_name"
            echo -e "    └─ Size: $file_size"
            echo -e "    └─ Lines: $line_count"
            echo
            
            ((csv_count++))
        fi
    done
    
    if [[ $csv_count -eq 0 ]]; then
        log "WARNING" "No CSV files found in $CSV_DIR"
        log "INFO" "Add your CSV files to this directory to use data loading"
    else
        log "INFO" "Total CSV files found: $csv_count"
    fi
}

# Function to create CSV template directory
create_csv_template() {
    log "INFO" "Creating directory structure and example templates..."
    
    # Create directory
    mkdir -p "$CSV_DIR"
    
    # Create README file with instructions
    cat > "$CSV_DIR/README.md" << 'EOF'
# CSV Files Directory

This directory contains CSV files that will be loaded into Citus tables.

## Structure

Each CSV file should have the same name as the corresponding table:
- `companies.csv` → `companies` table
- `campaigns.csv` → `campaigns` table
- `ads.csv` → `ads` table

## Format

Files should have:
1. **Header**: First line with column names
2. **Data**: Subsequent lines with comma-separated data
3. **Encoding**: UTF-8
4. **Separator**: Comma (,)

## Example companies.csv

```csv
id,name,industry,country,created_at
1,"Tech Solutions Inc","technology","Brazil","2024-01-15 10:30:00"
2,"Marketing Pro","marketing","USA","2024-01-16 14:20:00"
```

## Command to load

```bash
./scripts/data_loader.sh --load-all
```
EOF
    
    log "SUCCESS" "Structure created in $CSV_DIR"
    log "INFO" "Check $CSV_DIR/README.md for detailed instructions"
}

# Main function with interactive menu
main_menu() {
    echo
    echo -e "${PURPLE}=====================================================${NC}"
    echo -e "${PURPLE}                   DATA LOADER                      ${NC}"
    echo -e "${PURPLE}                  CSV Data Loading                  ${NC}"
    echo -e "${PURPLE}=====================================================${NC}"
    echo
    
    echo -e "${BOLD}Available options:${NC}"
    echo
    echo -e "  ${CYAN}1${NC} - List configured tables"
    echo -e "  ${CYAN}2${NC} - List available CSV files"
    echo -e "  ${CYAN}3${NC} - Load data from specific table"
    echo -e "  ${CYAN}4${NC} - Load data from all tables"
    echo -e "  ${CYAN}5${NC} - Create example CSV structure"
    echo -e "  ${CYAN}0${NC} - Return to main menu"
    echo
    
    read -p "$(echo -e ${CYAN}Choose an option [0-5]: ${NC})" choice
    
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
            read -p "$(echo -e ${CYAN}Table name: ${NC})" table_name
            if [[ -n "$table_name" ]]; then
                load_table_data "$table_name"
            else
                log "ERROR" "Table name is required"
            fi
            read -p "Press Enter to continue..."
            main_menu
            ;;
        4)
            load_all_data
            read -p "Press Enter to continue..."
            main_menu
            ;;
        5)
            create_csv_template
            read -p "Press Enter to continue..."
            main_menu
            ;;
        0)
            log "INFO" "Returning to main menu..."
            exit 0
            ;;
        *)
            log "ERROR" "Invalid option: $choice"
            sleep 1
            main_menu
            ;;
    esac
}

# Main function
main() {
    check_dependencies
    check_cluster
    
    # If no arguments, show interactive menu
    if [[ $# -eq 0 ]]; then
        main_menu
        return
    fi
    
    # Process command line arguments
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
                log "ERROR" "Table name is required"
                exit 1
            fi
            ;;
        "load")
            # Dashboard compatibility - load scenario data
            if [[ -n "${2:-}" ]]; then
                load_scenario_data "$2"
            else
                log "ERROR" "Scenario name is required"
                exit 1
            fi
            ;;
        "--create-template")
            create_csv_template
            ;;
        "--help"|"-h")
            echo -e "${BOLD}Data Loader - CSV Loading System${NC}"
            echo
            echo "Usage: $0 [option] [arguments]"
            echo
            echo "Options:"
            echo "  --list-tables          List configured tables"
            echo "  --list-csv             List available CSV files"
            echo "  --load-all             Load data from all tables"
            echo "  --load-table <name>    Load data from specific table"
            echo "  --create-template      Create example CSV structure"
            echo "  --help, -h             Show this help"
            echo
            echo "No arguments: Run interactive menu"
            ;;
        *)
            log "ERROR" "Invalid option: $1"
            log "INFO" "Use --help to see available options"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
