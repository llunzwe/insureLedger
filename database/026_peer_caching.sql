-- =============================================================================
-- FILE: 026_peer_caching.sql
-- PURPOSE: Primitive 22 - Peer Caching & Replication
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Multi-master replication, Edge caching
-- DEPENDENCIES: 013_datoms.sql
-- =============================================================================

-- =============================================================================
-- NODES (Peer registry)
-- =============================================================================

CREATE TYPE kernel.node_type AS ENUM (
    'primary',
    'replica',
    'edge',
    'witness',
    'archive'
);

CREATE TYPE kernel.node_status AS ENUM (
    'active',
    'inactive',
    'syncing',
    'recovering',
    'maintenance',
    'decommissioned'
);

CREATE TABLE kernel.nodes (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    node_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    node_name TEXT UNIQUE NOT NULL,
    
    -- Classification
    node_type kernel.node_type NOT NULL,
    data_center TEXT,  -- AWS region, GCP zone, etc.
    availability_zone TEXT,
    
    -- Network
    host_address INET NOT NULL,
    port INTEGER DEFAULT 5432,
    ssl_enabled BOOLEAN DEFAULT TRUE,
    
    -- Status
    status kernel.node_status DEFAULT 'active',
    last_heartbeat TIMESTAMP WITH TIME ZONE,
    
    -- Replication
    is_replica BOOLEAN DEFAULT FALSE,
    primary_node_id UUID REFERENCES kernel.nodes(node_id),
    replication_lag_seconds INTEGER,
    
    -- Capacity
    storage_capacity_bytes BIGINT,
    storage_used_bytes BIGINT,
    
    -- Metadata
    node_metadata JSONB DEFAULT '{}',
    
    -- Version
    software_version TEXT,
    schema_version INTEGER DEFAULT 1,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_nodes_node ON kernel.nodes(node_id);
CREATE INDEX idx_nodes_status ON kernel.nodes(status);
CREATE INDEX idx_nodes_type ON kernel.nodes(node_type);

-- =============================================================================
-- REPLICATION SLOTS
-- =============================================================================

CREATE TABLE kernel.replication_slots (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    slot_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    slot_name TEXT UNIQUE NOT NULL,
    
    -- Owner
    node_id UUID NOT NULL REFERENCES kernel.nodes(node_id),
    
    -- PostgreSQL replication slot info
    pg_slot_name TEXT,
    plugin TEXT DEFAULT 'pgoutput',
    
    -- Status
    active BOOLEAN DEFAULT TRUE,
    confirmed_lsn TEXT,
    restart_lsn TEXT,
    
    -- Lag tracking
    lag_bytes BIGINT,
    lag_messages INTEGER,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_replication_slots_node ON kernel.replication_slots(node_id);

-- =============================================================================
-- CACHE REGIONS
-- =============================================================================

CREATE TABLE kernel.cache_regions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    region_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    region_name TEXT UNIQUE NOT NULL,
    
    -- Scope
    entity_type VARCHAR(64),  -- Cache specific entity types
    tenant_id UUID,  -- Or specific tenant
    
    -- Configuration
    cache_strategy VARCHAR(32) DEFAULT 'lru',  -- lru, lfu, fifo
    max_size INTEGER DEFAULT 10000,
    ttl_seconds INTEGER DEFAULT 3600,
    
    -- Distribution
    node_ids UUID[],  -- Which nodes cache this region
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- CACHE ENTRIES
-- =============================================================================

CREATE TABLE kernel.cache_entries (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    cache_key TEXT NOT NULL,
    region_id UUID NOT NULL REFERENCES kernel.cache_regions(region_id),
    
    -- Data
    entity_type VARCHAR(64) NOT NULL,
    entity_id UUID,
    cached_data JSONB NOT NULL,
    data_hash TEXT,  -- For validation
    
    -- Metadata
    version INTEGER DEFAULT 1,
    source_node_id UUID REFERENCES kernel.nodes(node_id),
    
    -- TTL
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    last_accessed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    access_count INTEGER DEFAULT 0,
    
    -- Consistency
    is_stale BOOLEAN DEFAULT FALSE,
    stale_reason TEXT,
    
    UNIQUE(cache_key, region_id)
);

CREATE INDEX idx_cache_entries_region ON kernel.cache_entries(region_id, cache_key);
CREATE INDEX idx_cache_entries_expires ON kernel.cache_entries(expires_at) WHERE expires_at < NOW() + INTERVAL '1 hour';
CREATE INDEX idx_cache_entries_entity ON kernel.cache_entries(entity_type, entity_id);

-- =============================================================================
-- CONFLICT RESOLUTION (for multi-master)
-- =============================================================================

CREATE TYPE kernel.conflict_resolution AS ENUM (
    'last_write_wins',
    'first_write_wins',
    'manual_resolution',
    'timestamp_order',
    'vector_clock'
);

CREATE TABLE kernel.conflict_log (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    conflict_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Affected entity
    entity_type VARCHAR(64) NOT NULL,
    entity_id UUID NOT NULL,
    
    -- Conflicting versions
    local_version JSONB NOT NULL,
    remote_version JSONB NOT NULL,
    local_node_id UUID REFERENCES kernel.nodes(node_id),
    remote_node_id UUID REFERENCES kernel.nodes(node_id),
    
    -- Conflict details
    conflict_type VARCHAR(32) NOT NULL,  -- update_update, delete_update, etc.
    conflict_field TEXT,  -- Which field conflicted (NULL = whole record)
    
    -- Resolution
    resolution_strategy kernel.conflict_resolution DEFAULT 'last_write_wins',
    resolved_version JSONB,
    resolved_by UUID,
    resolved_at TIMESTAMP WITH TIME ZONE,
    
    -- Auto-resolution metadata
    resolution_metadata JSONB,
    
    detected_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_conflict_log_entity ON kernel.conflict_log(entity_type, entity_id);
CREATE INDEX idx_conflict_log_unresolved ON kernel.conflict_log(resolved_at) WHERE resolved_at IS NULL;

-- =============================================================================
-- SYNC QUEUE
-- =============================================================================

CREATE TYPE kernel.sync_direction AS ENUM (
    'push',
    'pull',
    'bidirectional'
);

CREATE TYPE kernel.sync_status AS ENUM (
    'pending',
    'in_progress',
    'completed',
    'failed',
    'conflict'
);

CREATE TABLE kernel.sync_queue (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    sync_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Source and target
    source_node_id UUID NOT NULL REFERENCES kernel.nodes(node_id),
    target_node_id UUID NOT NULL REFERENCES kernel.nodes(node_id),
    
    -- Sync scope
    entity_type VARCHAR(64),
    entity_id UUID,
    sync_direction kernel.sync_direction DEFAULT 'bidirectional',
    
    -- Data to sync
    operation VARCHAR(32) NOT NULL,  -- insert, update, delete
    payload JSONB NOT NULL,
    
    -- Status
    status kernel.sync_status DEFAULT 'pending',
    
    -- Timing
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Retry
    retry_count INTEGER DEFAULT 0,
    error_message TEXT,
    
    -- Ordering
    sequence_number BIGINT GENERATED ALWAYS AS IDENTITY
);

CREATE INDEX idx_sync_queue_status ON kernel.sync_queue(status, created_at);
CREATE INDEX idx_sync_queue_nodes ON kernel.sync_queue(source_node_id, target_node_id);

-- =============================================================================
-- TOPOLOGY VERSIONS (Schema registry)
-- =============================================================================

CREATE TABLE kernel.topology_versions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    version_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    version_number INTEGER NOT NULL UNIQUE,
    
    -- Schema definition
    schema_hash TEXT NOT NULL,
    schema_definition JSONB NOT NULL,
    
    -- Rollout
    rollout_status VARCHAR(32) DEFAULT 'pending',  -- pending, rolling_out, active, deprecated
    rollout_percentage INTEGER DEFAULT 0,
    
    -- Compatible versions
    compatible_with INTEGER[],
    
    -- Metadata
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    activated_at TIMESTAMP WITH TIME ZONE
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Register node
CREATE OR REPLACE FUNCTION kernel.register_node(
    p_node_name TEXT,
    p_node_type kernel.node_type,
    p_host_address INET,
    p_data_center TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_node_id UUID;
BEGIN
    INSERT INTO kernel.nodes (
        node_name, node_type, host_address, data_center, last_heartbeat
    ) VALUES (
        p_node_name, p_node_type, p_host_address, p_data_center, NOW()
    )
    RETURNING node_id INTO v_node_id;
    
    RETURN v_node_id;
END;
$$ LANGUAGE plpgsql;

-- Heartbeat
CREATE OR REPLACE FUNCTION kernel.node_heartbeat(p_node_id UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.nodes
    SET last_heartbeat = NOW(), updated_at = NOW()
    WHERE node_id = p_node_id;
END;
$$ LANGUAGE plpgsql;

-- Cache put
CREATE OR REPLACE FUNCTION kernel.cache_put(
    p_region_name TEXT,
    p_cache_key TEXT,
    p_entity_type VARCHAR,
    p_entity_id UUID,
    p_data JSONB,
    p_ttl_seconds INTEGER DEFAULT 3600
)
RETURNS VOID AS $$
DECLARE
    v_region_id UUID;
    v_data_hash TEXT;
BEGIN
    SELECT region_id INTO v_region_id FROM kernel.cache_regions WHERE region_name = p_region_name;
    
    IF v_region_id IS NULL THEN
        RAISE EXCEPTION 'Cache region % not found', p_region_name;
    END IF;
    
    v_data_hash := encode(digest(p_data::TEXT, 'sha256'), 'hex');
    
    INSERT INTO kernel.cache_entries (
        cache_key, region_id, entity_type, entity_id, cached_data, data_hash, expires_at
    ) VALUES (
        p_cache_key, v_region_id, p_entity_type, p_entity_id, p_data, v_data_hash,
        NOW() + (p_ttl_seconds || ' seconds')::INTERVAL
    )
    ON CONFLICT (cache_key, region_id) DO UPDATE SET
        cached_data = EXCLUDED.cached_data,
        data_hash = EXCLUDED.data_hash,
        version = kernel.cache_entries.version + 1,
        expires_at = EXCLUDED.expires_at,
        last_accessed_at = NOW(),
        is_stale = FALSE;
END;
$$ LANGUAGE plpgsql;

-- Cache get
CREATE OR REPLACE FUNCTION kernel.cache_get(
    p_region_name TEXT,
    p_cache_key TEXT
)
RETURNS TABLE(data JSONB, is_stale BOOLEAN) AS $$
DECLARE
    v_region_id UUID;
BEGIN
    SELECT region_id INTO v_region_id FROM kernel.cache_regions WHERE region_name = p_region_name;
    
    RETURN QUERY
    SELECT ce.cached_data, ce.is_stale
    FROM kernel.cache_entries ce
    WHERE ce.region_id = v_region_id
      AND ce.cache_key = p_cache_key
      AND ce.expires_at > NOW();
    
    -- Update access stats
    UPDATE kernel.cache_entries
    SET access_count = access_count + 1, last_accessed_at = NOW()
    WHERE region_id = v_region_id AND cache_key = p_cache_key;
END;
$$ LANGUAGE plpgsql;

-- Invalidate cache
CREATE OR REPLACE FUNCTION kernel.cache_invalidate(
    p_region_name TEXT DEFAULT NULL,
    p_entity_type VARCHAR DEFAULT NULL,
    p_entity_id UUID DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM kernel.cache_entries
    WHERE (p_region_name IS NULL OR region_id = (SELECT region_id FROM kernel.cache_regions WHERE region_name = p_region_name))
      AND (p_entity_type IS NULL OR entity_type = p_entity_type)
      AND (p_entity_id IS NULL OR entity_id = p_entity_id);
    
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

-- Resolve conflict
CREATE OR REPLACE FUNCTION kernel.resolve_conflict(
    p_conflict_id UUID,
    p_resolution JSONB,
    p_strategy kernel.conflict_resolution DEFAULT 'manual_resolution'
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.conflict_log
    SET resolved_version = p_resolution,
        resolution_strategy = p_strategy,
        resolved_by = security.get_participant_context(),
        resolved_at = NOW()
    WHERE conflict_id = p_conflict_id;
END;
$$ LANGUAGE plpgsql;

-- Queue sync
CREATE OR REPLACE FUNCTION kernel.queue_sync(
    p_source_node_id UUID,
    p_target_node_id UUID,
    p_entity_type VARCHAR,
    p_entity_id UUID,
    p_operation VARCHAR,
    p_payload JSONB
)
RETURNS UUID AS $$
DECLARE
    v_sync_id UUID;
BEGIN
    INSERT INTO kernel.sync_queue (
        source_node_id, target_node_id, entity_type, entity_id,
        operation, payload
    ) VALUES (
        p_source_node_id, p_target_node_id, p_entity_type, p_entity_id,
        p_operation, p_payload
    )
    RETURNING sync_id INTO v_sync_id;
    
    RETURN v_sync_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Create default cache regions
INSERT INTO kernel.cache_regions (region_name, cache_strategy, max_size, ttl_seconds) VALUES
    ('entity_snapshots', 'lru', 100000, 3600),
    ('participant_profiles', 'lru', 50000, 7200),
    ('policy_summaries', 'lru', 200000, 1800),
    ('claim_status', 'lru', 100000, 300),
    ('balance_cache', 'lru', 50000, 60),
    ('authorization_cache', 'lfu', 10000, 300)
ON CONFLICT (region_name) DO NOTHING;

-- Register local node
INSERT INTO kernel.nodes (node_name, node_type, host_address, data_center, status) VALUES
    ('primary-node', 'primary', '127.0.0.1'::INET, 'local', 'active')
ON CONFLICT (node_name) DO NOTHING;

SELECT 'Primitive 22: Peer Caching & Replication initialized' AS status;
