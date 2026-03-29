-- =============================================================================
-- FILE: 013_datoms.sql
-- PURPOSE: Primitive 6 - Datoms (Event Store)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Append-only log, Content-addressed storage
-- DEPENDENCIES: 002_crypto_utilities.sql, 003_base_entities.sql
-- =============================================================================

-- =============================================================================
-- DATOMS TABLE - The core append-only event store
-- =============================================================================

CREATE TYPE kernel.operation_type AS ENUM (
    'create',
    'update',
    'delete',
    'patch',
    'upsert'
);

CREATE TABLE kernel.datoms (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    -- Identity
    datom_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    entity_id UUID NOT NULL,  -- The entity this datom belongs to
    attribute TEXT NOT NULL,  -- The attribute/property name
    
    -- Value (content-addressed)
    value JSONB,              -- Structured value (JSONB for flexibility)
    value_text TEXT,          -- Text representation for string values
    value_type VARCHAR(32) NOT NULL,  -- string, number, boolean, json, ref, blob
    value_hash TEXT,          -- SHA-256 of value for content addressing
    
    -- Operation
    operation kernel.operation_type NOT NULL,
    
    -- Temporal
    transaction_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Chain of custody
    previous_datom_hash TEXT,
    current_hash TEXT NOT NULL,
    
    -- Provenance
    participant_id UUID REFERENCES kernel.participants(participant_id),
    device_id UUID REFERENCES kernel.devices(device_id),
    session_id UUID,
    
    -- Source
    source_system TEXT,       -- Which system generated this datom
    source_version TEXT,      -- Version of the source system
    
    -- Metadata
    metadata JSONB,           -- Additional context
    tags TEXT[],              -- Queryable tags
    
    -- Ordering (strict sequence within entity)
    sequence_number BIGINT GENERATED ALWAYS AS IDENTITY,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

COMMENT ON TABLE kernel.datoms IS 'Append-only event store - the immutable ledger of all state changes';

-- Critical indexes for the event store
CREATE INDEX idx_datoms_entity ON kernel.datoms(entity_id, attribute, transaction_time DESC);
CREATE INDEX idx_datoms_attribute ON kernel.datoms(attribute, value_hash);
CREATE INDEX idx_datoms_transaction_time ON kernel.datoms(transaction_time);
CREATE INDEX idx_datoms_current_hash ON kernel.datoms(current_hash);
CREATE INDEX idx_datoms_tags ON kernel.datoms USING GIN(tags);

-- Partition by transaction time for scalability
-- CREATE TABLE kernel.datoms_2024q1 PARTITION OF kernel.datoms
--     FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

-- =============================================================================
-- ENTITY SNAPSHOTS - Materialized views of current state
-- =============================================================================

CREATE TABLE kernel.entity_snapshots (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    entity_id UUID NOT NULL UNIQUE,
    entity_type TEXT NOT NULL,
    
    -- Current state (all attributes as JSON)
    current_state JSONB NOT NULL DEFAULT '{}',
    
    -- Datoms that make up this state
    datom_ids UUID[] NOT NULL DEFAULT '{}',
    
    -- Chain info
    first_datom_id UUID,
    last_datom_id UUID,
    datom_count INTEGER DEFAULT 0,
    
    -- Versioning
    version INTEGER DEFAULT 1,
    
    -- Temporal
    first_seen_at TIMESTAMP WITH TIME ZONE,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    -- Audit
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_entity_snapshots_entity ON kernel.entity_snapshots(entity_id);
CREATE INDEX idx_entity_snapshots_type ON kernel.entity_snapshots(entity_type);

-- =============================================================================
-- MERKLE TREE FOR DATOMS
-- =============================================================================

CREATE TABLE kernel.datom_merkle_nodes (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    level INTEGER NOT NULL,           -- 0 = leaf, 1+ = branch
    position BIGINT NOT NULL,         -- Position in this level
    
    -- Hashes
    left_child_hash TEXT,
    right_child_hash TEXT,
    node_hash TEXT NOT NULL,          -- Hash of children or datom
    
    -- Reference to datoms (for leaves)
    datom_ids UUID[],                 -- Datom IDs in this subtree
    
    -- Temporal window
    start_time TIMESTAMP WITH TIME ZONE,
    end_time TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(level, position)
);

CREATE INDEX idx_datom_merkle_nodes_level ON kernel.datom_merkle_nodes(level, position);
CREATE INDEX idx_datom_merkle_nodes_hash ON kernel.datom_merkle_nodes(node_hash);

-- =============================================================================
-- TRANSACTIONS - Grouping datoms
-- =============================================================================

CREATE TABLE kernel.datom_transactions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    transaction_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Transaction metadata
    description TEXT,
    participant_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Atomic datom set
    datom_ids UUID[] NOT NULL DEFAULT '{}',
    datom_count INTEGER DEFAULT 0,
    
    -- Transaction hash (Merkle root of datoms)
    transaction_hash TEXT,
    
    -- Status
    status VARCHAR(32) DEFAULT 'pending',  -- pending, committed, aborted
    
    -- Timing
    started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    committed_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Write a datom
CREATE OR REPLACE FUNCTION kernel.write_datom(
    p_entity_id UUID,
    p_attribute TEXT,
    p_value JSONB,
    p_value_type VARCHAR(32) DEFAULT 'json',
    p_operation kernel.operation_type DEFAULT 'upsert',
    p_metadata JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_datom_id UUID;
    v_value_hash TEXT;
    v_previous_hash TEXT;
    v_current_hash TEXT;
    v_value_text TEXT;
BEGIN
    -- Convert value to text for hashing
    v_value_text := p_value::TEXT;
    
    -- Calculate value hash
    v_value_hash := encode(digest(v_value_text, 'sha256'), 'hex');
    
    -- Get previous hash for this entity
    SELECT current_hash INTO v_previous_hash
    FROM kernel.datoms
    WHERE entity_id = p_entity_id
    ORDER BY sequence_number DESC
    LIMIT 1;
    
    -- Calculate current hash (chains all previous)
    v_current_hash := encode(digest(
        COALESCE(v_previous_hash, '') || 
        p_entity_id::TEXT || 
        p_attribute || 
        v_value_hash || 
        NOW()::TEXT,
        'sha256'
    ), 'hex');
    
    INSERT INTO kernel.datoms (
        entity_id, attribute, value, value_text, value_type, value_hash,
        operation, previous_datom_hash, current_hash,
        participant_id, metadata
    ) VALUES (
        p_entity_id, p_attribute, p_value, v_value_text, p_value_type, v_value_hash,
        p_operation, v_previous_hash, v_current_hash,
        security.get_participant_context(), p_metadata
    )
    RETURNING datom_id INTO v_datom_id;
    
    -- Update entity snapshot
    PERFORM kernel.update_entity_snapshot(p_entity_id);
    
    RETURN v_datom_id;
END;
$$ LANGUAGE plpgsql;

-- Update entity snapshot (rebuild from datoms)
CREATE OR REPLACE FUNCTION kernel.update_entity_snapshot(p_entity_id UUID)
RETURNS VOID AS $$
DECLARE
    v_entity_type TEXT;
    v_state JSONB := '{}';
    v_datom_ids UUID[] := '{}';
    v_first_datom UUID;
    v_last_datom UUID;
    v_count INTEGER;
BEGIN
    -- Build current state from all datoms for this entity
    SELECT 
        jsonb_object_agg(d.attribute, 
            CASE d.value_type
                WHEN 'json' THEN COALESCE(d.value, '{}'::JSONB)
                WHEN 'number' THEN to_jsonb((d.value_text)::numeric)
                WHEN 'boolean' THEN to_jsonb((d.value_text)::boolean)
                WHEN 'string' THEN to_jsonb(d.value_text)
                ELSE COALESCE(d.value, to_jsonb(d.value_text))
            END
        ),
        array_agg(d.datom_id ORDER BY d.sequence_number),
        min(d.datom_id),
        max(d.datom_id),
        count(*)
    INTO v_state, v_datom_ids, v_first_datom, v_last_datom, v_count
    FROM (
        SELECT DISTINCT ON (attribute) *
        FROM kernel.datoms
        WHERE entity_id = p_entity_id
          AND operation != 'delete'
        ORDER BY attribute, sequence_number DESC
    ) d;
    
    -- Detect entity type from attributes
    SELECT entity_type INTO v_entity_type
    FROM kernel.entity_snapshots
    WHERE entity_id = p_entity_id;
    
    IF v_entity_type IS NULL THEN
        v_entity_type := 'unknown';
    END IF;
    
    -- Upsert snapshot
    INSERT INTO kernel.entity_snapshots (
        entity_id, entity_type, current_state, datom_ids,
        first_datom_id, last_datom_id, datom_count,
        first_seen_at, last_modified_at
    ) VALUES (
        p_entity_id, v_entity_type, v_state, v_datom_ids,
        v_first_datom, v_last_datom, v_count,
        NOW(), NOW()
    )
    ON CONFLICT (entity_id) DO UPDATE SET
        current_state = EXCLUDED.current_state,
        datom_ids = EXCLUDED.datom_ids,
        last_datom_id = EXCLUDED.last_datom_id,
        datom_count = EXCLUDED.datom_count,
        version = kernel.entity_snapshots.version + 1,
        last_modified_at = NOW();
END;
$$ LANGUAGE plpgsql;

-- Get entity state at a point in time
CREATE OR REPLACE FUNCTION kernel.get_entity_state_at(
    p_entity_id UUID,
    p_timestamp TIMESTAMP WITH TIME ZONE
)
RETURNS JSONB AS $$
DECLARE
    v_state JSONB;
BEGIN
    SELECT jsonb_object_agg(d.attribute, 
        CASE d.value_type
            WHEN 'json' THEN d.value::jsonb
            WHEN 'number' THEN to_jsonb(d.value::numeric)
            WHEN 'boolean' THEN to_jsonb(d.value::boolean)
            ELSE to_jsonb(d.value)
        END
    )
    INTO v_state
    FROM (
        SELECT DISTINCT ON (attribute) *
        FROM kernel.datoms
        WHERE entity_id = p_entity_id
          AND transaction_time <= p_timestamp
          AND operation != 'delete'
        ORDER BY attribute, transaction_time DESC
    ) d;
    
    RETURN v_state;
END;
$$ LANGUAGE plpgsql;

-- Verify chain integrity
CREATE OR REPLACE FUNCTION kernel.verify_datom_chain(p_entity_id UUID)
RETURNS TABLE(
    is_valid BOOLEAN,
    broken_at_sequence BIGINT,
    expected_hash TEXT,
    actual_hash TEXT
) AS $$
DECLARE
    v_prev_hash TEXT := '';
    v_calc_hash TEXT;
    v_rec RECORD;
    v_valid BOOLEAN := TRUE;
    v_broken_seq BIGINT;
    v_expected TEXT;
    v_actual TEXT;
BEGIN
    FOR v_rec IN 
        SELECT * FROM kernel.datoms 
        WHERE entity_id = p_entity_id 
        ORDER BY sequence_number
    LOOP
        v_calc_hash := encode(digest(
            v_prev_hash || 
            v_rec.entity_id::TEXT || 
            v_rec.attribute || 
            v_rec.value_hash || 
            v_rec.transaction_time::TEXT,
            'sha256'
        ), 'hex');
        
        IF v_calc_hash != v_rec.current_hash THEN
            v_valid := FALSE;
            v_broken_seq := v_rec.sequence_number;
            v_expected := v_calc_hash;
            v_actual := v_rec.current_hash;
            EXIT;
        END IF;
        
        v_prev_hash := v_rec.current_hash;
    END LOOP;
    
    RETURN QUERY SELECT v_valid, v_broken_seq, v_expected, v_actual;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 6: Datoms (Event Store) initialized' AS status;
