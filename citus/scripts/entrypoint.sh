#!/bin/bash
set -e

# Entrypoint para containers Patroni + Citus
echo "🚀 Iniciando ${PATRONI_NAME:-unknown}..."
echo "   Grupo: ${PATRONI_CITUS_GROUP:-0}"
echo "   Scope: ${PATRONI_SCOPE:-citus-cluster}"

# Verificar qual serviço executar
case "${1:-patroni}" in
    "haproxy")
        echo "🔀 Iniciando HAProxy..."
        
        # Aguardar alguns nodes estarem disponíveis
        echo "⏳ Aguardando Patroni nodes..."
        sleep 10
        
        # Configuração HAProxy dinâmica básica
        cat > /etc/haproxy/haproxy.cfg << 'EOF'
global
    stats socket /run/haproxy/admin.sock mode 660 level admin
    log stdout local0 info

defaults
    mode tcp
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

frontend coordinator_frontend
    bind *:5000
    default_backend coordinator_primary

backend coordinator_primary
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
    server coordinator1 coordinator1:5432 check port 8008
    server coordinator2 coordinator2:5432 check port 8008 backup
    server coordinator3 coordinator3:5432 check port 8008 backup

listen stats
    bind *:8404
    stats enable
    stats uri /
EOF
        
        exec haproxy -f /etc/haproxy/haproxy.cfg -db
        ;;
    
    "patroni"|*)
        echo "🐘 Iniciando Patroni com PostgreSQL + Citus..."
        
        # Aguardar etcd estar disponível (simplificado)
        echo "⏳ Aguardando etcd ficar pronto..."
        sleep 15
        
        # Criar configuração Patroni dinamicamente
        cat > /tmp/patroni.yml << EOF
scope: ${PATRONI_SCOPE:-citus-cluster}
name: ${PATRONI_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${PATRONI_NAME}:8008

etcd3:
  hosts: ${PATRONI_ETCD3_HOSTS}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      pg_hba:
        - local all all trust
        - host replication replicator 0.0.0.0/0 md5
        - host all all 0.0.0.0/0 md5
      parameters:
        shared_preload_libraries: citus
        max_connections: 100
        shared_buffers: 128MB
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        max_prepared_transactions: 200

  initdb:
    - encoding: UTF8
    - locale: en_US.UTF-8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${PATRONI_NAME}:5432
  data_dir: /home/postgres/data
  authentication:
    replication:
      username: replicator
      password: replicator-password
    superuser:
      username: postgres
      password: ${POSTGRES_PASSWORD:-postgres}

citus:
  database: ${PATRONI_CITUS_DATABASE:-citus}
  group: ${PATRONI_CITUS_GROUP:-0}

tags:
  nofailover: false
  noloadbalance: false
EOF
        
        # Executar Patroni
        exec python3 /usr/local/bin/patroni /tmp/patroni.yml
        ;;
esac
