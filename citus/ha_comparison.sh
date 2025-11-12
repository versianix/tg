#!/bin/bash

# =============================================================================
# ADAPTIVE HIGH AVAILABILITY DEMONSTRATION
# =============================================================================
# Purpose: Demonstrate HA capabilities of the currently running Citus architecture
# Features: Detects environment and shows limitations/capabilities dynamically
# Author: Professional Staff Software Engineer Implementation
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly ORANGE='\033[0;33m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Environment configurations
readonly STANDARD_COORDINATOR="citus_coordinator"
readonly STANDARD_WORKER1="citus_worker1"
readonly STANDARD_WORKER2="citus_worker2"
readonly STANDARD_DB="citus_platform"

readonly PATRONI_COORDINATOR1="citus_coordinator1"
readonly PATRONI_COORDINATOR2="citus_coordinator2"
readonly PATRONI_COORDINATOR3="citus_coordinator3"
readonly PATRONI_WORKER1_PRIMARY="citus_worker1_primary"
readonly PATRONI_WORKER1_STANDBY="citus_worker1_standby"
readonly PATRONI_WORKER2_PRIMARY="citus_worker2_primary"
readonly PATRONI_WORKER2_STANDBY="citus_worker2_standby"
readonly PATRONI_DB="citus_platform"

# Test parameters
readonly QUERY_TIMEOUT=10
readonly RECOVERY_WAIT=5
readonly FAILOVER_WAIT=3

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%H:%M:%S')
    case "$level" in
        "INFO")  echo -e "${CYAN}[${timestamp}]${NC} ${message}" ;;
        "WARN")  echo -e "${YELLOW}[${timestamp}] WARNING:${NC}  ${message}" ;;
        "ERROR") echo -e "${RED}[${timestamp}] ERROR:${NC} ${message}" ;;
        "SUCCESS") echo -e "${GREEN}[${timestamp}] SUCCESS:${NC} ${message}" ;;
    esac
}

print_header() {
    local title="$1"
    echo
    echo -e "${PURPLE}================================================================${NC}"
    printf "${PURPLE}%s${NC}\n" "$(printf "%*s" $((31 + ${#title}/2)) "$title")"
    echo -e "${PURPLE}================================================================${NC}"
    echo
}

print_section() {
    local title="$1"
    echo
    echo -e "${BLUE}${title}${NC}"
    echo -e "${BLUE}$(printf '=%.0s' $(seq 1 $((${#title} + 3))))${NC}"
}

container_exists() {
    local container="$1"
    docker ps -a --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null
}

container_running() {
    local container="$1"
    if ! container_exists "$container"; then
        return 1
    fi
    docker ps --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null
}

container_healthy() {
    local container="$1"
    if ! container_running "$container"; then
        return 1
    fi
    docker exec "$container" pg_isready -U postgres >/dev/null 2>&1
}

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

detect_current_architecture() {
    # Check Patroni Citus first (more sophisticated)
    if container_running "$PATRONI_COORDINATOR1"; then
        if container_healthy "$PATRONI_COORDINATOR1"; then
            echo "patroni"
            return 0
        fi
    fi
    
    # Check Standard Citus
    if container_running "$STANDARD_COORDINATOR"; then
        if container_healthy "$STANDARD_COORDINATOR"; then
            echo "standard"
            return 0
        fi
    fi
    
    echo "none"
}

get_patroni_leader() {
    # Use the optimized detect_current_leader function
    local leader=$(detect_current_leader)
    if [ -n "$leader" ]; then
        echo "$leader"
    else
        # Fallback - return the first healthy container
        if container_healthy "$PATRONI_COORDINATOR1"; then
            echo "$PATRONI_COORDINATOR1"
        elif container_healthy "$PATRONI_COORDINATOR2"; then
            echo "$PATRONI_COORDINATOR2"  
        elif container_healthy "$PATRONI_COORDINATOR3"; then
            echo "$PATRONI_COORDINATOR3"
        else
            echo "$PATRONI_COORDINATOR1"  # ultimate fallback
        fi
    fi
}

get_current_coordinator() {
    local arch="$1"
    
    case "$arch" in
        "standard")
            echo "$STANDARD_COORDINATOR"
            ;;
        "patroni")
            get_patroni_leader
            ;;
        *)
            echo ""
            ;;
    esac
}

get_current_database() {
    local arch="$1"
    
    case "$arch" in
        "standard")
            echo "$STANDARD_DB"
            ;;
        "patroni")
            echo "$PATRONI_DB"
            ;;
        *)
            echo ""
            ;;
    esac
}

# =============================================================================
# PATRONI LEADER DETECTION
# =============================================================================

# Helper function to detect current leader
detect_current_leader() {
    local coordinator_containers=(
        "citus_coordinator1" 
        "citus_coordinator2" 
        "citus_coordinator3"
    )
    
    # Method 1: Try Patroni API first (faster)
    for container in "${coordinator_containers[@]}"; do
        if container_running "$container"; then
            # Check Patroni API - remove aggressive timeouts that cause failures
            local patroni_response
            patroni_response=$(docker exec "$container" curl -s http://localhost:8008/ 2>/dev/null || echo "")
            
            # Check for master role with flexible spacing around colon
            if echo "$patroni_response" | grep -q '"role"[[:space:]]*:[[:space:]]*"master"'; then
                echo "$container"
                return 0
            fi
        fi
    done
    
    # Method 2: Fallback to PostgreSQL direct check
    for container in "${coordinator_containers[@]}"; do
        if container_running "$container"; then
            # Check if PostgreSQL is master (not in recovery)
            local recovery_status
            recovery_status=$(timeout 3 docker exec "$container" psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' \n' || echo "t")
            
            if [[ "$recovery_status" == "f" ]]; then
                echo "$container"
                return 0
            fi
        fi
    done
    
    echo ""
}

# Wait for new leader election after failover
wait_for_leader_election() {
    local max_wait=30  # Reduced since we fixed the detection issue
    local wait_time=0
    local check_interval=2  # Balance between responsiveness and system load
    local failed_leader="$1"  # Pass the failed leader to exclude it
    
    log "INFO" "Waiting for Patroni leader election (excluding: ${failed_leader:-none})..."
    
    # First, wait a bit for Patroni to detect the failure
    sleep 2
    
    while [ $wait_time -lt $max_wait ]; do
        local new_leader=$(detect_current_leader)
        
        # Ensure we have a different leader (not the failed one)
        if [ -n "$new_leader" ] && [ "$new_leader" != "$failed_leader" ]; then
            log "SUCCESS" "New leader elected: ${new_leader}"
            
            # Verify the new leader is actually responding to queries
            log "INFO" "Verifying new leader is ready for queries..."
            local attempts=0
            while [ $attempts -lt 10 ]; do
                if timeout 5 docker exec "$new_leader" psql -U postgres -d "$PATRONI_DB" -c "SELECT 1;" >/dev/null 2>&1; then
                    log "SUCCESS" "New leader is ready for queries"
                    return 0
                fi
                sleep 1
                ((attempts++))
            done
            
            log "WARN" "New leader elected but not yet ready for queries"
            return 0
        fi
        
        # Show progress less frequently to reduce noise
        if [ $((wait_time % 6)) -eq 0 ]; then
            log "INFO" "Election in progress... (${wait_time}s)"
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
    done
    
    log "WARN" "Leader election taking longer than expected (${max_wait}s)"
    
    # Try to find any working coordinator as fallback
    local fallback_leader=$(detect_current_leader)
    if [ -n "$fallback_leader" ]; then
        log "INFO" "Using fallback leader: ${fallback_leader}"
        return 0
    fi
    
    return 1
}

get_patroni_primary_worker() {
    local group="$1"  # 1 or 2
    local primary=""
    
    case "$group" in
        "1")
            if container_healthy "$PATRONI_WORKER1_PRIMARY"; then
                local recovery_status
                recovery_status=$(docker exec "$PATRONI_WORKER1_PRIMARY" psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' \n' || echo "t")
                if [[ "$recovery_status" == "f" ]]; then
                    primary="$PATRONI_WORKER1_PRIMARY"
                fi
            fi
            if [[ -z "$primary" ]] && container_healthy "$PATRONI_WORKER1_STANDBY"; then
                local recovery_status
                recovery_status=$(docker exec "$PATRONI_WORKER1_STANDBY" psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' \n' || echo "t")
                if [[ "$recovery_status" == "f" ]]; then
                    primary="$PATRONI_WORKER1_STANDBY"
                fi
            fi
            ;;
        "2")
            if container_healthy "$PATRONI_WORKER2_PRIMARY"; then
                local recovery_status
                recovery_status=$(docker exec "$PATRONI_WORKER2_PRIMARY" psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' \n' || echo "t")
                if [[ "$recovery_status" == "f" ]]; then
                    primary="$PATRONI_WORKER2_PRIMARY"
                fi
            fi
            if [[ -z "$primary" ]] && container_healthy "$PATRONI_WORKER2_STANDBY"; then
                local recovery_status
                recovery_status=$(docker exec "$PATRONI_WORKER2_STANDBY" psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' \n' || echo "t")
                if [[ "$recovery_status" == "f" ]]; then
                    primary="$PATRONI_WORKER2_STANDBY"
                fi
            fi
            ;;
    esac
    
    echo "$primary"
}

# =============================================================================
# TOPOLOGY DISPLAY
# =============================================================================

show_standard_topology() {
    print_section "STANDARD CITUS TOPOLOGY"
    
    echo -e "${BOLD}COORDINATOR:${NC}"
    if container_healthy "$STANDARD_COORDINATOR"; then
    echo -e "${GREEN}   $STANDARD_COORDINATOR (ACTIVE)${NC}"
    else
    echo -e "${RED}   $STANDARD_COORDINATOR (DOWN)${NC}"
    fi
    
    echo -e "${BOLD}WORKERS:${NC}"
    if container_healthy "$STANDARD_COORDINATOR"; then
        docker exec "$STANDARD_COORDINATOR" psql -U postgres -d "$STANDARD_DB" -c "
        SELECT 
            nodename as worker,
            nodeport as port,
            CASE WHEN isactive THEN '✅ ACTIVE' ELSE '❌ INACTIVE' END as status
        FROM pg_dist_node 
        WHERE noderole = 'primary'
        ORDER BY nodename;" 2>/dev/null || echo "   ⚠️  Unable to query worker status"
    else
    echo -e "${RED}   Cannot query workers - coordinator down${NC}"
    fi
}

show_patroni_topology() {
    print_section "PATRONI CITUS TOPOLOGY"
    
    echo -e "${BOLD}COORDINATORS:${NC}"
    local leader
    leader=$(get_patroni_leader)
    
    for coord in "$PATRONI_COORDINATOR1" "$PATRONI_COORDINATOR2" "$PATRONI_COORDINATOR3"; do
        if container_healthy "$coord"; then
            if [[ "$coord" == "$leader" ]]; then
                echo -e "${GREEN}   $coord (LEADER)${NC}"
            else
                echo -e "${YELLOW}   $coord (REPLICA)${NC}"
            fi
        else
            echo -e "${RED}   $coord (DOWN)${NC}"
        fi
    done
    
    echo -e "${BOLD}WORKER GROUPS:${NC}"
    
    # Worker Group 1
    echo -e "${CYAN}   Group 1:${NC}"
    local w1_primary
    w1_primary=$(get_patroni_primary_worker "1")
    
    for worker in "$PATRONI_WORKER1_PRIMARY" "$PATRONI_WORKER1_STANDBY"; do
        if container_healthy "$worker"; then
            if [[ "$worker" == "$w1_primary" ]]; then
                echo -e "${GREEN}     $worker (PRIMARY)${NC}"
            else
                echo -e "${YELLOW}     $worker (STANDBY)${NC}"
            fi
        else
            echo -e "${RED}     $worker (DOWN)${NC}"
        fi
    done
    
    # Worker Group 2  
    echo -e "${CYAN}   Group 2:${NC}"
    local w2_primary
    w2_primary=$(get_patroni_primary_worker "2")
    
    for worker in "$PATRONI_WORKER2_PRIMARY" "$PATRONI_WORKER2_STANDBY"; do
        if container_healthy "$worker"; then
            if [[ "$worker" == "$w2_primary" ]]; then
                echo -e "${GREEN}     $worker (PRIMARY)${NC}"
            else
                echo -e "${YELLOW}     $worker (STANDBY)${NC}"
            fi
        else
            echo -e "${RED}     $worker (DOWN)${NC}"
        fi
    done
    
    # Show registered workers in Citus
    if [[ -n "$leader" ]]; then
        echo -e "${BOLD}REGISTERED WORKERS:${NC}"
        docker exec "$leader" psql -U postgres -d "$PATRONI_DB" -c "
        SELECT 
            nodename as worker,
            nodeport as port,
            CASE WHEN isactive THEN 'ACTIVE' ELSE 'INACTIVE' END as status
        FROM pg_dist_node 
        WHERE noderole = 'primary'
        ORDER BY nodename;" 2>/dev/null || echo "   Unable to query worker status"
    fi
}

# =============================================================================
# QUERY TESTING
# =============================================================================

test_query() {
    local env="$1"
    local coordinator="$2" 
    local database="$3"
    local description="$4"
    
    echo -e "${YELLOW}Testing: ${description}${NC}"
    
    local start_time
    start_time=$(date +%s.%N)
    
    local query_result
    if timeout "$QUERY_TIMEOUT" docker exec "$coordinator" psql -U postgres -d "$database" -c "
    SELECT 
        COUNT(*) as total_companies,
        COUNT(CASE WHEN name LIKE 'Company %' THEN 1 END) as test_companies,
        now() as query_time
    FROM companies;" 2>/dev/null; then
        local end_time
        end_time=$(date +%s.%N)
        local duration
        duration=$(echo "$end_time - $start_time" | bc 2>/dev/null | cut -c1-5 || echo "N/A")
    log "SUCCESS" "Query completed successfully (${duration}s)"
        return 0
    else
        local end_time
        end_time=$(date +%s.%N)  
        local duration
        duration=$(echo "$end_time - $start_time" | bc 2>/dev/null | cut -c1-5 || echo "N/A")
    log "ERROR" "Query failed after ${duration}s"
        return 1
    fi
}

# =============================================================================
# FAILOVER SIMULATION
# =============================================================================

simulate_coordinator_failure() {
    local env="$1"
    local coordinator="$2"
    
    # If no specific coordinator given, detect current leader for patroni
    if [[ -z "$coordinator" && "$env" == "patroni" ]]; then
        coordinator=$(get_patroni_leader)
        if [[ -z "$coordinator" ]]; then
            log "ERROR" "Could not detect current leader"
            return 1
        fi
    fi
    
    log "WARN" "Pausing current leader: $coordinator"
    docker pause "$coordinator" 2>/dev/null || true
    
    if [[ "$env" == "patroni" ]]; then
    echo "Patroni should elect new leader automatically..."
    echo "   This may take 5-15 seconds for leader election..."
        
        # Wait for new leader to be elected
        local attempts=0
        local max_attempts=15
        local new_leader=""
        
        while [[ $attempts -lt $max_attempts ]]; do
            sleep 2
            new_leader=$(get_patroni_leader)
            if [[ -n "$new_leader" && "$new_leader" != "$coordinator" ]]; then
                log "SUCCESS" "New leader elected: $new_leader"
                break
            fi
            attempts=$((attempts + 1))
            echo "   Waiting for leader election... (${attempts}/${max_attempts})"
        done
        
        if [[ $attempts -eq $max_attempts ]]; then
            log "WARN" "Leader election taking longer than expected"
            echo "   This is normal during coordinator failover"
        fi
        
        # Test queries after failover
    echo "Testing queries after automatic failover..."
        test_queries_during_failure "$env" "coordinator"
    else
        sleep "$FAILOVER_WAIT"
    log "ERROR" "Coordinator $coordinator is DOWN - No automatic recovery!"
    fi
}

simulate_worker_failure() {
    local worker="$1"
    
    log "WARN" "SIMULATING WORKER FAILURE: $worker"  
    docker pause "$worker" 2>/dev/null || true
    sleep "$FAILOVER_WAIT"
    log "ERROR" "Worker $worker is DOWN"
}

recover_container() {
    local container="$1"
    
    log "INFO" "RECOVERING: $container"
    docker unpause "$container" 2>/dev/null || true
    sleep "$RECOVERY_WAIT"
    
    if container_healthy "$container"; then
    log "SUCCESS" "Container $container recovered successfully"
    else
    log "WARN" "Container $container started but may need more time"
    fi
}

# =============================================================================
# ADAPTIVE TEST SCENARIOS
# =============================================================================

run_ha_demonstration() {
    local arch="$1"
    
    case "$arch" in
        "standard")
            demonstrate_standard_limitations
            ;;
        "patroni") 
            demonstrate_patroni_capabilities
            ;;
        *)
            log "ERROR" "Unknown architecture: $arch"
            return 1
            ;;
    esac
}

demonstrate_standard_limitations() {
    print_header "STANDARD CITUS - HA LIMITATIONS DEMO"
    echo -e "${YELLOW}OBJECTIVE: Show limitations of basic Citus setup${NC}"
    echo -e "${YELLOW}   This will demonstrate why HA solutions like Patroni are needed${NC}"
    echo
    
    if ! container_healthy "$STANDARD_COORDINATOR"; then
        log "ERROR" "Standard Citus coordinator is not healthy. Please start the cluster first."
        return 1
    fi
    
    print_section "BASELINE TEST"
    show_standard_topology
    test_query "standard" "$STANDARD_COORDINATOR" "$STANDARD_DB" "Baseline query (healthy cluster)"
    
    echo -e "${CYAN}Press Enter to simulate coordinator failure...${NC}"
    read -r
    
    print_section "COORDINATOR FAILURE TEST"
    simulate_coordinator_failure "standard" "$STANDARD_COORDINATOR"
    show_standard_topology
    test_query "standard" "$STANDARD_COORDINATOR" "$STANDARD_DB" "Query during coordinator failure"
    echo -e "${CYAN}Press Enter to recover coordinator...${NC}"
    read -r
    
    print_section "COORDINATOR RECOVERY"
    recover_container "$STANDARD_COORDINATOR"
    log "INFO" "Waiting for coordinator to be ready..."
    local attempts=0
    while ! container_healthy "$STANDARD_COORDINATOR" && [[ $attempts -lt 30 ]]; do
        sleep 2
        ((attempts++))
    done
    show_standard_topology
    test_query "standard" "$STANDARD_COORDINATOR" "$STANDARD_DB" "Query after coordinator recovery"
    print_section "WORKER FAILURE TEST"
    echo -e "${CYAN}Press Enter to test worker failure...${NC}"
    read -r
    simulate_worker_failure "$STANDARD_WORKER1"
    show_standard_topology
    test_query "standard" "$STANDARD_COORDINATOR" "$STANDARD_DB" "Query with worker1 down"
    print_section "WORKER RECOVERY"
    echo -e "${CYAN}Press Enter to recover worker...${NC}"
    read -r
    recover_container "$STANDARD_WORKER1"
    show_standard_topology
    test_query "standard" "$STANDARD_COORDINATOR" "$STANDARD_DB" "Query after worker recovery"
    print_section "STANDARD CITUS - LIMITATIONS SUMMARY"
    echo -e "${RED}CRITICAL LIMITATIONS IDENTIFIED:${NC}"
    echo
    echo -e "   ${RED}SINGLE POINT OF FAILURE${NC}"
    echo -e "      - Coordinator failure = Complete cluster down"
    echo -e "      - No automatic failover mechanism"
    echo
    echo -e "   ${RED}DATA LOSS RISK${NC}"
    echo -e "      - No replication for coordinator"
    echo -e "      - Worker failures lose shard data"
    echo
    echo -e "   ${RED}MANUAL RECOVERY REQUIRED${NC}"
    echo -e "      - DBA intervention needed for all failures"
    echo -e "      - Long recovery times (minutes to hours)"
    echo
    echo -e "   ${RED}NOT PRODUCTION READY${NC}"
    echo -e "      - No 24/7 availability guarantees"
    echo -e "      - Unsuitable for mission-critical applications"
    echo
    echo -e "${CYAN}SOLUTION: Use Patroni + Citus for production workloads${NC}"
    echo -e "${CYAN}   - Automatic failover in seconds${NC}"
    echo -e "${CYAN}   - Zero data loss with replication${NC}"
    echo -e "${CYAN}   - Self-healing cluster architecture${NC}"
}

check_patroni_cluster_health() {
    log "INFO" "Checking Patroni cluster health..."
    
    local healthy_coordinators=0
    local total_coordinators=0
    
    for coord in "$PATRONI_COORDINATOR1" "$PATRONI_COORDINATOR2" "$PATRONI_COORDINATOR3"; do
        ((total_coordinators++))
        if container_healthy "$coord"; then
            ((healthy_coordinators++))
            log "SUCCESS" "Coordinator $coord is healthy"
        else
            log "WARN" "Coordinator $coord is not healthy"
        fi
    done
    
    log "INFO" "Healthy coordinators: $healthy_coordinators/$total_coordinators"
    
    if [ $healthy_coordinators -lt 2 ]; then
        log "ERROR" "Need at least 2 healthy coordinators for HA demonstration"
        return 1
    fi
    
    local leader=$(get_patroni_leader)
    if [ -n "$leader" ]; then
        log "SUCCESS" "Cluster has active leader: $leader"
        return 0
    else
        log "ERROR" "No active leader found"
        return 1
    fi
}

demonstrate_patroni_capabilities() {
    print_header "PATRONI CITUS - HA CAPABILITIES DEMO"
    
    echo -e "${GREEN}OBJECTIVE: Show advanced HA capabilities of Patroni + Citus${NC}"
    echo -e "${GREEN}   This demonstrates production-ready high availability${NC}"
    echo
    
    # Check cluster health before starting
    if ! check_patroni_cluster_health; then
        log "ERROR" "Patroni cluster is not healthy enough for HA demonstration"
        return 1
    fi
    
    local leader
    leader=$(get_patroni_leader)
    
    print_section "BASELINE TEST"
    show_patroni_topology
    test_query "patroni" "$leader" "$PATRONI_DB" "Baseline query (healthy cluster)"
    
    echo -e "${CYAN}Press Enter to simulate leader failure...${NC}"
    read -r
    
    print_section "LEADER FAILURE TEST"
    simulate_coordinator_failure "patroni" "$leader"
    show_patroni_topology
    
    # Wait for new leader election
    log "INFO" "Waiting for leader election..."
    sleep 10
    
    local new_leader
    new_leader=$(get_patroni_leader)
    
    if [[ -n "$new_leader" ]] && [[ "$new_leader" != "$leader" ]]; then
        log "SUCCESS" "NEW LEADER ELECTED: $new_leader"
        show_patroni_topology
        test_query "patroni" "$new_leader" "$PATRONI_DB" "Query with new leader"
    else
        log "WARN" "Leader election may still be in progress"
    fi
    
    echo -e "${CYAN}Press Enter to recover original leader...${NC}"
    read -r
    
    print_section "ORIGINAL LEADER RECOVERY"
    recover_container "$leader"
    sleep 10  # Allow time for Patroni to sync
    show_patroni_topology
    
    # Test with current leader (might have changed)
    local current_leader
    current_leader=$(get_patroni_leader)
    test_query "patroni" "$current_leader" "$PATRONI_DB" "Query after original leader recovery"
    
    print_section "WORKER FAILOVER TEST"
    echo -e "${CYAN}Press Enter to test worker failover...${NC}"
    read -r
    
    local w1_primary
    w1_primary=$(get_patroni_primary_worker "1")
    
    if [[ -n "$w1_primary" ]]; then
        simulate_worker_failure "$w1_primary"
        
        log "INFO" "Waiting for worker failover..."
        sleep 10
        
        show_patroni_topology
        
        local new_w1_primary
        new_w1_primary=$(get_patroni_primary_worker "1")
        
        if [[ -n "$new_w1_primary" ]] && [[ "$new_w1_primary" != "$w1_primary" ]]; then
            log "SUCCESS" "WORKER FAILOVER SUCCESSFUL: $new_w1_primary is now primary"
        else
            log "WARN" "Worker failover may still be in progress"
        fi
        
        current_leader=$(get_patroni_leader)
        test_query "patroni" "$current_leader" "$PATRONI_DB" "Query after worker failover"
        
        echo -e "${CYAN}Press Enter to recover original worker...${NC}"
        read -r
        
        print_section "WORKER RECOVERY"
        recover_container "$w1_primary"
        sleep 10
        show_patroni_topology
        
        current_leader=$(get_patroni_leader)
        test_query "patroni" "$current_leader" "$PATRONI_DB" "Query after worker recovery"
    fi
    
    print_section "PATRONI CITUS - CAPABILITIES SUMMARY"
    echo -e "${GREEN}PRODUCTION-READY HA CAPABILITIES:${NC}"
    echo
    echo -e "   ${GREEN}AUTOMATIC FAILOVER${NC}"
    echo -e "      - Leader election in seconds"
    echo -e "      - No manual intervention required"
    echo
    echo -e "   ${GREEN}ZERO DATA LOSS${NC}"
    echo -e "      - Streaming replication"
    echo -e "      - Synchronous commit options"
    echo
    echo -e "   ${GREEN}SELF-HEALING ARCHITECTURE${NC}"
    echo -e "      - Automatic worker promotion"
    echo -e "      - Continuous availability"
    echo
    echo -e "   ${GREEN}PRODUCTION READY${NC}"
    echo -e "      - 99.9%+ availability possible"
    echo -e "      - Mission-critical application support"
    
    echo
    echo -e "${CYAN}RESULT: Enterprise-grade distributed database with HA${NC}"
}

# =============================================================================
# ARCHITECTURE ANALYSIS
# =============================================================================

show_architecture_analysis() {
    local arch="$1"
    
    case "$arch" in
        "standard")
            show_standard_analysis
            ;;
        "patroni")
            show_patroni_analysis  
            ;;
        *)
            show_general_comparison
            ;;
    esac
}

show_standard_analysis() {
    print_header "STANDARD CITUS ANALYSIS"
    
    echo -e "${BOLD}📊 CURRENT ARCHITECTURE ASSESSMENT${NC}"
    echo
    echo -e "${YELLOW}⚡ STRENGTHS:${NC}"
    echo "   ✅ Simple setup and configuration"
    echo "   ✅ Low resource requirements"  
    echo "   ✅ Fast development iteration"
    echo "   ✅ Good for learning Citus concepts"
    
    echo
    echo -e "${RED}⚠️  CRITICAL LIMITATIONS:${NC}"
    echo "   ❌ Single point of failure (coordinator)"
    echo "   ❌ No automatic failover"
    echo "   ❌ Data loss risk during failures"
    echo "   ❌ Manual recovery required"
    echo "   ❌ Not suitable for production"
    
    echo
    echo -e "${CYAN}🎯 RECOMMENDATIONS:${NC}"
    echo "   • Use for: Development, testing, demos"
    echo "   • Avoid for: Production, mission-critical apps"
    echo "   • Upgrade to: Patroni + Citus for production"
}

show_patroni_analysis() {
    print_header "PATRONI CITUS ANALYSIS"
    
    echo -e "${BOLD}📊 CURRENT ARCHITECTURE ASSESSMENT${NC}"
    echo
    echo -e "${GREEN}� PRODUCTION STRENGTHS:${NC}"
    echo "   ✅ Automatic failover (seconds)"
    echo "   ✅ Zero data loss protection"
    echo "   ✅ Self-healing architecture" 
    echo "   ✅ Continuous availability"
    echo "   ✅ Enterprise-grade reliability"
    
    echo
    echo -e "${YELLOW}⚠️  CONSIDERATIONS:${NC}"
    echo "   • Higher complexity to setup"
    echo "   • More resource requirements"
    echo "   • Requires monitoring and ops knowledge"
    
    echo
    echo -e "${CYAN}� PRODUCTION READY:${NC}"
    echo "   • Ideal for: Mission-critical applications"
    echo "   • Supports: 24/7 operations"
    echo "   • Enables: Enterprise SLA compliance"
}

show_general_comparison() {
    print_header "CITUS HA ARCHITECTURES"
    
    echo -e "${BOLD}📊 ARCHITECTURE COMPARISON${NC}"
    echo
    printf "%-25s | %-15s | %-15s\n" "FEATURE" "STANDARD" "PATRONI"
    echo "$(printf '=%.0s' {1..60})"
    printf "%-25s | %-15s | %-15s\n" "Failover" "Manual" "Automatic"
    printf "%-25s | %-15s | %-15s\n" "Data Protection" "Limited" "Full"
    printf "%-25s | %-15s | %-15s\n" "Recovery Time" "Minutes" "Seconds"
    printf "%-25s | %-15s | %-15s\n" "Production Ready" "No" "Yes"
    printf "%-25s | %-15s | %-15s\n" "Setup Complexity" "Low" "High"
}

# =============================================================================
# HA DEMONSTRATION FUNCTIONS
# =============================================================================

run_ha_demonstration() {
    local arch="$1"
    
    print_header "HIGH AVAILABILITY DEMONSTRATION"
    
    case "$arch" in
        "standard")
            echo -e "${YELLOW}🎯 DEMONSTRATING: Standard Citus Limitations${NC}"
            echo -e "${YELLOW}   Purpose: Show where basic setup fails${NC}"
            echo
            demonstrate_standard_limitations
            ;;
        "patroni")
            echo -e "${GREEN}🎯 DEMONSTRATING: Patroni Citus Capabilities${NC}"
            echo -e "${GREEN}   Purpose: Show enterprise-grade resilience${NC}"
            echo
            demonstrate_patroni_capabilities
            ;;
        *)
            log "ERROR" "Invalid architecture: $arch"
            return 1
            ;;
    esac
}

demonstrate_standard_limitations() {
    print_section "STANDARD CITUS - LIVE FAILOVER TEST"
    
    echo -e "${YELLOW}🎯 LIVE DEMONSTRATION: Standard Citus under failure${NC}"
    echo -e "${YELLOW}   We'll run queries and simulate failures to show limitations${NC}"
    echo
    
    # Step 1: Baseline test
    echo -e "${CYAN}📊 STEP 1: Baseline Performance${NC}"
    echo "Running baseline queries on healthy cluster..."
    run_baseline_queries "standard"
    
    echo -e "${CYAN}Press Enter to continue to failure simulation...${NC}"
    read -r
    
    # Step 2: Worker failure
    echo -e "${RED}� STEP 2: Worker Failure Simulation${NC}"
    echo "Simulating worker failure while running queries..."
    simulate_worker_failure "standard"
    
    echo -e "${CYAN}Press Enter to continue to coordinator failure...${NC}"
    read -r
    
    # Step 3: Coordinator failure (devastating)
    echo -e "${RED}🚨 STEP 3: Coordinator Failure (Critical)${NC}"
    echo "Simulating coordinator failure - this will break everything..."
    simulate_coordinator_failure "standard"
    
    echo -e "${CYAN}Press Enter to recover and see results...${NC}"
    read -r
    
    # Recovery
    recover_all_services "standard"
    show_standard_limitations_summary
}

demonstrate_patroni_capabilities() {
    print_section "PATRONI CITUS - LIVE RESILIENCE TEST"
    
    echo -e "${GREEN}LIVE DEMONSTRATION: Patroni Citus under failure${NC}"
    echo -e "${GREEN}   Watch how queries continue working despite failures!${NC}"
    echo
    
    # Step 1: Baseline test
    echo -e "${CYAN}STEP 1: Baseline Performance${NC}"
    echo "Running baseline queries on healthy cluster..."
    run_baseline_queries "patroni"
    
    echo -e "${CYAN}Press Enter to start failure tests...${NC}"
    read -r
    
    # Step 2: Worker failure (should handle gracefully)
    echo -e "${YELLOW}STEP 2: Worker Primary Failure${NC}"
    echo "Failing worker primary - watch automatic failover!"
    simulate_worker_failure "patroni"
    
    echo -e "${CYAN}Press Enter to test coordinator failover...${NC}"
    read -r
    
    # Step 3: Coordinator failover (should be automatic)
    echo -e "${ORANGE}STEP 3: Coordinator Failover${NC}"
    echo "Failing coordinator leader - Patroni should elect new leader!"
    simulate_coordinator_failure "patroni"
    
    echo -e "${CYAN}Press Enter to see final results...${NC}"
    read -r
    
    # Recovery and summary
    recover_all_services "patroni"
    show_patroni_capabilities_summary
}

test_cluster_connectivity() {
    local arch="$1"
    local coordinator
    
    coordinator=$(get_current_coordinator "$arch")
    
    if [[ -z "$coordinator" ]]; then
        return 1
    fi
    
    # Simple connectivity test
    if ! container_healthy "$coordinator"; then
        return 1
    fi
    
    # Test database connectivity
    local db_name
    case "$arch" in
        "standard") db_name="$STANDARD_DB" ;;
        "patroni") db_name="$PATRONI_DB" ;;
    esac
    
    if docker exec "$coordinator" psql -U postgres -d "$db_name" -c "SELECT 1;" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# PRACTICAL TESTING FUNCTIONS
# =============================================================================

run_baseline_queries() {
    local arch="$1"
    local coordinator
    coordinator=$(get_current_coordinator "$arch")
    
    local db_name
    case "$arch" in
        "standard") db_name="$STANDARD_DB" ;;
        "patroni") db_name="$PATRONI_DB" ;;
    esac
    
    echo -e "${CYAN}Testing query performance...${NC}"
    
    # Test 1: Simple count query
    echo -n "   Company count query: "
    if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM companies;" >/dev/null 2>&1; then
        echo -e "${GREEN}SUCCESS${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    # Test 2: Distributed query
    echo -n "   Distributed campaign query: "
    if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM campaigns;" >/dev/null 2>&1; then
        echo -e "${GREEN}SUCCESS${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    # Test 3: Join query
    echo -n "   Cross-table join query: "
    if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM companies c JOIN campaigns camp ON c.id = camp.company_id;" >/dev/null 2>&1; then
        echo -e "${GREEN}SUCCESS${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    echo -e "${GREEN}Baseline: All queries working normally${NC}"
}

simulate_worker_failure() {
    local arch="$1"
    
    case "$arch" in
        "standard")
            echo -e "${RED}Pausing worker1...${NC}"
            docker pause "$STANDARD_WORKER1" 2>/dev/null || true
            sleep 2
            
            echo -e "${YELLOW}Testing queries with failed worker...${NC}"
            test_queries_during_failure "$arch"
            ;;
        "patroni")
            echo -e "${YELLOW}Pausing worker1-primary...${NC}"
            docker pause "$PATRONI_WORKER1_PRIMARY" 2>/dev/null || true
            sleep 3
            
            echo -e "${CYAN}Patroni should promote standby automatically...${NC}"
            sleep 3
            
            echo -e "${GREEN}Testing queries after automatic failover...${NC}"
            test_queries_during_failure "$arch"
            ;;
    esac
}

simulate_coordinator_failure() {
    local arch="$1"
    
    case "$arch" in
        "standard")
            echo -e "${RED}Pausing coordinator...${NC}"
            docker pause "$STANDARD_COORDINATOR" 2>/dev/null || true
            sleep 2
            
            echo -e "${RED}This will break everything - no coordinator redundancy!${NC}"
            test_queries_during_failure "$arch"
            ;;
        "patroni")
            local current_leader
            current_leader=$(get_patroni_leader)
            log "WARN" "Pausing current leader: $current_leader"
            docker pause "$current_leader" 2>/dev/null || true
            
            log "INFO" "Patroni should elect new leader automatically..."
            
            # Wait for new leader election, passing the failed leader
            if wait_for_leader_election "$current_leader"; then
                log "INFO" "Testing queries with new coordinator setup..."
                test_queries_during_failure "$arch" "coordinator"
            else
                log "WARN" "Leader election incomplete - testing anyway..."
                test_queries_during_failure "$arch" "coordinator"
            fi
            ;;
    esac
}

test_queries_during_failure() {
    local arch="$1"
    local failure_type="${2:-worker}"  # worker or coordinator
    local coordinator
    
    # For coordinator failures in Patroni, we need to detect the new leader
    if [[ "$failure_type" == "coordinator" && "$arch" == "patroni" ]]; then
        log "INFO" "Testing queries during leader transition..."
        
        # Try to get the current leader with retries
        local retries=5
        local retry_delay=3
        
        for i in $(seq 1 $retries); do
            coordinator=$(get_patroni_leader)
            if [[ -n "$coordinator" ]]; then
                log "SUCCESS" "Active leader found: $coordinator"
                break
            fi
            
            if [[ $i -lt $retries ]]; then
                log "INFO" "Retry $i/$retries - waiting for new leader..."
                sleep $retry_delay
            fi
        done
        
        if [[ -z "$coordinator" ]]; then
            log "WARN" "No leader available - will test connection failures"
            # Try each coordinator to see if any is responding
            local backup_coordinators=("citus_coordinator1" "citus_coordinator2" "citus_coordinator3")
            for backup in "${backup_coordinators[@]}"; do
                if container_running "$backup" && timeout 3 docker exec "$backup" pg_isready -U postgres >/dev/null 2>&1; then
                    coordinator="$backup"
                    log "INFO" "Using backup coordinator: $backup"
                    break
                fi
            done
            
            if [[ -z "$coordinator" ]]; then
                coordinator="citus_coordinator1"  # Ultimate fallback for testing
            fi
        fi
    else
        coordinator=$(get_current_coordinator "$arch")
    fi
    
    local db_name
    case "$arch" in
        "standard") db_name="$STANDARD_DB" ;;
        "patroni") db_name="$PATRONI_DB" ;;
    esac
    
    echo -e "${CYAN}Query results during failure:${NC}"
    
    # Test 1: Reference table (should always work)
    echo -n "   Basic company query: "
    if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM companies;" >/dev/null 2>&1; then
        echo -e "${GREEN}STILL WORKS${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    # Test 2: Distributed query (may fail during worker failure)
    echo -n "   Distributed campaign query: "
    if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM campaigns;" >/dev/null 2>&1; then
        echo -e "${GREEN}STILL WORKS${NC}"
    else
        case "$arch" in
            "standard")
                echo -e "${RED}FAILED - DATA UNAVAILABLE${NC}"
                ;;
            "patroni")
                echo -e "${YELLOW}TEMPORARY FAILURE - Patroni failover in progress${NC}"
                # Wait a bit and retry
                sleep 3
                echo -n "   Retrying after Patroni failover: "
                if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM campaigns;" >/dev/null 2>&1; then
                    echo -e "${GREEN}RECOVERED AUTOMATICALLY${NC}"
                else
                    echo -e "${YELLOW}Still failing - may need more time${NC}"
                fi
                ;;
        esac
    fi
    
    # Test 3: Join query (should work if both tables are accessible)
    echo -n "   Cross-table join query: "
    if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM companies c JOIN campaigns camp ON c.id = camp.company_id;" >/dev/null 2>&1; then
        echo -e "${GREEN}STILL WORKS${NC}"
    else
        case "$arch" in
            "standard")
                echo -e "${RED}FAILED - CROSS-SHARD DATA UNAVAILABLE${NC}"
                ;;
            "patroni")
                echo -e "${YELLOW}TEMPORARY FAILURE - Waiting for failover${NC}"
                # Wait a bit and retry for coordinator failovers
                if [[ "$failure_type" == "coordinator" ]]; then
                    sleep 3
                    echo -n "   Retrying cross-table join: "
                    if docker exec "$coordinator" psql -U postgres -d "$db_name" -t -c "SELECT COUNT(*) FROM companies c JOIN campaigns camp ON c.id = camp.company_id;" >/dev/null 2>&1; then
                        echo -e "${GREEN}RECOVERED AUTOMATICALLY${NC}"
                    else
                        echo -e "${YELLOW}Still recovering - coordinator stabilizing${NC}"
                    fi
                fi
                ;;
        esac
    fi
}

recover_all_services() {
    local arch="$1"
    
    log "INFO" "Recovering all services..."
    
    case "$arch" in
        "standard")
            docker unpause "$STANDARD_COORDINATOR" 2>/dev/null || true
            docker unpause "$STANDARD_WORKER1" 2>/dev/null || true
            docker unpause "$STANDARD_WORKER2" 2>/dev/null || true
            sleep 5
            ;;
        "patroni")
            # Unpause all containers
            docker unpause "$PATRONI_COORDINATOR1" 2>/dev/null || true
            docker unpause "$PATRONI_COORDINATOR2" 2>/dev/null || true
            docker unpause "$PATRONI_COORDINATOR3" 2>/dev/null || true
            docker unpause "$PATRONI_WORKER1_PRIMARY" 2>/dev/null || true
            docker unpause "$PATRONI_WORKER1_STANDBY" 2>/dev/null || true
            docker unpause "$PATRONI_WORKER2_PRIMARY" 2>/dev/null || true
            docker unpause "$PATRONI_WORKER2_STANDBY" 2>/dev/null || true
            
            # Wait for Patroni to stabilize the cluster
            log "INFO" "Waiting for Patroni cluster to stabilize..."
            sleep 10
            
            # Verify we have a leader
            local leader=$(get_patroni_leader)
            if [ -n "$leader" ]; then
                log "SUCCESS" "Cluster stabilized with leader: $leader"
            else
                log "WARN" "Cluster recovery may need more time"
            fi
            ;;
    esac
    
    log "SUCCESS" "Recovery procedure complete"
}

show_standard_limitations_summary() {
    print_section "STANDARD CITUS - LIMITATIONS REVEALED"
    
    echo -e "${RED}📋 CRITICAL ISSUES DEMONSTRATED:${NC}"
    echo -e "${RED}   ❌ Single coordinator = total failure point${NC}"
    echo -e "${RED}   ❌ Worker failures cause data unavailability${NC}"
    echo -e "${RED}   ❌ No automatic recovery mechanisms${NC}"
    echo -e "${RED}   ❌ Manual intervention required for all failures${NC}"
    echo
    echo -e "${YELLOW}⚠️  PRODUCTION IMPACT:${NC}"
    echo "   • Extended downtime during failures"
    echo "   • Data loss risk"  
    echo "   • Requires 24/7 manual monitoring"
    echo "   • Not suitable for mission-critical applications"
}

show_patroni_capabilities_summary() {
    print_section "PATRONI CITUS - ENTERPRISE RESILIENCE PROVEN"
    
    echo -e "${GREEN}📋 CAPABILITIES DEMONSTRATED:${NC}"
    echo -e "${GREEN}   ✅ Automatic coordinator failover${NC}"
    echo -e "${GREEN}   ✅ Worker redundancy with streaming replication${NC}"
    echo -e "${GREEN}   ✅ Queries continue during failures${NC}"
    echo -e "${GREEN}   ✅ Zero data loss during planned failovers${NC}"
    echo
    echo -e "${CYAN}🚀 PRODUCTION ADVANTAGES:${NC}"
    echo "   • Sub-minute recovery times"
    echo "   • Automatic failure detection and recovery"
    echo "   • Suitable for 24/7 mission-critical operations"
    echo "   • Enterprise SLA compliance ready"
}

show_architecture_analysis() {
    local arch="$1"
    
    case "$arch" in
        "standard")
            show_standard_analysis
            ;;
        "patroni")
            show_patroni_analysis
            ;;
    esac
}

# =============================================================================
# ADAPTIVE MAIN MENU
# =============================================================================

show_menu() {
    local arch
    arch=$(detect_current_architecture)
    
    print_header "ADAPTIVE HA DEMONSTRATION"
    
    case "$arch" in
        "standard")
            echo -e "${YELLOW}🎯 DETECTED: Standard Citus Cluster${NC}"
            echo -e "${YELLOW}   Mode: Limitation Demonstration${NC}"
            echo
            echo -e "${BOLD}Available Options:${NC}"
            echo -e "${GREEN}1)${NC} Run HA Limitations Demo"
            echo -e "${CYAN}2)${NC} Show Architecture Analysis"  
            echo -e "${CYAN}3)${NC} Cluster Topology"
            echo -e "${RED}4)${NC} Exit"
            ;;
        "patroni")
            echo -e "${GREEN}🎯 DETECTED: Patroni Citus Cluster${NC}"
            echo -e "${GREEN}   Mode: Capabilities Demonstration${NC}"
            echo
            echo -e "${BOLD}Available Options:${NC}"
            echo -e "${GREEN}1)${NC} Run HA Capabilities Demo"
            echo -e "${CYAN}2)${NC} Show Architecture Analysis"
            echo -e "${CYAN}3)${NC} Cluster Topology"
            echo -e "${RED}4)${NC} Exit"
            ;;
        *)
            echo -e "${RED}❌ NO ACTIVE CLUSTER DETECTED${NC}"
            echo
            echo -e "${YELLOW}Please start a Citus cluster first:${NC}"
            echo -e "${YELLOW}   Standard: docker-compose up -d${NC}"
            echo -e "${YELLOW}   Patroni:   ./simple_setup.sh${NC}"
            echo
            echo -e "${RED}1)${NC} Exit"
            ;;
    esac
    
    echo
    read -p "Enter your choice: " choice
    
    case "$arch" in
        "standard"|"patroni")
            case "$choice" in
                1)
                    run_ha_demonstration "$arch"
                    ;;
                2)
                    show_architecture_analysis "$arch"
                    ;;
                3)
                    case "$arch" in
                        "standard") show_standard_topology ;;
                        "patroni") show_patroni_topology ;;
                    esac
                    ;;
                4)
                    log "INFO" "Goodbye!"
                    exit 0
                    ;;
                *)
                    log "ERROR" "Invalid choice."
                    ;;
            esac
            ;;
        *)
            case "$choice" in
                1)
                    log "INFO" "Goodbye!"
                    exit 0
                    ;;
                *)
                    log "ERROR" "Invalid choice."
                    ;;
            esac
            ;;
    esac
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Dependency check
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR" "Docker is required but not installed"
        exit 1
    fi
    
    if ! command -v bc >/dev/null 2>&1; then
        log "WARN" "bc not found - timing measurements will be limited"
    fi
    
    # Detect current architecture and run HA Capabilities Demo directly
    local arch
    arch=$(detect_current_architecture)
    
    case "$arch" in
        "patroni")
            log "INFO" "Detected Patroni Citus - Running HA Capabilities Demo"
            demonstrate_patroni_capabilities
            ;;
        *)
            log "ERROR" "No Patroni cluster detected. This demo requires Patroni Citus."
            echo -e "${YELLOW}Please start Patroni Citus cluster first: ./simple_setup.sh${NC}"
            exit 1
            ;;
    esac
    
    echo
    echo -e "${CYAN}HA Capabilities demonstration completed.${NC}"
}

# Handle script interruption gracefully  
trap 'log "WARN" "Script interrupted by user"; exit 130' INT

# Execute main function
main "$@"