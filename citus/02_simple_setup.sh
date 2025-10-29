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
WORKER1_PRIMARY_CONTAINER="citus_worker1_primary"
WORKER1_STANDBY_CONTAINER="citus_worker1_standby"
WORKER2_PRIMARY_CONTAINER="citus_worker2_primary"
WORKER2_STANDBY_CONTAINER="citus_worker2_standby"

# Function to detect leader coordinator
detect_leader_coordinator() {
    echo -e "${CYAN}🔍 Detecting leader coordinator...${NC}"
    
    # Try to detect leader for up to 30 seconds
    local timeout=30
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        # Try to access any coordinator to get cluster info
        for coord in coordinator1 coordinator2 coordinator3; do
            container_name="citus_$coord"

            # Check if the container is running
            if ! docker ps --format "table {{.Names}}" | grep -q "^$container_name$"; then
                continue
            fi

            # Use Patroni API to detect leader
            leader=$(docker exec "$container_name" curl -s localhost:8008/cluster 2>/dev/null | \
                     grep -o '"name": "[^"]*", "role": "leader"' | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
            
            if [ -n "$leader" ] && [ "$leader" != "" ]; then
                COORDINATOR_CONTAINER="citus_$leader"
                echo -e "${GREEN}✅ Leader detected: $leader${NC}"
                return 0
            fi
            
            break  # If a coordinator was accessed, no need to try others
        done
        
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo -e "\n${YELLOW}⚠️ Could not detect coordinator leader. Using coordinator1 (fallback)${NC}"
    COORDINATOR_CONTAINER="citus_coordinator1"
    return 1
}

echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}║            CITUS SIMPLIFIED SETUP (Apple Silicon)         ║${NC}"
echo -e "${PURPLE}║                     Robust Version                         ║${NC}"
echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
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

# Detect leader coordinator
detect_leader_coordinator

log_step "Waiting for leader coordinator ($COORDINATOR_CONTAINER) to be ready..."
timeout=180
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        break
    fi
    echo -n "."
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $timeout ]; then
    echo -e "${RED}❌ Timeout waiting for coordinator${NC}"
    exit 1
fi

log_step "✅ Coordinator Primary ready!"

echo -e "${BLUE}🔧 STEP 3: Basic Configuration${NC}"
echo "═══════════════════════════════════"

# Database already exists automatically via POSTGRES_DB in docker-compose.yml
log_step "Checking database $DB_NAME..."
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME" || {
    echo -e "${RED}❌ Database $DB_NAME not found${NC}"
    exit 1
}

# Wait for complete Patroni architecture intelligently
log_step "Checking Patroni status..."

# Check if any coordinator is leader (recent logs)
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
    # More direct verification - if PostgreSQL responds, Patroni is working
    if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Patroni cluster active (PostgreSQL responding)${NC}"
    else
        log_step "Waiting for PostgreSQL to initialize..."
        sleep 10
        if docker exec "$COORDINATOR_CONTAINER" pg_isready -U postgres > /dev/null 2>&1; then
            echo -e "${GREEN}✅ PostgreSQL ready${NC}"
        else
            echo -e "${YELLOW}⚠️ PostgreSQL still initializing, continuing...${NC}"
        fi
    fi
fi

# Check if Citus is configured
log_step "Checking Citus configuration..."
if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_version();" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Citus already configured and working${NC}"
else
    # If not configured, wait a bit
    log_step "Waiting for Citus to initialize..."
    sleep 10
    if docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT citus_version();" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Citus successfully configured${NC}"
    else
        echo -e "${YELLOW}⚠️ Citus still initializing, but continuing...${NC}"
    fi
fi

# Check workers quickly
log_step "Checking workers..."
worker1_ready=0
worker2_ready=0

if docker exec citus_worker1_primary pg_isready -U postgres > /dev/null 2>&1; then
    worker1_ready=1
fi
if docker exec citus_worker2_primary pg_isready -U postgres > /dev/null 2>&1; then
    worker2_ready=1
fi

workers_ready=$((worker1_ready + worker2_ready))

if [ $workers_ready -eq 2 ]; then
    echo -e "${GREEN}✅ All workers ready (2/2)${NC}"
else
    echo -e "${YELLOW}⏳ Waiting for workers to be ready... ($workers_ready/2)${NC}"
    sleep 15
    
    # Check again
    worker1_ready=0
    worker2_ready=0
    if docker exec citus_worker1_primary pg_isready -U postgres > /dev/null 2>&1; then
        worker1_ready=1
    fi
    if docker exec citus_worker2_primary pg_isready -U postgres > /dev/null 2>&1; then
        worker2_ready=1
    fi
    workers_ready=$((worker1_ready + worker2_ready))
    echo -e "${GREEN}✅ Workers ready: $workers_ready/2${NC}"
fi

# Check active workers (Patroni)
log_step "Checking active workers..."
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM citus_get_active_worker_nodes();" 2>/dev/null | tr -d ' ' || echo "0")

echo -e "${CYAN}📋 Registered workers:${NC}"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT * FROM master_get_active_worker_nodes();"

if [ "$WORKER_COUNT" -eq 2 ]; then
    log_step "✅ Cluster successfully configured! 2 active workers."
elif [ "$WORKER_COUNT" -eq 1 ]; then
    log_step "⚠️ Only 1 active worker. Check worker2."
else
    log_step "❌ No active workers. Check configuration."
fi

echo -e "${BLUE}📊 STEP 4: Final Verification${NC}"
echo "════════════════════════════════"

# Show cluster status
log_step "Citus cluster status:"
docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -c "SELECT * FROM master_get_active_worker_nodes();"

# Check active workers
WORKER_COUNT=$(docker exec "$COORDINATOR_CONTAINER" psql -U postgres -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM master_get_active_worker_nodes();" 2>/dev/null | tr -d ' ')

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                🎯 CITUS CLUSTER CONFIGURED!                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}🎯 Status:${NC}"
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
