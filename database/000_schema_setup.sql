-- =============================================================================
-- FILE: 000_schema_setup.sql
-- PURPOSE: Foundation - Create schemas, enable extensions, define ENUM types
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 8601 (timestamps), PostgreSQL 14+
-- DEPENDENCIES: None (first file to run)
-- =============================================================================

-- =============================================================================
-- EXTENSIONS
-- =============================================================================

-- Core extensions for UUID and cryptography
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gist";

-- Hierarchy support for account paths
CREATE EXTENSION IF NOT EXISTS "ltree";

-- Optional: TimescaleDB for time-series data (comment out if not available)
-- CREATE EXTENSION IF NOT EXISTS "timescaledb";

-- Optional: PostGIS for geographic data (comment out if not available)
-- CREATE EXTENSION IF NOT EXISTS "postgis";

-- =============================================================================
-- SCHEMAS
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS kernel;
COMMENT ON SCHEMA kernel IS 'Core immutable ledger entities and business logic. All tables implement bitemporal tracking, cryptographic chaining, and append-only immutability.';

CREATE SCHEMA IF NOT EXISTS security;
COMMENT ON SCHEMA security IS 'Access control, RBAC, entitlements, digital signatures, and key management. Implements ISO 27001 security controls.';

CREATE SCHEMA IF NOT EXISTS audit;
COMMENT ON SCHEMA audit IS 'Audit trails, compliance logs, and forensic records. Immutable append-only logs with hash chain verification.';

CREATE SCHEMA IF NOT EXISTS crypto;
COMMENT ON SCHEMA crypto IS 'Cryptographic functions, hashing utilities, and verification procedures. Supports post-quantum readiness.';

CREATE SCHEMA IF NOT EXISTS temporal;
COMMENT ON SCHEMA temporal IS 'Bitemporal time tracking support functions and utilities per ISO 8601.';

CREATE SCHEMA IF NOT EXISTS test;
COMMENT ON SCHEMA test IS 'Testing and verification functions. Not for production use.';

-- =============================================================================
-- ENUM TYPES - Foundation
-- =============================================================================

-- ISO 4217 Currency codes will be validated via CHECK constraints or lookup table
-- Core type definitions

-- Device types (constrained to allowed list per specification)
CREATE TYPE kernel.device_type AS ENUM (
    'desktop',
    'laptop', 
    'tablet',
    'smartphone',
    'smartwatch',
    'other'
);
COMMENT ON TYPE kernel.device_type IS 'Allowed device types for digital twin registry';

-- Participant types in the ecosystem
CREATE TYPE kernel.participant_type AS ENUM (
    'customer',
    'insurer',
    'oem',
    'ecommerce_platform',
    'technician',
    'regulator',
    'certification_body',
    'custodian',
    'broker'
);
COMMENT ON TYPE kernel.participant_type IS 'Actor types in the insureLedger ecosystem';

-- Business types for technician tenants
CREATE TYPE kernel.business_type AS ENUM (
    'individual',
    'shop',
    'chain'
);

-- Datom operations for event store
CREATE TYPE kernel.datom_operation AS ENUM (
    'assert',
    'retract'
);

-- Core status types
CREATE TYPE kernel.active_status AS ENUM (
    'active',
    'inactive',
    'suspended',
    'pending'
);

-- Bitemporal validity types
CREATE TYPE kernel.temporal_status AS ENUM (
    'current',
    'superseded',
    'future',
    'expired'
);

-- =============================================================================
-- SYSTEM VERSION TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS kernel.schema_version (
    version_id BIGSERIAL PRIMARY KEY,
    major_version INTEGER NOT NULL,
    minor_version INTEGER NOT NULL,
    patch_version INTEGER NOT NULL,
    version_name TEXT,
    deployed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    deployed_by TEXT DEFAULT CURRENT_USER,
    deployment_notes TEXT,
    checksum TEXT  -- Hash of all schema files
);

-- Insert initial version
INSERT INTO kernel.schema_version (major_version, minor_version, patch_version, version_name, deployment_notes)
VALUES (2, 0, 0, 'Enterprise Edition', 'Initial enterprise deployment with 24 primitives')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- INITIALIZATION COMPLETE
-- =============================================================================

SELECT 'Schema foundation created successfully' AS status;
