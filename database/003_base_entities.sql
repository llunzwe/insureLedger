-- =============================================================================
-- FILE: 003_base_entities.sql
-- PURPOSE: Common table columns template, bitemporal utilities, tenant context
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 8601 (bitemporal), RFC 4122 (UUID)
-- DEPENDENCIES: 000, 001, 002
-- =============================================================================

-- =============================================================================
-- TEMPORAL UTILITY FUNCTIONS
-- =============================================================================

-- Maximum timestamp for "infinity" in bitemporal modeling
CREATE OR REPLACE FUNCTION temporal.max_timestamp()
RETURNS TIMESTAMP WITH TIME ZONE AS $$
BEGIN
    RETURN '9999-12-31 23:59:59.999999+00'::TIMESTAMP WITH TIME ZONE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION temporal.max_timestamp() IS 'Maximum timestamp representing infinity in bitemporal modeling';

-- Check if a record is currently valid (business time)
CREATE OR REPLACE FUNCTION temporal.is_valid_now(
    p_valid_from TIMESTAMP WITH TIME ZONE,
    p_valid_to TIMESTAMP WITH TIME ZONE
)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (p_valid_from <= NOW() OR p_valid_from IS NULL)
       AND (p_valid_to > NOW() OR p_valid_to IS NULL);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION temporal.is_valid_now(TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE) 
IS 'Check if record is currently valid in business time (valid time)';

-- Check if a record is currently active (system time)
CREATE OR REPLACE FUNCTION temporal.is_active_now(
    p_system_from TIMESTAMP WITH TIME ZONE,
    p_system_to TIMESTAMP WITH TIME ZONE
)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (p_system_from <= NOW() OR p_system_from IS NULL)
       AND (p_system_to > NOW() OR p_system_to IS NULL);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION temporal.is_active_now(TIMESTAMP WITH TIME ZONE, TIMESTAMP WITH TIME ZONE) 
IS 'Check if record is currently active in system time (audit time)';

-- Get current business date considering timezone
CREATE OR REPLACE FUNCTION temporal.current_business_date(p_timezone TEXT DEFAULT 'UTC')
RETURNS DATE AS $$
BEGIN
    RETURN (NOW() AT TIME ZONE p_timezone)::DATE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- TENANT CONTEXT MANAGEMENT
-- =============================================================================

-- Session context table for tracking current session
CREATE TABLE IF NOT EXISTS security.session_context (
    session_id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    participant_id UUID,
    tenant_id UUID,
    ip_address_hash TEXT,  -- Hashed IP for audit
    user_agent_hash TEXT,  -- Hashed user agent
    session_start TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    session_end TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,
    jwt_token_hash TEXT  -- Hash of JWT for validation
);

COMMENT ON TABLE security.session_context IS 'Active session tracking for context management';

-- Function to set tenant context for RLS
CREATE OR REPLACE FUNCTION security.set_tenant_context(p_tenant_id UUID)
RETURNS VOID AS $$
BEGIN
    PERFORM set_config('app.current_tenant_id', p_tenant_id::TEXT, FALSE);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION security.set_tenant_context(UUID) IS 'Set tenant ID for Row-Level Security policies';

-- Function to get current tenant context
CREATE OR REPLACE FUNCTION security.get_tenant_context()
RETURNS UUID AS $$
DECLARE
    v_tenant_id TEXT;
BEGIN
    v_tenant_id := current_setting('app.current_tenant_id', TRUE);
    RETURN CASE WHEN v_tenant_id IS NULL OR v_tenant_id = '' 
                THEN NULL 
                ELSE v_tenant_id::UUID 
           END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION security.get_tenant_context() IS 'Get current tenant ID from session context';

-- Function to set participant context
CREATE OR REPLACE FUNCTION security.set_participant_context(p_participant_id UUID)
RETURNS VOID AS $$
BEGIN
    PERFORM set_config('app.current_participant_id', p_participant_id::TEXT, FALSE);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION security.set_participant_context(UUID) IS 'Set participant ID for audit and RLS';

-- Function to get current participant context
CREATE OR REPLACE FUNCTION security.get_participant_context()
RETURNS UUID AS $$
DECLARE
    v_participant_id TEXT;
BEGIN
    v_participant_id := current_setting('app.current_participant_id', TRUE);
    RETURN CASE WHEN v_participant_id IS NULL OR v_participant_id = '' 
                THEN NULL 
                ELSE v_participant_id::UUID 
           END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION security.get_participant_context() IS 'Get current participant ID from session context';

-- =============================================================================
-- IMMUTABILITY ENFORCEMENT
-- =============================================================================

-- Function to prevent updates on immutable tables
CREATE OR REPLACE FUNCTION kernel.prevent_update()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Immutable table: Updates are not allowed. Insert a new version instead.'
        USING HINT = 'This table uses append-only immutability. Use versioning functions.',
              ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.prevent_update() IS 'Trigger function to prevent updates on immutable tables';

-- Function to prevent deletes on immutable tables
CREATE OR REPLACE FUNCTION kernel.prevent_delete()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Immutable table: Deletions are not allowed.'
        USING HINT = 'This table uses append-only immutability. Records are preserved for audit.',
              ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.prevent_delete() IS 'Trigger function to prevent deletions on immutable tables';

-- =============================================================================
-- ENTITY STREAM TRACKING
-- =============================================================================

-- Table to track entity streams for hash chaining
CREATE TABLE kernel.entity_streams (
    stream_id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    entity_type VARCHAR(64) NOT NULL,
    entity_id UUID NOT NULL,
    stream_purpose VARCHAR(64) DEFAULT 'versions',  -- versions, audit, state
    genesis_hash TEXT NOT NULL,
    current_hash TEXT NOT NULL,
    record_count BIGINT DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE (entity_type, entity_id, stream_purpose)
);

COMMENT ON TABLE kernel.entity_streams IS 'Tracks hash chains for entity versioning and audit trails';

CREATE INDEX idx_entity_streams_entity ON kernel.entity_streams(entity_type, entity_id);

-- Initialize an entity stream
CREATE OR REPLACE FUNCTION kernel.init_entity_stream(
    p_entity_type TEXT,
    p_entity_id UUID,
    p_purpose TEXT DEFAULT 'versions'
)
RETURNS UUID AS $$
DECLARE
    v_stream_id UUID;
    v_genesis_hash TEXT;
BEGIN
    v_genesis_hash := crypto.sha256_hash(
        'genesis:' || p_entity_type || ':' || p_entity_id::TEXT || ':' || p_purpose
    );
    
    INSERT INTO kernel.entity_streams (
        entity_type, entity_id, stream_purpose, genesis_hash, current_hash
    ) VALUES (
        p_entity_type, p_entity_id, p_purpose, v_genesis_hash, v_genesis_hash
    )
    ON CONFLICT (entity_type, entity_id, stream_purpose) DO NOTHING
    RETURNING stream_id INTO v_stream_id;
    
    RETURN v_stream_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.init_entity_stream(TEXT, UUID, TEXT) IS 'Initialize a new hash chain for an entity';

-- Get next hash for entity stream
CREATE OR REPLACE FUNCTION kernel.get_next_chain_hash(
    p_stream_id UUID,
    p_record_data JSONB
)
RETURNS TEXT AS $$
DECLARE
    v_current_hash TEXT;
    v_new_hash TEXT;
BEGIN
    SELECT current_hash INTO v_current_hash
    FROM kernel.entity_streams
    WHERE stream_id = p_stream_id;
    
    IF v_current_hash IS NULL THEN
        RAISE EXCEPTION 'Entity stream not found: %', p_stream_id;
    END IF;
    
    v_new_hash := crypto.chain_hash(v_current_hash, p_record_data);
    
    -- Update stream
    UPDATE kernel.entity_streams
    SET current_hash = v_new_hash,
        record_count = record_count + 1,
        last_updated = NOW()
    WHERE stream_id = p_stream_id;
    
    RETURN v_new_hash;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.get_next_chain_hash(UUID, JSONB) IS 'Get next hash in entity chain and update stream';

-- =============================================================================
-- COMMON INDEX CREATION HELPER
-- =============================================================================

-- Function to create standard indexes for an entity table
CREATE OR REPLACE FUNCTION kernel.create_entity_indexes(
    p_schema TEXT,
    p_table TEXT
)
RETURNS VOID AS $$
BEGIN
    -- Bitemporal indexes
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_system_time ON %I.%I (system_from, system_to) WHERE system_to IS NULL',
        p_table, p_schema, p_table
    );
    
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_valid_time ON %I.%I (valid_from, valid_to)',
        p_table, p_schema, p_table
    );
    
    -- Creator index
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_created_by ON %I.%I (created_by)',
        p_table, p_schema, p_table
    );
    
    -- Tenant index (if applicable)
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = p_schema
          AND table_name = p_table
          AND column_name = 'tenant_id'
    ) THEN
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS idx_%s_tenant ON %I.%I (tenant_id) WHERE tenant_id IS NOT NULL',
            p_table, p_schema, p_table
        );
    END IF;
    
    -- Current record index
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_current ON %I.%I (id) WHERE system_to IS NULL',
        p_table, p_schema, p_table
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.create_entity_indexes(TEXT, TEXT) IS 'Create standard bitemporal indexes for entity tables';

-- =============================================================================
-- SYSTEM CONFIGURATION
-- =============================================================================

CREATE TABLE IF NOT EXISTS kernel.system_config (
    config_key VARCHAR(128) PRIMARY KEY,
    config_value JSONB NOT NULL,
    description TEXT,
    is_encrypted BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_by UUID
);

COMMENT ON TABLE kernel.system_config IS 'System-wide configuration settings';

-- Insert default configuration
INSERT INTO kernel.system_config (config_key, config_value, description)
VALUES 
    ('ledger_version', '{"major": 2, "minor": 0, "patch": 0}', 'Ledger kernel version'),
    ('hash_algorithm', '{"algorithm": "SHA-256", "encoding": "hex"}', 'Cryptographic hash settings'),
    ('bitemporal_enabled', '{"enabled": true}', 'Bitemporal tracking status'),
    ('anchoring_interval_minutes', '{"value": 60}', 'Merkle tree anchoring interval'),
    ('max_audit_retention_days', '{"value": 2555}', 'Maximum audit log retention (7 years)'),
    ('default_timezone', '{"value": "UTC"}', 'Default system timezone'),
    ('require_dual_authorization_above', '{"value": 10000, "currency": "USD"}', 'Amount requiring 4-eyes'),
    ('velocity_check_enabled', '{"enabled": true}', 'Enable velocity limit checks'),
    ('streaming_enabled', '{"enabled": true}', 'Enable real-time mutation streaming'),
    ('compression_enabled', '{"enabled": true, "after_days": 7}', 'Enable TimescaleDB compression')
ON CONFLICT (config_key) DO NOTHING;

-- =============================================================================
-- INITIALIZATION COMPLETE
-- =============================================================================

SELECT 'Base entities and utilities initialized' AS status;
