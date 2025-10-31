#!/bin/bash

# ================================================================================
#                    DISTRIBUTED SHARDING LABORATORY
#                      PostgreSQL + Citus + Patroni + etcd
#                         Bachelor's Thesis Project
# ================================================================================
#
# Interactive Dashboard - Laboratory Main Menu
# Objective: Control interface for navigation between experimental modules

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration - Adapted to support both architectures
COMPOSE_PROJECT_NAME="citus"
DB_NAME="citus_platform"

# Function to detect active architecture
detect_architecture() {
    # Check if there are Patroni containers running
    if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$"; then
        echo "patroni"
    # Check if there are simple architecture containers
    elif docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$"; then
        echo "simple"
    else
        echo "none"
    fi
}

# Function to detect coordinator leader in Patroni architecture
detect_leader_coordinator() {
    for i in 1 2 3; do
        local container="citus_coordinator$i"
        if docker ps --format "{{.Names}}" | grep -q "^$container$"; then
            # Check if it's the leader via Patroni API
            local role=$(docker exec "$container" curl -s http://localhost:8008/ 2>/dev/null | grep -o '"role":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            if [[ "$role" == "master" ]]; then
                echo "$container"
                return
            fi
        fi
    done
    # Fallback: return first available coordinator
    echo "citus_coordinator1"
}

# Function to get coordinator container based on architecture
get_coordinator_container() {
    local arch=$(detect_architecture)
    case $arch in
        "patroni")
            detect_leader_coordinator
            ;;
        "simple")
            echo "citus_coordinator"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to clear screen
clear_screen() {
    clear
    echo -e "${BLUE}"
    echo "================================================================================"
    echo "                    DISTRIBUTED SHARDING LABORATORY"
    echo "                      PostgreSQL + Citus + Patroni + etcd"
    echo "                         Bachelor's Thesis Project"
    echo "================================================================================"
    echo -e "${NC}"
    echo
}

# Function to show cluster status
show_cluster_status() {
    echo -e "${CYAN}CLUSTER STATUS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    # Detectar arquitetura ativa
    local arch=$(detect_architecture)
    local coordinator_container=$(get_coordinator_container)
    
    # Check if there are containers running
    CLUSTER_RUNNING=$(docker ps --format "{{.Names}}" | grep "^citus_" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    
    if [ "$CLUSTER_RUNNING" -gt 0 ]; then
        case $arch in
            "patroni")
                echo -e "${GREEN}CLUSTER: ACTIVE (${CLUSTER_RUNNING} containers) - PATRONI Architecture${NC}"
                show_patroni_status
                ;;
            "simple")
                echo -e "${GREEN}CLUSTER: ACTIVE (${CLUSTER_RUNNING} containers) - SIMPLE Architecture${NC}"
                show_simple_status
                ;;
            *)
                echo -e "${YELLOW}CLUSTER: PARTIAL (${CLUSTER_RUNNING} containers) - UNKNOWN Architecture${NC}"
                ;;
        esac
        
        # PostgreSQL and Citus status (common for both architectures)
        show_postgresql_status "$coordinator_container"
        show_monitoring_status "$arch"
        
    else
        echo -e "${RED}CLUSTER: INACTIVE${NC}"
        echo -e "${YELLOW}Run the Simple Setup module to initialize the environment${NC}"
    fi
    echo
}

# Function to show Patroni architecture status
show_patroni_status() {
    echo
    
    # === ETCD CONSENSUS CLUSTER ===
    echo -e "${PURPLE}ETCD Consensus Cluster (Raft Algorithm):${NC}"
    etcd1_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd1$" && echo "ACTIVE" || echo "INACTIVE")
    etcd2_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd2$" && echo "ACTIVE" || echo "INACTIVE")
    etcd3_status=$(docker ps --format "{{.Names}}" | grep "^citus_etcd3$" && echo "ACTIVE" || echo "INACTIVE")
    echo "  - etcd1: citus_etcd1
$etcd1_status"
    echo "  - etcd2: citus_etcd2
$etcd2_status"
    echo "  - etcd3: citus_etcd3
$etcd3_status"
    
    # === COORDINATORS PATRONI HA ===
    echo
    echo -e "${BLUE}Coordinators (High Availability with Patroni):${NC}"
    
    # Check which one is the leader using Patroni API
    coord1_role="REPLICA"
    coord2_role="REPLICA"
    coord3_role="REPLICA"
    
    # Check coordinator1
    if docker exec citus_coordinator1 curl -s localhost:8008/ 2>/dev/null | grep -q '"role": "master"'; then
        coord1_role="LEADER"
    fi
    
    # Check coordinator2  
    if docker exec citus_coordinator2 curl -s localhost:8008/ 2>/dev/null | grep -q '"role": "master"'; then
        coord2_role="LEADER"
    fi
    
    # Check coordinator3
    if docker exec citus_coordinator3 curl -s localhost:8008/ 2>/dev/null | grep -q '"role": "master"'; then
        coord3_role="LEADER"
    fi
    
    coord1_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$" && echo "ACTIVE" || echo "INACTIVE")
    coord2_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator2$" && echo "ACTIVE" || echo "INACTIVE")
    coord3_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator3$" && echo "ACTIVE" || echo "INACTIVE")
    
    echo "  - coordinator1: $coord1_role - $coord1_status"
    echo "  - coordinator2: $coord2_role - $coord2_status"  
    echo "  - coordinator3: $coord3_role - $coord3_status"
    
    # === WORKERS PATRONI HA ===
    echo
    echo -e "${YELLOW}Workers (High Availability with Patroni):${NC}"
    echo "  Group 1:"
    worker1p_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1_primary$" && echo "ACTIVE" || echo "INACTIVE")
    worker1s_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1_standby$" && echo "ACTIVE" || echo "INACTIVE")
    echo "    - worker1_primary: $worker1p_status"
    echo "    - worker1_standby: $worker1s_status"
    echo "  Group 2:"
    worker2p_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2_primary$" && echo "ACTIVE" || echo "INACTIVE")
    worker2s_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2_standby$" && echo "ACTIVE" || echo "INACTIVE")
    echo "    - worker2_primary: $worker2p_status"
    echo "    - worker2_standby: $worker2s_status"
}

# Function to show simple architecture status
show_simple_status() {
    echo
    
    # === SIMPLE COORDINATOR ===
    echo -e "${BLUE}Coordinator (Minimal Version):${NC}"
    coord_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$" && echo "ACTIVE" || echo "INACTIVE")
    echo "  - coordinator: $coord_status"
    
    # === SIMPLE WORKERS ===
    echo
    echo -e "${YELLOW}Workers (No Replication):${NC}"
    worker1_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker1$" && echo "ACTIVE" || echo "INACTIVE")
    worker2_status=$(docker ps --format "{{.Names}}" | grep -q "^citus_worker2$" && echo "ACTIVE" || echo "INACTIVE")
    echo "  - worker1: $worker1_status"
    echo "  - worker2: $worker2_status"
}

# Function to show PostgreSQL status (common for both architectures)
show_postgresql_status() {
    local coordinator_container="$1"
    
    echo
    if [[ -n "$coordinator_container" ]] && docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}PostgreSQL: OPERATIONAL${NC}"
        
        # Check database first
        if docker exec -i "$coordinator_container" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
            echo -e "${GREEN}Database: $DB_NAME ACTIVE${NC}"
            
            # Check workers registered in Citus
            worker_count=$(docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" 2>/dev/null | xargs 2>/dev/null || echo "0")
            echo -e "${GREEN}Citus Workers: $worker_count active${NC}"
            
            # Check tables (excluding Citus system views)
            table_count=$(docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' AND table_name NOT LIKE 'citus_%';" 2>/dev/null | xargs 2>/dev/null || echo "0")
            echo -e "${GREEN}Data tables: $table_count created${NC}"
        else
            echo -e "${YELLOW}Database: Waiting for creation${NC}"
        fi
    else
        echo -e "${RED}PostgreSQL: NOT RESPONSIVE${NC}"
    fi
}

# Function to show monitoring status (adapted for both architectures)
show_monitoring_status() {
    local arch="$1"
    
    echo
    echo -e "${CYAN}Monitoring Tools:${NC}"
    
    # Prometheus (different names per architecture)
    if [[ "$arch" == "patroni" ]]; then
        prometheus_running=$(docker ps --format "{{.Names}}" | grep "citus_prometheus_patroni" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    else
        prometheus_running=$(docker ps --format "{{.Names}}" | grep "citus_prometheus" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    fi
    
    if [ "$prometheus_running" -gt 0 ]; then
        echo -e "${GREEN}  - Prometheus: ACTIVE (http://localhost:9090)${NC}"
    else
        echo -e "${YELLOW}  - Prometheus: UNAVAILABLE${NC}"
    fi
    
    # Grafana (different names per architecture)
    if [[ "$arch" == "patroni" ]]; then
        grafana_running=$(docker ps --format "{{.Names}}" | grep "citus_grafana_patroni" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    else
        grafana_running=$(docker ps --format "{{.Names}}" | grep "citus_grafana" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    fi
    
    if [ "$grafana_running" -gt 0 ]; then
        echo -e "${GREEN}  - Grafana: ACTIVE (http://localhost:3000)${NC}"
    else
        echo -e "${YELLOW}  - Grafana: UNAVAILABLE${NC}"
    fi
    
    # HAProxy
    haproxy_running=$(docker ps --format "{{.Names}}" | grep "haproxy" 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    if [ "$haproxy_running" -gt 0 ]; then
        echo -e "${GREEN}  - HAProxy: ACTIVE (http://localhost:5432)${NC}"
    else
        echo -e "${YELLOW}  - HAProxy: UNAVAILABLE${NC}"
    fi
}

# Function to show quick statistics
show_quick_stats() {
    local coordinator_container=$(get_coordinator_container)
    
    # Check if coordinator is running
    if [[ -z "$coordinator_container" ]] || ! docker ps --format "{{.Names}}" | grep -q "^${coordinator_container}$"; then
        return
    fi
    
    # Check if PostgreSQL is responding
    if ! docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        return
    fi
    
    # Check if database exists
    if ! docker exec -i "$coordinator_container" psql -U postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        return
    fi
    
    echo -e "${CYAN}DATABASE STATISTICS${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    # Try to get statistics
    if docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        'Companies'::text as item,
        COUNT(*)::text as count
    FROM companies
    UNION ALL
    SELECT 
        'Campaigns',
        COUNT(*)::text
    FROM campaigns
    UNION ALL
    SELECT 
        'Ads',
        COUNT(*)::text  
    FROM ads;
    " 2>/dev/null; then
        echo
    else
        echo "Data not yet loaded"
        echo
    fi
}

# Main menu function
show_menu() {
    clear_screen
    show_cluster_status
    show_quick_stats
    
    echo -e "${BLUE}AVAILABLE MODULES${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    echo -e "${YELLOW}[1]${NC} Simple Setup (Basic)    - Configure simple cluster"
    echo -e "${YELLOW}[2]${NC} Simple Setup (Patroni)  - Configure cluster with Patroni + etcd"
    echo -e "${YELLOW}[3]${NC} HA & Failover           - High availability and recovery"
    echo -e "${YELLOW}[4]${NC} Schema Manager          - Create custom schemas"
    echo
    echo -e "${PURPLE}UTILITIES${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo -e "${YELLOW}[5]${NC} SQL Console             - Connect directly to cluster"
    echo -e "${YELLOW}[6]${NC} Cluster Monitor         - View real-time metrics"
    echo -e "${YELLOW}[0]${NC} Cleanup                 - Stop and clean environment"
    echo
    echo -e "${RED}[q]${NC} Exit"
    echo
    echo -n -e "${CYAN}Select an option [0-7,q]: ${NC}"
}

# Function for Schema Manager
schema_manager_menu() {
    clear_screen
    echo -e "${PURPLE}SCHEMA MANAGER${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    echo -e "${CYAN}Available Features:${NC}"
    echo "[1] List available scenarios"
    echo "[2] Create complete schema"
    echo "[3] Generate sample data"
    echo "[4] Load data into database" 
    echo "[5] Complete process (schema + data)"
    echo "[0] Back"
    echo
    echo -n -e "${CYAN}Choose an option [0-5]: ${NC}"
    read -r schema_choice
    
    case $schema_choice in
        1)
            echo -e "${CYAN}📋 Available scenarios:${NC}"
            ./scripts/schema_manager.sh list
            echo
            echo "Press Enter to continue..."
            read -r
            ;;
        2)
            echo -e "${CYAN}🏗️ Create schema:${NC}"
            ./scripts/schema_manager.sh interactive
            echo
            echo "Press Enter to continue..."
            read -r
            ;;
        3)
            echo -n -e "${CYAN}Enter scenario to generate data: ${NC}"
            read -r scenario
            if [[ -n "$scenario" ]]; then
                ./scripts/data_loader.sh generate "$scenario"
            fi
            echo
            echo "Press Enter to continue..."
            read -r
            ;;
        4)
            echo -n -e "${CYAN}Enter scenario to load data: ${NC}"
            read -r scenario
            if [[ -n "$scenario" ]]; then
                ./scripts/data_loader.sh load "$scenario"
            fi
            echo
            echo "Press Enter to continue..."
            read -r
            ;;
        5)
            echo -n -e "${CYAN}Enter scenario for complete process: ${NC}"
            read -r scenario
            if [[ -n "$scenario" ]]; then
                echo -e "${YELLOW}🚀 Running complete process...${NC}"
                ./scripts/schema_manager.sh create "$scenario"
                ./scripts/data_loader.sh full "$scenario"
            fi
            echo
            echo "Press Enter to continue..."
            read -r
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}❌ Invalid option!${NC}"
            sleep 1
            schema_manager_menu
            ;;
    esac
    
    # Recursive to keep menu active
    if [[ "$schema_choice" != "0" ]]; then
        schema_manager_menu
    fi
}

# Function for SQL console
sql_console() {
    clear_screen
    echo -e "${PURPLE}CONSOLE SQL INTERATIVO${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    # Basic checks
    if ! docker ps > /dev/null 2>&1; then
        echo -e "${RED}Docker is not running!${NC}"
        echo "Start Docker Desktop first."
        echo
        echo "Press Enter to go back..."
        read -r
        return
    fi
    
    local coordinator_container=$(get_coordinator_container)
    if [[ -z "$coordinator_container" ]]; then
        echo -e "${RED}Cluster is not running!${NC}"
        echo "Run the Simple Setup module first."
        echo
        echo "Press Enter to go back..."
        read -r
        return
    fi
    
    if ! docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}PostgreSQL is not responding!${NC}"
        echo "Wait a few seconds and try again."
        echo
        echo "Press Enter to go back..."
        read -r
        return
    fi
    
    echo -e "${GREEN}PostgreSQL is running!${NC}"
    echo -e "${CYAN}Connecting to PostgreSQL console (database: $DB_NAME)...${NC}"
    echo -e "${YELLOW}To exit, type \\q and press Enter${NC}"
    echo
    
    # Conectar diretamente ao PostgreSQL
    docker exec -it "$coordinator_container" psql -U postgres -d "$DB_NAME"
    
    # Message after exiting psql
    echo
    echo -e "${GREEN}SQL session ended${NC}"
    echo -e "${CYAN}Press Enter to return to menu...${NC}"
    read -r
}

# Function for monitoring
cluster_monitor() {
    clear_screen
    echo -e "${PURPLE}MONITOR DO CLUSTER${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    local coordinator_container=$(get_coordinator_container)
    if [[ -z "$coordinator_container" ]] || ! docker exec "$coordinator_container" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${RED}Cluster is not running!${NC}"
        echo
        echo "Press Enter to go back..."
        read -r
        return
    fi
    
    echo -e "${CYAN}Shard Distribution:${NC}"
    docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        n.nodename,
        n.nodeport,
        COUNT(p.shardid) as shard_count,
        ROUND(COUNT(p.shardid) * 100.0 / SUM(COUNT(p.shardid)) OVER(), 1) as percentage
    FROM pg_dist_node n
    LEFT JOIN pg_dist_shard_placement p ON n.groupid = p.groupid
    WHERE n.noderole = 'primary'
    GROUP BY n.groupid, n.nodename, n.nodeport
    ORDER BY shard_count DESC;
    "
    
    echo
    echo -e "${CYAN}Table Sizes:${NC}"
    docker exec -i "$coordinator_container" psql -U postgres -d "$DB_NAME" -c "
    SELECT 
        schemaname, 
        tablename, 
        pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
    FROM pg_tables 
    WHERE schemaname = 'public'
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
    "
    
    echo
    echo -e "${CYAN}Monitoring Links:${NC}"
    echo "- Grafana: http://localhost:3000"
    echo "- Prometheus: http://localhost:9090"
    echo "- Postgres Metrics: http://localhost:9187/metrics"
    echo
    echo "Press Enter to go back..."
    read -r
}

# Function for cleanup
cleanup_environment() {
    clear_screen
    echo -e "${PURPLE}LIMPEZA DO AMBIENTE${NC}"
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo
    
    echo -e "${YELLOW}WARNING: This operation will:${NC}"
    echo "- Stop all containers"
    echo "- Remove data volumes"
    echo "- Clean configurations"
    echo
    echo -n "Do you want to continue? [y/N]: "
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo
        echo -e "${CYAN}Stopping containers...${NC}"
        
        # Stop both architectures
        docker-compose -f docker-compose-patroni.yml down -v 2>/dev/null || true
        docker-compose down -v 2>/dev/null || true
        
        echo -e "${CYAN}Cleaning orphaned volumes...${NC}"
        docker volume prune -f
        
        echo -e "${GREEN}Environment cleaned successfully!${NC}"
    else
        echo -e "${YELLOW}Operation cancelled.${NC}"
    fi
    
    echo
    echo "Press Enter to go back..."
    read -r
}

# Help function
show_help() {
    clear_screen
    echo -e "${PURPLE}❓ HELP AND DOCUMENTATION${NC}"
    echo "═══════════════════════"
    echo
    echo -e "${CYAN}📚 Recommended Order:${NC}"
    echo "1. Simple Setup - Configure o ambiente (ou use Schema Manager)"
    echo "2. Schema Manager - Crie schemas personalizados"

    echo "4. HA & Failover - Alta disponibilidade"
    echo
    echo -e "${CYAN}🛠️  Prerequisites:${NC}"
    echo "• Docker & Docker Compose installed"
    echo "• 8GB+ RAM available"
    echo "• Free ports: 5432, 3000, 9090, 9187, 9100"
    echo
    echo -e "${CYAN}🔗 Useful Links:${NC}"
    echo "• README.md - Complete documentation"
    echo "• Citus Docs: https://docs.citusdata.com/"
    echo "• PostgreSQL: https://www.postgresql.org/docs/"
    echo
    echo -e "${CYAN}🐛 Troubleshooting:${NC}"
    echo "• If ports are busy: docker-compose down"
    echo "• If memory is low: close other applications"
    echo "• For complete reset: use the Cleanup option"
    echo
    echo "Pressione Enter para voltar..."
    read -r
}

# Loop principal
main() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                echo -e "${CYAN}Running Simple Setup (Basic)...${NC}"
                echo -e "${YELLOW}Starting cluster with simple architecture${NC}"
                # Check if there's already a Patroni cluster running
                if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator1$"; then
                    echo -e "${RED}WARNING: Patroni cluster detected! Do cleanup first.${NC}"
                    echo "Press Enter to continue..."
                    read -r
                    return
                fi
                
                echo -e "${CYAN}Starting containers...${NC}"
                docker-compose up -d
                
                echo -e "${CYAN}Waiting for PostgreSQL to initialize...${NC}"
                sleep 10
                
                # Wait for coordinator to be ready
                echo -e "${CYAN}Checking if coordinator is ready...${NC}"
                for i in {1..30}; do
                    if docker exec citus_coordinator pg_isready -U postgres > /dev/null 2>&1; then
                        echo -e "${GREEN}Coordinator is ready!${NC}"
                        break
                    fi
                    echo "Waiting... ($i/30)"
                    sleep 2
                done
                
                # Register workers in Citus
                echo -e "${CYAN}Registering workers in Citus...${NC}"
                
                # Wait for workers to be ready
                sleep 5
                
                # Register worker 1
                echo "Registering worker1..."
                docker exec citus_coordinator psql -U postgres -d citus_platform -c "SELECT citus_add_node('worker1', 5432);" 2>/dev/null || echo "Worker1 already registered or error"
                
                # Register worker 2
                echo "Registering worker2..."
                docker exec citus_coordinator psql -U postgres -d citus_platform -c "SELECT citus_add_node('worker2', 5432);" 2>/dev/null || echo "Worker2 already registered or error"
                
                # Check registered workers
                echo -e "${CYAN}Checking registered workers:${NC}"
                docker exec citus_coordinator psql -U postgres -d citus_platform -c "SELECT * FROM citus_get_active_worker_nodes();"
                
                echo -e "${GREEN}Simple setup completed!${NC}"
                echo "Press Enter to continue..."
                read -r
                ;;
            2)
                echo -e "${CYAN}Running Simple Setup (Patroni)...${NC}"
                echo -e "${YELLOW}Starting cluster with Patroni + etcd${NC}"
                # Check if there's already a simple cluster running
                if docker ps --format "{{.Names}}" | grep -q "^citus_coordinator$"; then
                    echo -e "${RED}WARNING: Simple cluster detected! Do cleanup first.${NC}"
                    echo "Press Enter to continue..."
                    read -r
                    return
                fi
                ./02_simple_setup.sh
                ;;
            3)
                echo -e "${CYAN}Running HA & Failover...${NC}"
                ./ha_comparison.sh
                ;;
            4)
                schema_manager_menu
                ;;
            5)
                sql_console
                clear
                ;;
            6)
                cluster_monitor
                clear
                ;;
            0)
                cleanup_environment
                clear
                ;;
            q|Q|quit|exit)
                echo -e "${GREEN}Thank you for using the laboratory!${NC}"
                echo -e "${CYAN}Bachelor's Thesis Project completed.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Try again.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Check if we're in the correct directory
if [[ ! -f "docker-compose-patroni.yml" ]]; then
    echo -e "${RED}ERROR: Run this script from the citus directory${NC}"
    echo -e "${YELLOW}Make sure the docker-compose-patroni.yml file exists${NC}"
    exit 1
fi

# Run main menu
main
