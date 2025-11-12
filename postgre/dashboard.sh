#!/bin/bash

# ================================================================================
#                         POSTGRESQL BASELINE LABORATORY
#                            Monolithic Database Benchmark
#                             Bachelor's Thesis Project
# ================================================================================
#
# Interactive Dashboard - Baseline PostgreSQL Environment
# Objective: Control interface for PostgreSQL monolithic database testing

set -euo pipefail

# ================================================================================
# SETTINGS AND CONSTANTS
# ================================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Database settings
DATABASE_NAME="benchmark_db"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="postgres"

# ================================================================================
# UTILITY FUNCTIONS
# ================================================================================

# Function for logging with timestamp
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${GREEN}[${timestamp}]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[${timestamp}]${NC} $message" ;;
        "ERROR") echo -e "${RED}[${timestamp}]${NC} $message" ;;
        "DEBUG") echo -e "${CYAN}[${timestamp}]${NC} $message" ;;
        *)       echo -e "[${timestamp}] $message" ;;
    esac
}

# Function to check if container is running
is_container_running() {
    local container_name=$1
    docker ps --format "{{.Names}}" | grep -q "^${container_name}$"
}

# Function to wait for PostgreSQL to be ready
wait_for_postgres() {
    log "INFO" "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker exec pg_standard pg_isready -U postgres >/dev/null 2>&1; then
            log "INFO" "PostgreSQL ready!"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    log "ERROR" "PostgreSQL not ready after ${max_attempts} attempts"
    return 1
}

# ================================================================================
# STATUS FUNCTIONS
# ================================================================================

# Show containers status
show_containers_status() {
    echo -e "\n${BLUE}CONTAINER STATUS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    local containers=("pg_standard" "postgres_exporter" "node_exporter" "prometheus_pg" "grafana_pg" "pgbench")
    
    for container in "${containers[@]}"; do
        if is_container_running "$container"; then
            local status="ACTIVE"
            local uptime=$(docker ps --format "{{.Status}}" --filter "name=^${container}$")
            echo -e "   ${container}: ${GREEN}${status}${NC} (${uptime})"
        else
            echo -e "   ${container}: ${RED}INACTIVE${NC}"
        fi
    done
}

# Show database status
show_database_status() {
    echo -e "\n${BLUE}DATABASE STATUS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    if ! is_container_running "pg_standard"; then
        echo -e "   ${RED}PostgreSQL is not running${NC}"
        return
    fi
    
    # Check if the database exists
    local db_exists=$(docker exec pg_standard psql -U postgres -t -c "SELECT 1 FROM pg_database WHERE datname='${DATABASE_NAME}'" 2>/dev/null | grep -c "1" || echo "0")
    
    if [ "$db_exists" = "1" ]; then
        echo -e "   Database: ${GREEN}${DATABASE_NAME} ACTIVE${NC}"
        
        # Check tables
        local tables_count=$(docker exec pg_standard psql -U postgres -d "${DATABASE_NAME}" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || echo "0")
        echo -e "   Tables: ${GREEN}${tables_count} tables created${NC}"
        
        # Check data
        if [ "$tables_count" -gt "0" ]; then
            local total_records=0
            local tables=("companies" "campaigns" "ads" "system_metrics")
            
            for table in "${tables[@]}"; do
                local count=$(docker exec pg_standard psql -U postgres -d "${DATABASE_NAME}" -t -c "SELECT COUNT(*) FROM ${table}" 2>/dev/null || echo "0")
                if [ "$count" -gt "0" ]; then
                    echo -e "   - ${table}: ${GREEN}${count} records${NC}"
                    ((total_records += count))
                else
                    echo -e "   - ${table}: ${YELLOW}empty${NC}"
                fi
            done
            
            echo -e "   Total records: ${GREEN}${total_records}${NC}"
        fi
    else
        echo -e "   Database: ${YELLOW}${DATABASE_NAME} not created${NC}"
    fi
}

# Show monitoring services status
show_monitoring_status() {
    echo -e "\n${BLUE}MONITORING SERVICES${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    # Prometheus
    if is_container_running "prometheus_pg"; then
        echo -e "   Prometheus: ${GREEN}ACTIVE${NC} - http://localhost:9090"
    else
        echo -e "   Prometheus: ${RED}INACTIVE${NC}"
    fi
    
    # Grafana
    if is_container_running "grafana_pg"; then
        echo -e "   Grafana: ${GREEN}ACTIVE${NC} - http://localhost:3000 (admin/admin)"
    else
        echo -e "   Grafana: ${RED}INACTIVE${NC}"
    fi
    
    # Postgres Exporter
    if is_container_running "postgres_exporter"; then
        echo -e "   Postgres Exporter: ${GREEN}ACTIVE${NC} - http://localhost:9187"
    else
        echo -e "   Postgres Exporter: ${RED}INACTIVE${NC}"
    fi
    
    # Node Exporter
    if is_container_running "node_exporter"; then
        echo -e "   Node Exporter: ${GREEN}ACTIVE${NC} - http://localhost:9100"
    else
        echo -e "   Node Exporter: ${RED}INACTIVE${NC}"
    fi
}

# ================================================================================
# OPERATION FUNCTIONS
# ================================================================================

# Start environment
start_environment() {
    echo -e "\n${PURPLE}STARTING POSTGRESQL ENVIRONMENT${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    log "INFO" "Starting containers with docker-compose..."
    
    if docker-compose up -d; then
        log "INFO" "Containers started successfully!"
        
        # Wait for PostgreSQL
        if wait_for_postgres; then
            echo -e "\n${GREEN}PostgreSQL environment started successfully!${NC}"
            echo -e "\nTo connect to the database:"
            echo -e "   docker exec -it pg_standard psql -U postgres -d ${DATABASE_NAME}"
        fi
    else
        log "ERROR" "Failed to start containers"
        return 1
    fi
}

# Stop environment
stop_environment() {
    echo -e "\n${PURPLE}STOPPING ENVIRONMENT${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    log "INFO" "Stopping all containers..."
    
    if docker-compose down; then
        log "INFO" "Environment stopped successfully!"
    else
        log "ERROR" "Failed to stop containers"
        return 1
    fi
}

# Clean environment completely
cleanup_environment() {
    echo -e "\n${PURPLE}COMPLETE ENVIRONMENT CLEANUP${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    read -p "WARNING: This will remove ALL data. Confirm? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Stopping and removing containers and volumes..."
        
        docker-compose down -v 2>/dev/null || true
        
        log "INFO" "Cleanup completed!"
    else
        log "INFO" "Operation cancelled"
    fi
}

# Setup database schema
setup_database() {
    echo -e "\n${PURPLE}SETTING UP DATABASE${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "PostgreSQL is not running. Execute 'start' first."
        return 1
    fi
    
    log "INFO" "Creating database ${DATABASE_NAME}..."
    
    # Create database if it doesn't exist
    docker exec pg_standard psql -U postgres -c "CREATE DATABASE ${DATABASE_NAME}" 2>/dev/null || log "INFO" "Database already exists"
    
    log "INFO" "Running schema script..."
    
        # Execute schema script
    if [ -f "schema.sql" ]; then
        docker exec -i pg_standard psql -U postgres -d "${DATABASE_NAME}" < schema.sql
        log "INFO" "Schema created successfully!"
    else
        log "ERROR" "schema.sql file not found"
        return 1
    fi
}

# Load data
load_data() {
    echo -e "\n${PURPLE}LOADING DATA${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "PostgreSQL is not running. Execute 'start' first."
        return 1
    fi
    
    # Check if database and tables exist
    local db_exists=$(docker exec pg_standard psql -U postgres -t -c "SELECT 1 FROM pg_database WHERE datname='${DATABASE_NAME}'" 2>/dev/null | grep -c "1" || echo "0")
    
    if [ "$db_exists" = "0" ]; then
        log "ERROR" "Database ${DATABASE_NAME} does not exist. Execute 'setup' first."
        return 1
    fi
    
    if [ -f "load_data.sh" ]; then
        log "INFO" "Running data loading..."
        bash load_data.sh "${DATABASE_NAME}"
        log "INFO" "Data loaded successfully!"
    else
        log "ERROR" "load_data.sh script not found"
        return 1
    fi
}

# Run benchmark
run_benchmark() {
    echo -e "\n${PURPLE}RUNNING BENCHMARK${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "PostgreSQL is not running. Execute 'start' first."
        return 1
    fi
    
    if [ -f "pgbench.sh" ]; then
        log "INFO" "Starting professional benchmark..."
        bash pgbench.sh
        log "INFO" "Benchmark completed! Check results in benchmark/"
    else
        log "ERROR" "pgbench.sh script not found"
        return 1
    fi
}

# ================================================================================
# MAIN MENU
# ================================================================================

show_main_menu() {
    clear
    echo -e "${BLUE}"
    echo "================================================================================"
    echo "                         POSTGRESQL Monolithic Database"
    echo "                             Bachelor's Thesis Project"
    echo "================================================================================"
    echo -e "${NC}"
    
    show_containers_status
    show_database_status
    show_monitoring_status
    
    echo -e "\n${YELLOW}AVAILABLE OPERATIONS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo -e "${YELLOW}[1]${NC} Start Environment    - Initialize complete PostgreSQL stack"
    echo -e "${YELLOW}[2]${NC} Setup Database       - Create database schema and tables"
    echo -e "${YELLOW}[3]${NC} Load Data           - Import CSV seed data"
    echo -e "${YELLOW}[4]${NC} Run Benchmark       - Execute performance tests"
    echo -e "${YELLOW}[5]${NC} Stop Environment    - Graceful shutdown"
    echo -e "${YELLOW}[6]${NC} Cleanup             - Complete environment reset"
    echo -e "${YELLOW}[7]${NC} View Logs           - Container log inspection"
    echo -e "${YELLOW}[8]${NC} SQL Console         - Direct PostgreSQL connection"
    echo -e "${YELLOW}[r]${NC} Refresh Status      - Update dashboard"
    echo -e "${YELLOW}[q]${NC} Exit"
    
    echo -e "\n────────────────────────────────────────────────────────────────"
}

# View container logs
show_logs() {
    echo -e "\n${PURPLE}CONTAINER LOGS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    echo -e "Choose container:"
    echo -e "${YELLOW}[1]${NC} pg_standard (PostgreSQL)"
    echo -e "${YELLOW}[2]${NC} prometheus_pg"
    echo -e "${YELLOW}[3]${NC} grafana_pg"
    echo -e "${YELLOW}[4]${NC} postgres_exporter"
    
    read -p "Option (1-4): " -n 1 -r
    echo
    
    case $REPLY in
        1) docker logs --tail 50 pg_standard ;;
        2) docker logs --tail 50 prometheus_pg ;;
        3) docker logs --tail 50 grafana_pg ;;
        4) docker logs --tail 50 postgres_exporter ;;
        *) log "ERROR" "Invalid option" ;;
    esac
    
    read -p "Press Enter to continue..."
}

# Connect to PostgreSQL
connect_to_postgres() {
    echo -e "\n${PURPLE}CONNECTING TO POSTGRESQL${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    if ! is_container_running "pg_standard"; then
        log "ERROR" "PostgreSQL is not running"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log "INFO" "Connecting to database ${DATABASE_NAME}..."
    docker exec -it pg_standard psql -U postgres -d "${DATABASE_NAME}"
}

# ================================================================================
# MAIN LOOP
# ================================================================================

main() {
    # Check if we are in the correct directory
    if [[ ! -f "docker-compose.yml" ]]; then
        log "ERROR" "docker-compose.yml file not found!"
        log "ERROR" "Run this script in the /postgre directory"
        exit 1
    fi
    
    # Main interactive menu loop
    while true; do
        show_main_menu
        
        echo -ne "\n${CYAN}Select an option [1-8,r,q]: ${NC}"
        read -r choice
        
        case $choice in
            "1"|"start")
                start_environment
                read -p "Press Enter to continue..."
                ;;
            "2"|"setup")
                setup_database
                read -p "Press Enter to continue..."
                ;;
            "3"|"load-data")
                load_data
                read -p "Press Enter to continue..."
                ;;
            "4"|"benchmark")
                run_benchmark
                read -p "Press Enter to continue..."
                ;;
            "5"|"stop")
                stop_environment
                read -p "Press Enter to continue..."
                ;;
            "6"|"cleanup")
                cleanup_environment
                read -p "Press Enter to continue..."
                ;;
            "7"|"logs")
                show_logs
                ;;
            "8"|"connect")
                connect_to_postgres
                ;;
            "r"|"refresh")
                # Just refresh the menu
                ;;
            "q"|"quit")
                echo -e "\n${GREEN}Thank you for using PostgreSQL Baseline Laboratory!${NC}"
                echo -e "${CYAN}Bachelor's Thesis Project - Monolithic Database Benchmark${NC}"
                exit 0
                ;;
            "")
                # Empty enter just refreshes
                ;;
            *)
                log "ERROR" "Invalid option: $choice"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Check if called with parameter (non-interactive mode)
if [ $# -gt 0 ]; then
    case "$1" in
        "start") start_environment ;;
        "setup") setup_database ;;
        "load-data") load_data ;;
        "benchmark") run_benchmark ;;
        "stop") stop_environment ;;
        "cleanup") cleanup_environment ;;
        "status") 
            show_containers_status
            show_database_status
            show_monitoring_status
            ;;
        *)
            echo "Usage: $0 [start|setup|load-data|benchmark|stop|cleanup|status]"
            echo "Or run without parameters for interactive mode"
            exit 1
            ;;
    esac
else
    # Interactive mode
    main
fi