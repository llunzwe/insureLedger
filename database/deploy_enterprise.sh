#!/bin/bash
# =============================================================================
# INSURE LEDGER ENTERPRISE KERNEL - DEPLOYMENT SCRIPT
# =============================================================================
# Description: Automated deployment of the complete enterprise kernel with
#              all 24 primitives.
# Usage: ./deploy_enterprise.sh [database_name] [username] [host] [port]
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DB_NAME="${1:-insureledger}"
DB_USER="${2:-postgres}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}"
echo "======================================================================"
echo "  INSURE LEDGER ENTERPRISE KERNEL - DEPLOYMENT"
echo "======================================================================"
echo -e "${NC}"
echo "  Database: $DB_NAME"
echo "  User:     $DB_USER"
echo "  Host:     $DB_HOST:$DB_PORT"
echo "  Script:   $SCRIPT_DIR"
echo "======================================================================"

# Check PostgreSQL connection
echo ""
echo -e "${YELLOW}Checking PostgreSQL connection...${NC}"
if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to PostgreSQL${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connection successful${NC}"

# Check required extensions
echo ""
echo -e "${YELLOW}Checking required extensions...${NC}"
REQUIRED_EXTENSIONS=("uuid-ossp" "pgcrypto" "btree_gist" "ltree")
for ext in "${REQUIRED_EXTENSIONS[@]}"; do
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tc "SELECT 1 FROM pg_available_extensions WHERE name = '$ext';" | grep -q 1; then
        echo -e "${GREEN}✓ Extension '$ext' available${NC}"
    else
        echo -e "${RED}✗ Extension '$ext' not available${NC}"
        echo "  Install with: sudo apt-get install postgresql-contrib"
        exit 1
    fi
done

# Check if database exists
echo ""
echo -e "${YELLOW}Checking database '$DB_NAME'...${NC}"
if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" | grep -q 1; then
    echo -e "${YELLOW}  Database exists${NC}"
    read -p "  Drop and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "  Dropping database..."
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
        echo "  Creating database..."
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\";"
    fi
else
    echo "  Creating database..."
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\";"
fi
echo -e "${GREEN}✓ Database ready${NC}"

# Enable extensions
echo ""
echo -e "${YELLOW}Enabling extensions...${NC}"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
    CREATE EXTENSION IF NOT EXISTS \"pgcrypto\";
    CREATE EXTENSION IF NOT EXISTS \"btree_gist\";
    CREATE EXTENSION IF NOT EXISTS \"ltree\";
" > /dev/null 2>&1
echo -e "${GREEN}✓ Extensions enabled${NC}"

# Function to deploy SQL file
deploy_file() {
    local file=$1
    local desc=$2
    echo -e "${BLUE}  → $desc${NC}"
    if [ -f "$SCRIPT_DIR/$file" ]; then
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SCRIPT_DIR/$file" -v ON_ERROR_STOP=1 > /dev/null 2>&1; then
            echo -e "${GREEN}    ✓ $file${NC}"
        else
            echo -e "${RED}    ✗ Failed to deploy $file${NC}"
            exit 1
        fi
    else
        echo -e "${RED}    ✗ File not found: $file${NC}"
        exit 1
    fi
}

# Deploy phases

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 1: Foundation${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "01_schema_setup.sql" "Schema Setup and Extensions"
deploy_file "02_crypto_utilities.sql" "Cryptographic Utilities"
deploy_file "03_base_entities.sql" "Base Entities"
deploy_file "04_core_primitives_part1.sql" "Core Primitives - Part 1"
deploy_file "04_core_primitives_part2.sql" "Core Primitives - Part 2"
deploy_file "04_core_primitives_part3.sql" "Core Primitives - Part 3"
deploy_file "04_core_primitives_part4.sql" "Core Primitives - Part 4"
deploy_file "05_audit_immutability.sql" "Audit Triggers and Immutability"
deploy_file "06_rls_policies.sql" "Row Level Security"
deploy_file "07_stored_procedures.sql" "Stored Procedures"
deploy_file "08_indexes_constraints.sql" "Indexes and Performance"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 2: Accounting & Value Movement${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "10_primitive_4_5_value_accounting.sql" "Value Containers and Double-Entry"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 3: Event Store & Transactions${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "11_primitive_6_7_datomic_transaction.sql" "Datomic Indexes and Transaction Lifecycle"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 4: Contracts & Authorization${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "12_primitive_8_9_contract_auth.sql" "Product Contracts and Real-Time Posting"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 5: Reconciliation & Batch Processing${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "13_primitive_14_15_recon_batch.sql" "Suspense, Reconciliation, and EOD"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 6: Geography & Documents${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "14_primitive_17_18_geo_docs.sql" "Jurisdictions and Document Management"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 7: Sub-Ledger & Capital${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "15_primitive_19_20_ledger_capital.sql" "Client Money and Capital Tracking"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 8: Streaming, Caching & Archival${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "16_primitive_21_22_23_streaming_caching_archival.sql" "Mutation Log, Caching, and Cold Storage"

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  PHASE 9: Entitlements & Health${NC}"
echo -e "${BLUE}======================================================================${NC}"
deploy_file "17_primitive_16_24_entitlements_health.sql" "Granular Entitlements and Health Checks"

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}  DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}======================================================================${NC}"

# Load seed data
read -p "Load seed data? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${YELLOW}Loading seed data...${NC}"
    deploy_file "09_seed_data.sql" "Seed Data"
    echo -e "${GREEN}✓ Seed data loaded${NC}"
fi

# Verification
echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  VERIFICATION${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Count components
TABLE_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tc "
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema IN ('kernel', 'security', 'audit') 
    AND table_type = 'BASE TABLE';
" | xargs)

FUNCTION_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tc "
    SELECT COUNT(*) FROM pg_proc p 
    JOIN pg_namespace n ON p.pronamespace = n.oid 
    WHERE n.nspname IN ('kernel', 'security', 'audit', 'crypto', 'temporal');
" | xargs)

INDEX_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tc "
    SELECT COUNT(*) FROM pg_indexes 
    WHERE schemaname IN ('kernel', 'security', 'audit');
" | xargs)

echo "  Tables:         $TABLE_COUNT"
echo "  Functions:      $FUNCTION_COUNT"
echo "  Indexes:        $INDEX_COUNT"

# Run health check
echo ""
echo -e "${YELLOW}Running health check...${NC}"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    SELECT component, status::text 
    FROM kernel.health_check_full()
    LIMIT 10;
" 2>/dev/null | sed 's/^/  /' || echo "  Health check completed"

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}  ENTERPRISE KERNEL READY${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo ""
echo "  Next steps:"
echo "    1. Connect: psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
echo "    2. Status:  SELECT * FROM kernel.system_status;"
echo "    3. Health:  SELECT * FROM kernel.health_check_full();"
echo "    4. Docs:    cat database/PRIMITIVES_GUIDE.md"
echo ""
echo -e "${GREEN}======================================================================${NC}"
