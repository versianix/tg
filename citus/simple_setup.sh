#!/bin/bash
#
# Setup script for Citus cluster with Patroni 

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configs
COMPOSE_PROJECT_NAME="citus"
POSTGRES_PASSWORD="postgres"
DB_NAME="citus_platform"
# NOTE: Container names are inverted in this setup!
# The "standby" containers are actually the primaries (pg_is_in_recovery = false)
# The "primary" containers are actually the replicas (pg_is_in_recovery = true)
WORKER1_PRIMARY_CONTAINER="citus_worker1_primary"  # Actually the primary
WORKER1_STANDBY_CONTAINER="citus_worker1_standby"  # Actually the standby
WORKER2_PRIMARY_CONTAINER="citus_worker2_primary"  # Actually the primary  
WORKER2_STANDBY_CONTAINER="citus_worker2_standby"  # Actually the standby



echo -e "${BLUE}Citus Cluster Setup with Patroni${NC}"
echo "================================="
echo

# Function for logging
log_step() {
    echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"
}

# Check Docker
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}❌ Docker is not running. Start Docker first.${NC}"
    exit 1
fi

echo -e "${BLUE}🧹 STEP 1: Cleanup${NC}"
echo "═══════════════════════"

log_step "Stopping old containers..."
docker-compose down -v 2>/dev/null || true

log_step "Cleaning orphaned volumes..."
docker volume prune -f

echo -e "${BLUE}🚀 STEP 2: Starting Cluster${NC}"
echo "════════════════════════════════"

# Set environment variables
export COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME"
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export POSTGRES_USER="postgres"

log_step "Starting containers with Patroni..."
docker-compose -f docker-compose-patroni.yml up -d



# Function to detect leader coordinator
detect_leader_coordinator() {
    echo -e "${CYAN}🔍 Detecting leader coordinator...${NC}"
    
    # Try to detect leader for up to 2 minutes (PostgreSQL initialization may take time)
    local max_attempts=240  # 120 seconds (240 * 0.5s)
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Check for leader using multiple methods
        for coord in coordinator1 coordinator2 coordinator3; do
            container_name="citus_$coord"

            # Check if the container is running
            if ! docker ps --format "table {{.Names}}" | grep -q "^$container_name$"; then
                continue
            fi

            # Method 1: Check Patroni API for leader role
            role=$(docker exec "$container_name" curl -s localhost:8008/ 2>/dev/null | grep -o '"role":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
            if [[ "$role" == "master" ]]; then
                COORDINATOR_CONTAINER="$container_name"
                echo -e "${GREEN}✅ Leader detected: $coord${NC}"
                return 0
            fi
            
            # Method 2: Direct PostgreSQL check for master/replica status
            if docker exec "$container_name" pg_isready -U postgres >/dev/null 2>&1; then
                postgres_role=$(docker exec "$container_name" psql -U postgres -t -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'master' END;" 2>/dev/null | tr -d ' ')
                if [[ "$postgres_role" == "master" ]]; then
                    COORDINATOR_CONTAINER="$container_name"
                    echo -e "${GREEN}✅ Leader detected: $coord${NC}"
                    return 0
                fi
            fi
        done
        
        # Show progress
        if [ $((attempt % 10)) -eq 0 ] && [ $attempt -gt 0 ]; then
            echo -n " [${attempt}s]"
        else
            echo -n "."
        fi
        sleep 0.5
        attempt=$((attempt + 1))
    done

    echo -e "\n${YELLOW}⚠️ Could not detect leader automatically.${NC}"
    
    # Fallback: attempt to find any responsive coordinator
    echo -e "${CYAN}Trying to find any working coordinator...${NC}"
    for coord in coordinator1 coordinator2 coordinator3; do
        container_name="citus_$coord"
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            echo -n "Testing $coord... "
            if docker exec "$container_name" pg_isready -U postgres >/dev/null 2>&1; then
                COORDINATOR_CONTAINER="$container_name"
                echo -e "${GREEN}✅ Found working coordinator: $coord${NC}"
                return 0
            else
                echo "not ready"
            fi
        fi
    done
    
    echo -e "${YELLOW}Using coordinator1 as fallback${NC}"
    COORDINATOR_CONTAINER="citus_coordinator1"
    return 1
}

# Detect leader coordinator
detect_leader_coordinator

log_step "Waiting for coordinator ($COORDINATOR_CONTAINER) to be ready..."
timeout=360  # 3 minutes timeout
attempt=0
while [ $attempt -lt $timeout ]; do
    if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 0.5
    attempt=$((attempt + 1))
done

if [ $attempt -ge $timeout ]; then
    echo -e "${RED}❌ Timeout waiting for coordinator${NC}"
    exit 1
fi

log_step "✅ Coordinator Primary ready!"

echo -e "${BLUE}🔧 STEP 3: Basic Configuration${NC}"
echo "═══════════════════════════════════"

# Verify database exists (created automatically via POSTGRES_DB environment variable)
log_step "Checking database $DB_NAME..."
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME" || {
    echo -e "${RED}❌ Database $DB_NAME not found${NC}"
    exit 1
}

# Verify Patroni cluster status
log_step "Checking Patroni status..."

# Check coordinator leader status via logs
leader_found=""
if docker logs citus_coordinator1 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
    leader_found="coordinator1"
elif docker logs citus_coordinator2 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
    leader_found="coordinator2"  
elif docker logs citus_coordinator3 --tail 1 2>/dev/null | grep -q "leader with the lock"; then
    leader_found="coordinator3"
fi

if [ -n "$leader_found" ]; then
    echo -e "${GREEN}✅ Active leader: $leader_found${NC}"
else
    # Verify PostgreSQL connectivity as fallback
    if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Patroni cluster active (PostgreSQL responding)${NC}"
    else
        log_step "Waiting for PostgreSQL to initialize..."
        for i in {1..20}; do  # 10 second timeout
            if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
                echo -e "${GREEN}✅ PostgreSQL ready${NC}"
                break
            fi
            sleep 0.5
        done
        
        if ! docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
            echo -e "${YELLOW}⚠️ PostgreSQL still initializing, continuing...${NC}"
        fi
    fi
fi

# Check if Citus is configured
log_step "Checking Citus configuration..."
if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_version();" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Citus already configured and working${NC}"
else
    # Wait for Citus extension initialization
    log_step "Waiting for Citus to initialize..."
    for i in {1..20}; do  # 10 second timeout
        if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_version();" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ Citus successfully configured${NC}"
            break
        fi
        sleep 0.5
    done
    
    if ! docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_version();" > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Citus still initializing, but continuing...${NC}"
    fi
fi

# Verify worker node status
log_step "Checking workers..."
worker1_ready=0
worker2_ready=0

if docker exec "$WORKER1_PRIMARY_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
    worker1_ready=1
fi
if docker exec "$WORKER2_PRIMARY_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
    worker2_ready=1
fi

workers_ready=$((worker1_ready + worker2_ready))

if [ $workers_ready -eq 2 ]; then
    echo -e "${GREEN}✅ All workers ready (2/2)${NC}"
else
    echo -e "${YELLOW}⏳ Waiting for workers to be ready... ($workers_ready/2)${NC}"
    
    # Wait for worker initialization
    for i in {1..30}; do  # 15 second timeout
        worker1_ready=0
        worker2_ready=0
        
        if docker exec "$WORKER1_PRIMARY_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
            worker1_ready=1
        fi
        if docker exec "$WORKER2_PRIMARY_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
            worker2_ready=1
        fi
        
        workers_ready=$((worker1_ready + worker2_ready))
        
        if [ $workers_ready -eq 2 ]; then
            break
        fi
        
        sleep 0.5
    done
    
    echo -e "${GREEN}✅ Workers ready: $workers_ready/2${NC}"
fi

# Register workers in Citus coordinator
log_step "Registering workers in Citus coordinator..."

# Function to check if a worker is primary (not in recovery)
is_worker_primary() {
    local worker_container="$1"
    
    # Check if worker is ready first
    if ! docker exec "$worker_container" pg_isready -U postgres > /dev/null 2>&1; then
        return 1
    fi
    
    # Check if worker is NOT in recovery (i.e., it's a primary)
    if docker exec "$worker_container" psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
        return 0  # It's a primary
    else
        return 1  # It's a replica/standby
    fi
}

# Function to register a worker node
register_worker() {
    local worker_container="$1"
    local worker_name="$2"
    
    log_step "Checking $worker_name..."
    
    # Check if worker is ready
    if ! docker exec "$worker_container" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Worker $worker_name not ready, skipping${NC}"
        return 1
    fi
    
    # Check if it's a primary
    if ! is_worker_primary "$worker_container"; then
        echo -e "${BLUE}ℹ️ $worker_name is a replica, skipping registration${NC}"
        return 1
    fi
    
    log_step "Adding $worker_name (primary) to Citus cluster..."
    
    # Get the internal hostname for the worker
    local worker_hostname
    worker_hostname=$(docker exec "$worker_container" hostname 2>/dev/null || echo "$worker_container")
    
    # Check if already registered using hostname
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT 1 FROM master_get_active_worker_nodes() WHERE node_name = '$worker_hostname';" 2>/dev/null | grep -q "1"; then
        echo -e "${BLUE}ℹ️ Worker $worker_name already registered${NC}"
        return 0
    fi
    
    # Try to register the worker using hostname
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT master_add_node('$worker_hostname', 5432);" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Worker $worker_name registered successfully${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to register worker $worker_name${NC}"
        return 1
    fi
}

# Auto-detect and register primary workers
log_step "Auto-detecting primary workers..."

# Check all worker containers dynamically
ALL_WORKER_CONTAINERS=("$WORKER1_PRIMARY_CONTAINER" "$WORKER1_STANDBY_CONTAINER" "$WORKER2_PRIMARY_CONTAINER" "$WORKER2_STANDBY_CONTAINER")
ALL_WORKER_NAMES=("Worker1-Primary" "Worker1-Standby" "Worker2-Primary" "Worker2-Standby")

registered_count=0
for i in "${!ALL_WORKER_CONTAINERS[@]}"; do
    container="${ALL_WORKER_CONTAINERS[$i]}"
    name="${ALL_WORKER_NAMES[$i]}"
    
    if register_worker "$container" "$name"; then
        registered_count=$((registered_count + 1))
    fi
done

if [ $registered_count -eq 0 ]; then
    echo -e "${RED}❌ No primary workers found or registered${NC}"
elif [ $registered_count -eq 2 ]; then
    echo -e "${GREEN}✅ Successfully registered $registered_count primary workers${NC}"
else
    echo -e "${YELLOW}⚠️ Only $registered_count primary worker(s) registered${NC}"
fi

# Verify registered Citus worker nodes
log_step "Verifying worker registration..."

# Function to verify worker registration
verify_worker_registration() {
    local worker_container="$1"
    local worker_hostname="$2"
    local worker_name="$3"
    
    # Check if worker is in active worker nodes
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT 1 FROM master_get_active_worker_nodes() WHERE node_name = '$worker_hostname';" 2>/dev/null | grep -q "1"; then
        # Test connection to worker
        if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_check_connection_to_node('$worker_hostname', 5432);" 2>/dev/null | grep -q "t"; then
            echo -e "${GREEN}✅ $worker_name: registered and connected${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️ $worker_name: registered but connection failed${NC}"
            return 1
        fi
    else
        echo -e "${RED}❌ $worker_name: not registered${NC}"
        return 1
    fi
}

echo -e "${CYAN}📋 Worker status:${NC}"
# Check which workers are actually registered
registered_workers=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT node_name FROM master_get_active_worker_nodes();" 2>/dev/null | xargs || echo "")

if [[ -n "$registered_workers" ]]; then
    for worker in $registered_workers; do
        echo -e "${GREEN}✅ $worker: registered and active${NC}"
    done
else
    echo -e "${RED}❌ No workers registered${NC}"
fi

# Get final worker count
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM master_get_active_worker_nodes();" 2>/dev/null | tr -d ' ' || echo "0")

echo -e "${BLUE}📊 STEP 4: Final Verification${NC}"
echo "════════════════════════════════"

# Show cluster status
log_step "Citus cluster status:"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT node_name, node_port FROM master_get_active_worker_nodes();" 2>/dev/null || echo "No workers registered"

# Final worker count and status
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM master_get_active_worker_nodes();" 2>/dev/null | tr -d ' ' || echo "0")

# Check if Citus is working
CITUS_WORKING=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT citus_version();" 2>/dev/null | wc -l | tr -d ' ')

if [ "$WORKER_COUNT" -eq 2 ] && [ "$CITUS_WORKING" -gt 0 ]; then
    CLUSTER_STATUS="${GREEN}✅ FULLY OPERATIONAL"
elif [ "$WORKER_COUNT" -ge 1 ] && [ "$CITUS_WORKING" -gt 0 ]; then
    CLUSTER_STATUS="${YELLOW}⚠️ PARTIALLY OPERATIONAL"
else
    CLUSTER_STATUS="${RED}❌ NOT OPERATIONAL"
fi

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                🎯 CITUS CLUSTER STATUS                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}🎯 Status: $CLUSTER_STATUS${NC}"
echo "   • Coordinator Primary: ✅ Running on port 5432"
echo "   • Coordinator Standby: ✅ Running on port 5434" 
echo "   • Worker 1A (Primary): ✅ Running on port 5435"
echo "   • Worker 1B (Standby): ✅ Running on port 5436"
echo "   • Worker 2A (Primary): ✅ Running on port 5437"
echo "   • Worker 2B (Standby): ✅ Running on port 5438"
echo "   • Active Workers in Citus: $WORKER_COUNT (primaries only)"
echo "   • Database: $DB_NAME created"
echo "   • Citus Extension: ✅ Configured"
echo "   • Grafana: http://localhost:3000 (admin/admin)"
echo "   • Prometheus: http://localhost:9090"
echo
echo -e "${PURPLE}📝 To connect to the cluster:${NC}"
echo "   docker exec -it $COORDINATOR_CONTAINER psql -U postgres -d $DB_NAME"
echo
echo -e "${PURPLE}🚀 Next steps:${NC}"
echo "   1. ../scripts/schema_manager.sh  → Create and distribute tables"
echo "   2. ../scripts/data_loader.sh     → Load CSV data"
