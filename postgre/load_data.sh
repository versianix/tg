#!/usr/bin/env bash

# ================================================================================
# DATA LOADER FOR STANDARD POSTGRESQL
# File: load_data.sh
# Purpose: Load CSV data into PostgreSQL tables for benchmarking
# Compatible with Citus CSV data structure
# ================================================================================

set -e

# Color definitions for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
DB_HOST="localhost"
DB_PORT="5432"
DB_USER="postgres"
DB_PASSWORD="postgres"
DB_NAME="${1:-postgres_benchmark}"  # Use parameter or default
CONTAINER_NAME="pg_standard"

# CSV file paths
CSV_DIR="../citus/config/csv"
COMPANIES_CSV="${CSV_DIR}/companies.csv"
CAMPAIGNS_CSV="${CSV_DIR}/campaigns.csv"
ADS_CSV="${CSV_DIR}/ads.csv" 
SYSTEM_METRICS_CSV="${CSV_DIR}/system_metrics.csv"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${CYAN}[INFO]${NC}  [$timestamp] $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC}  [$timestamp] $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} [$timestamp] $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} [$timestamp] $message" ;;
    esac
}

check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    # Check if Docker is running
    if ! docker ps >/dev/null 2>&1; then
        log "ERROR" "Docker is not running or not accessible"
        exit 1
    fi
    
    # Check if container is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        log "ERROR" "PostgreSQL container '${CONTAINER_NAME}' is not running"
        log "INFO" "Please start it with: docker-compose up -d"
        exit 1
    fi
    
    # Check if CSV directory exists
    if [[ ! -d "$CSV_DIR" ]]; then
        log "ERROR" "CSV directory not found: $CSV_DIR"
        exit 1
    fi
    
    log "SUCCESS" "All dependencies are satisfied"
}

wait_for_postgres() {
    log "INFO" "Waiting for PostgreSQL to be ready..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker exec $CONTAINER_NAME pg_isready -U $DB_USER >/dev/null 2>&1; then
            log "SUCCESS" "PostgreSQL is ready!"
            return 0
        fi
        
        log "INFO" "Attempt $attempt/$max_attempts - PostgreSQL not ready yet..."
        sleep 2
        ((attempt++))
    done
    
    log "ERROR" "PostgreSQL failed to become ready after $max_attempts attempts"
    exit 1
}

check_database() {
    log "INFO" "Checking if database '$DB_NAME' exists..."
    
    local db_exists=$(docker exec $CONTAINER_NAME psql -U $DB_USER -lqt | cut -d \| -f 1 | grep -w $DB_NAME | wc -l)
    
    if [[ $db_exists -eq 0 ]]; then
        log "ERROR" "Database '$DB_NAME' does not exist"
        log "INFO" "Please create it first by running the schema.sql script"
        exit 1
    fi
    
    log "SUCCESS" "Database '$DB_NAME' exists"
}

check_tables() {
    log "INFO" "Checking if required tables exist..."
    
    local required_tables=("companies" "campaigns" "ads" "system_metrics")
    
    for table in "${required_tables[@]}"; do
        local table_exists=$(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "
            SELECT COUNT(*) FROM information_schema.tables 
            WHERE table_name = '$table' AND table_schema = 'public'
        " | tr -d ' ')
        
        if [[ $table_exists -eq 0 ]]; then
            log "ERROR" "Table '$table' does not exist"
            log "INFO" "Please run the schema.sql script first"
            exit 1
        fi
    done
    
    log "SUCCESS" "All required tables exist"
}

check_csv_files() {
    log "INFO" "Checking CSV files..."
    log "INFO" "CSV directory: $CSV_DIR"
    
    local missing_files=0
    
    # Check each CSV file
    for csv_file in "$COMPANIES_CSV" "$CAMPAIGNS_CSV" "$ADS_CSV" "$SYSTEM_METRICS_CSV"; do
        if [[ ! -f "$csv_file" ]]; then
            log "ERROR" "CSV file not found: $csv_file"
            missing_files=$((missing_files + 1))
        else
            local lines=$(wc -l < "$csv_file" 2>/dev/null || echo "0")
            local basename=$(basename "$csv_file")
            local size=$(ls -lh "$csv_file" | awk '{print $5}')
            log "INFO" "Found $basename: $csv_file ($lines lines, $size)"
            
            # Show first few lines for debugging
            log "INFO" "Preview of $basename (first 3 lines):"
            head -n 3 "$csv_file" | while IFS= read -r line; do
                log "INFO" "  $line"
            done
        fi
    done
    
    if [[ $missing_files -gt 0 ]]; then
        log "ERROR" "Found $missing_files missing CSV files"
        return 1
    fi
    
    log "SUCCESS" "All CSV files found and accessible"
    return 0
}

# ============================================================================
# DATA LOADING FUNCTIONS
# ============================================================================

load_table_data() {
    local table=$1
    local csv_path=$2
    local csv_file=$(basename "$csv_path")
    
    if [[ ! -f "$csv_path" ]]; then
        log "WARN" "CSV file not found: $csv_path - skipping $table"
        return 1
    fi
    
    log "INFO" "Loading data into table '$table' from '$csv_path'..."
    
    # Get CSV info
    local total_lines=$(wc -l < "$csv_path")
    local data_lines=$((total_lines - 1))  # Subtract header
    
    log "INFO" "CSV file has $data_lines data rows (excluding header)"
    
    # Clear table first
    docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "TRUNCATE TABLE $table RESTART IDENTITY CASCADE;" >/dev/null
    
    # Copy CSV file to container
    docker cp "$csv_path" "$CONTAINER_NAME:/tmp/$csv_file"
    
    # Load data based on table type
    local copy_result=0
    case $table in
        "companies")
            docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "
                COPY companies(id, name, industry, country, created_at) 
                FROM '/tmp/$csv_file' 
                DELIMITER ',' CSV HEADER;
            "
            copy_result=$?
            ;;
        "campaigns") 
            docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "
                COPY campaigns(id, company_id, name, budget, status, start_date, end_date, created_at) 
                FROM '/tmp/$csv_file' 
                DELIMITER ',' CSV HEADER;
            "
            copy_result=$?
            ;;
        "ads")
            docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "
                COPY ads(id, campaign_id, company_id, title, content, clicks, impressions, cost, created_at) 
                FROM '/tmp/$csv_file' 
                DELIMITER ',' CSV HEADER;
            "
            copy_result=$?
            ;;
        "system_metrics")
            docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "
                COPY system_metrics(id, metric_name, metric_value, collected_at) 
                FROM '/tmp/$csv_file' 
                DELIMITER ',' CSV HEADER;
            "
            copy_result=$?
            ;;
        *)
            log "ERROR" "Unknown table: $table"
            return 1
            ;;
    esac
    
    # Check if the COPY command succeeded
    if [[ $copy_result -eq 0 ]]; then
        log "INFO" "COPY command completed successfully for $table"
    else
        log "ERROR" "COPY command failed for $table (exit code: $copy_result)"
        return 1
    fi
    
    # Verify loaded data
    local loaded_count=$(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM $table;" | tr -d ' ')
    
    log "INFO" "Verification: Expected $data_lines records, found $loaded_count in '$table'"
    
    if [[ $loaded_count -eq $data_lines ]]; then
        log "SUCCESS" "Successfully loaded $loaded_count records into '$table'"
    else
        log "WARN" "Expected $data_lines records, but loaded $loaded_count into '$table'"
    fi
    
    # Cleanup temp file
    docker exec $CONTAINER_NAME rm -f "/tmp/$csv_file"
    
    return 0
}

load_all_data() {
    log "INFO" "Starting data loading process..."
    
    local total_tables=4
    local loaded_tables=0
    local failed_tables=0
    
    # Load in order: companies -> campaigns -> ads -> system_metrics (due to FK constraints)
    
    if load_table_data "companies" "$COMPANIES_CSV"; then
        ((loaded_tables++))
    else
        ((failed_tables++))
    fi
    echo ""
    
    if load_table_data "campaigns" "$CAMPAIGNS_CSV"; then
        ((loaded_tables++))
    else
        ((failed_tables++))
    fi
    echo ""
    
    if load_table_data "ads" "$ADS_CSV"; then
        ((loaded_tables++))
    else
        ((failed_tables++))
    fi
    echo ""
    
    if load_table_data "system_metrics" "$SYSTEM_METRICS_CSV"; then
        ((loaded_tables++))
    else
        ((failed_tables++))
    fi
    echo ""
    
    log "INFO" "Data loading completed!"
    log "INFO" "Tables loaded successfully: $loaded_tables/$total_tables"
    
    if [[ $failed_tables -gt 0 ]]; then
        log "WARN" "Tables with issues: $failed_tables"
    fi
}

show_data_summary() {
    log "INFO" "Generating data summary..."
    
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}                    DATA SUMMARY${NC}"
    echo -e "${BLUE}============================================================${NC}"
    
    docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "
        SELECT 
            'companies' as table_name, 
            COUNT(*) as record_count,
            MIN(created_at) as earliest_date,
            MAX(created_at) as latest_date
        FROM companies
        UNION ALL
        SELECT 
            'campaigns' as table_name, 
            COUNT(*) as record_count,
            MIN(created_at) as earliest_date,
            MAX(created_at) as latest_date
        FROM campaigns
        UNION ALL
        SELECT 
            'ads' as table_name, 
            COUNT(*) as record_count,
            MIN(created_at) as earliest_date,
            MAX(created_at) as latest_date
        FROM ads
        UNION ALL
        SELECT 
            'system_metrics' as table_name, 
            COUNT(*) as record_count,
            MIN(collected_at) as earliest_date,
            MAX(collected_at) as latest_date
        FROM system_metrics
        ORDER BY table_name;
    "
    
    echo ""
    log "INFO" "Sample business analysis queries:"
    
    # Top companies by campaign budget
    echo -e "\n${PURPLE}Top 5 Companies by Total Campaign Budget:${NC}"
    docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "
        SELECT * FROM campaign_summary 
        LIMIT 5;
    "
    
    # Ads performance summary
    echo -e "\n${PURPLE}Top 5 Campaigns by Performance:${NC}"
    docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "
        SELECT * FROM ads_performance 
        LIMIT 5;
    "
    
    echo -e "${BLUE}============================================================${NC}"
}

validate_data() {
    log "INFO" "Validating data integrity..."
    
    # Check for orphaned campaigns (campaigns without valid companies)
    local orphaned_campaigns=$(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "
        SELECT COUNT(*) FROM campaigns c 
        LEFT JOIN companies comp ON c.company_id = comp.id 
        WHERE comp.id IS NULL;
    " | tr -d ' ')
    
    if [[ $orphaned_campaigns -gt 0 ]]; then
        log "WARN" "Found $orphaned_campaigns orphaned campaigns (no matching company)"
    fi
    
    # Check for orphaned ads
    local orphaned_ads=$(docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "
        SELECT COUNT(*) FROM ads a 
        LEFT JOIN companies comp ON a.company_id = comp.id 
        WHERE comp.id IS NULL;
    " | tr -d ' ')
    
    if [[ $orphaned_ads -gt 0 ]]; then
        log "WARN" "Found $orphaned_ads orphaned ads (no matching company)"
    fi
    
    if [[ $orphaned_campaigns -eq 0 && $orphaned_ads -eq 0 ]]; then
        log "SUCCESS" "Data integrity validation passed!"
    fi
}

# ============================================================================
# CLEANUP FUNCTIONS  
# ============================================================================

clean_all_data() {
    log "WARN" "This will remove ALL data from all tables. Continue? (y/N)"
    read -r confirmation
    
    if [[ $confirmation =~ ^[Yy]$ ]]; then
        log "INFO" "Cleaning all tables..."
        docker exec $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -c "SELECT truncate_all_tables();" >/dev/null
        log "SUCCESS" "All tables have been cleaned"
    else
        log "INFO" "Operation cancelled"
    fi
}

# ============================================================================
# MAIN MENU AND EXECUTION
# ============================================================================

show_help() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}           PostgreSQL Data Loader v1.0${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
    echo "Usage: $0 [DATABASE_NAME] [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  load        Load all CSV data into tables"
    echo "  summary     Show data summary and statistics" 
    echo "  validate    Validate data integrity"
    echo "  clean       Clean all data from tables"
    echo "  check       Check prerequisites and dependencies"
    echo "  help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 postgres_benchmark load     # Load all CSV data"
    echo "  $0 postgres_benchmark summary  # Show loaded data summary"
    echo "  $0 postgres_benchmark clean    # Clean all tables"
    echo "  $0 load                        # Use default database"
    echo ""
    echo "CSV Data Source: $CSV_DIR"
    echo "Target Database: $DB_NAME on $CONTAINER_NAME"
    echo ""
}

main() {
    # If first parameter looks like a database name (not a command), use it
    if [[ "$1" != "" && "$1" != "load" && "$1" != "summary" && "$1" != "validate" && "$1" != "clean" && "$1" != "check" && "$1" != "help" ]]; then
        DB_NAME="$1"
        shift  # Remove database name from parameters
    fi
    
    case "${1:-help}" in
        "load")
            check_dependencies
            wait_for_postgres
            check_database
            check_tables
            check_csv_files
            load_all_data
            validate_data
            show_data_summary
            ;;
        "summary")
            check_dependencies
            wait_for_postgres
            check_database
            show_data_summary
            ;;
        "validate")
            check_dependencies
            wait_for_postgres
            check_database
            validate_data
            ;;
        "clean")
            check_dependencies
            wait_for_postgres
            check_database
            clean_all_data
            ;;
        "check")
            check_dependencies
            wait_for_postgres
            check_database
            check_tables
            log "SUCCESS" "All checks passed!"
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

# Execute main function
main "$@"