#!/bin/bash
# =============================================================================
# INSURE LEDGER KERNEL - DEPLOYMENT SCRIPT
# =============================================================================
# Description: Automated deployment and verification script
# Usage: ./deploy.sh [database_name] [username]
# =============================================================================

set -e  # Exit on error

# Configuration
DB_NAME="${1:-insureledger}"
DB_USER="${2:-postgres}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================================"
echo "  INSURE LEDGER KERNEL - DEPLOYMENT"
echo "======================================================================"
echo "  Database: $DB_NAME"
echo "  User:     $DB_USER"
echo "  Host:     $DB_HOST:$DB_PORT"
echo "  Script:   $SCRIPT_DIR"
echo "======================================================================"

# Check PostgreSQL connection
echo ""
echo "Checking PostgreSQL connection..."
if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to PostgreSQL"
    exit 1
fi
echo "✓ Connection successful"

# Check if database exists
echo ""
echo "Checking database '$DB_NAME'..."
if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" | grep -q 1; then
    echo "  Database exists"
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
echo "✓ Database ready"

# Check required extensions
echo ""
echo "Checking required extensions..."
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
    CREATE EXTENSION IF NOT EXISTS \"pgcrypto\";
    CREATE EXTENSION IF NOT EXISTS \"btree_gist\";
"
echo "✓ Extensions ready"

# Deploy schema files
echo ""
echo "Deploying schema files..."

deploy_file() {
    local file=$1
    local desc=$2
    echo "  → $desc"
    if [ -f "$SCRIPT_DIR/$file" ]; then
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SCRIPT_DIR/$file" -v ON_ERROR_STOP=1 > /dev/null 2>&1
        echo "    ✓ $file"
    else
        echo "    ✗ File not found: $file"
        exit 1
    fi
}

deploy_file "01_schema_setup.sql" "Schema Setup and Extensions"
deploy_file "02_crypto_utilities.sql" "Cryptographic Utilities"
deploy_file "03_base_entities.sql" "Base Entities"
deploy_file "04_core_primitives_part1.sql" "Core Primitives - Part 1 (Participants)"
deploy_file "04_core_primitives_part2.sql" "Core Primitives - Part 2 (Insurance)"
deploy_file "04_core_primitives_part3.sql" "Core Primitives - Part 3 (Event Store)"
deploy_file "04_core_primitives_part4.sql" "Core Primitives - Part 4 (Audit & VCs)"
deploy_file "05_audit_immutability.sql" "Audit Triggers and Immutability"
deploy_file "06_rls_policies.sql" "Row Level Security"
deploy_file "07_stored_procedures.sql" "Stored Procedures"
deploy_file "08_indexes_constraints.sql" "Indexes and Performance"

echo ""
echo "✓ Schema deployment complete"

# Load seed data
read -p "Load seed data? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Loading seed data..."
    deploy_file "09_seed_data.sql" "Seed Data"
    echo "✓ Seed data loaded"
fi

# Verification
echo ""
echo "======================================================================"
echo "  VERIFICATION"
echo "======================================================================"

# Count tables
TABLE_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tc "
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema IN ('kernel', 'security', 'audit') 
    AND table_type = 'BASE TABLE';
" | xargs)

# Count functions
FUNCTION_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tc "
    SELECT COUNT(*) FROM pg_proc p 
    JOIN pg_namespace n ON p.pronamespace = n.oid 
    WHERE n.nspname IN ('kernel', 'security', 'audit', 'crypto', 'temporal');
" | xargs)

# Count indexes
INDEX_COUNT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tc "
    SELECT COUNT(*) FROM pg_indexes 
    WHERE schemaname IN ('kernel', 'security', 'audit');
" | xargs)

echo "  Tables:    $TABLE_COUNT"
echo "  Functions: $FUNCTION_COUNT"
echo "  Indexes:   $INDEX_COUNT"

# List core tables
echo ""
echo "  Core Tables:"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
    SELECT schemaname, tablename 
    FROM pg_tables 
    WHERE schemaname IN ('kernel', 'security', 'audit')
    ORDER BY schemaname, tablename;
" | grep -E "^\s+(kernel|security|audit)" | sed 's/^/    /'

# Test immutability if seed data loaded
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "  Running immutability tests..."
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
        SELECT * FROM test.verify_immutability();
    " | sed 's/^/    /'
fi

echo ""
echo "======================================================================"
echo "  DEPLOYMENT COMPLETE"
echo "======================================================================"
echo "  Database: $DB_NAME is ready"
echo ""
echo "  Next steps:"
echo "    1. Connect: psql -d $DB_NAME"
echo "    2. View entities: \\dt kernel.*"
echo "    3. View functions: \\df kernel.*"
echo "======================================================================"
