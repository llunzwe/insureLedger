-- =============================================================================
-- FILE: 025_streaming_mutation.sql
-- PURPOSE: Primitive 21 - Streaming & Mutation
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Kafka, Event Streaming, CQRS
-- DEPENDENCIES: 013_datoms.sql
-- =============================================================================

-- =============================================================================
-- EVENT STREAMS
-- =============================================================================

CREATE TYPE kernel.stream_status AS ENUM (
    'active',
    'paused',
    'failed',
    'terminated'
);

CREATE TYPE kernel.delivery_guarantee AS ENUM (
    'at_most_once',
    'at_least_once',
    'exactly_once'
);

CREATE TABLE kernel.event_streams (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    stream_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    stream_name TEXT UNIQUE NOT NULL,
    
    -- Configuration
    stream_type VARCHAR(32) NOT NULL,  -- kafka, kinesis, pubsub, internal
    topic_pattern TEXT NOT NULL,
    
    -- Performance
    partition_count INTEGER DEFAULT 1,
    replication_factor INTEGER DEFAULT 3,
    
    -- Guarantees
    delivery_guarantee kernel.delivery_guarantee DEFAULT 'at_least_once',
    retention_hours INTEGER DEFAULT 168,  -- 7 days
    
    -- Status
    status kernel.stream_status DEFAULT 'active',
    
    -- Schema
    schema_version TEXT DEFAULT '1.0',
    event_schema JSONB,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_event_streams_name ON kernel.event_streams(stream_name);
CREATE INDEX idx_event_streams_status ON kernel.event_streams(status);

-- =============================================================================
-- EVENT PRODUCERS
-- =============================================================================

CREATE TABLE kernel.event_producers (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    producer_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    producer_name TEXT NOT NULL,
    
    -- Target stream
    stream_id UUID NOT NULL REFERENCES kernel.event_streams(stream_id),
    
    -- Configuration
    producer_type VARCHAR(32) NOT NULL,  -- application, connector, trigger
    source_table TEXT,  -- For database triggers
    source_query TEXT,  -- For query-based producers
    
    -- Transformation
    transformation_logic TEXT,  -- SQL or function reference
    
    -- Rate limiting
    max_events_per_second INTEGER DEFAULT 1000,
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_event_producers_stream ON kernel.event_producers(stream_id);

-- =============================================================================
-- EVENT CONSUMERS
-- =============================================================================

CREATE TYPE kernel.consumer_status AS ENUM (
    'idle',
    'consuming',
    'lagging',
    'failed',
    'stopped'
);

CREATE TABLE kernel.event_consumers (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    consumer_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    consumer_name TEXT NOT NULL,
    consumer_group TEXT NOT NULL,
    
    -- Source stream
    stream_id UUID NOT NULL REFERENCES kernel.event_streams(stream_id),
    
    -- Configuration
    consumer_type VARCHAR(32) NOT NULL,  -- application, materialized_view, webhook
    target_table TEXT,
    target_api TEXT,
    
    -- Processing
    processing_logic TEXT,
    error_handling VARCHAR(32) DEFAULT 'retry',  -- retry, dead_letter, skip
    max_retries INTEGER DEFAULT 3,
    
    -- Current state
    current_offset BIGINT DEFAULT 0,
    partition_assignments INTEGER[],
    
    -- Status
    status kernel.consumer_status DEFAULT 'idle',
    
    -- Metrics
    messages_consumed BIGINT DEFAULT 0,
    messages_failed BIGINT DEFAULT 0,
    lag_seconds INTEGER,
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_consumed_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_event_consumers_stream ON kernel.event_consumers(stream_id);
CREATE INDEX idx_event_consumers_group ON kernel.event_consumers(consumer_group);

-- =============================================================================
-- EVENT LOG (Materialized stream)
-- =============================================================================

CREATE TABLE kernel.event_log (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    event_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Stream info
    stream_name TEXT NOT NULL,
    partition INTEGER NOT NULL DEFAULT 0,
    offset BIGINT NOT NULL,
    
    -- Event data
    event_type VARCHAR(64) NOT NULL,
    event_version TEXT DEFAULT '1.0',
    
    -- Payload
    payload JSONB NOT NULL,
    payload_schema TEXT,
    
    -- Context
    entity_type VARCHAR(64),
    entity_id UUID,
    
    -- Timing
    event_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    processed_time TIMESTAMP WITH TIME ZONE,
    
    -- Provenance
    producer_id UUID,
    correlation_id UUID,
    causation_id UUID,
    
    -- Key for partitioning
    partition_key TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(stream_name, partition, offset)
);

CREATE INDEX idx_event_log_stream ON kernel.event_log(stream_name, partition, offset DESC);
CREATE INDEX idx_event_log_entity ON kernel.event_log(entity_type, entity_id, event_time DESC);
CREATE INDEX idx_event_log_type ON kernel.event_log(event_type, event_time DESC);
CREATE INDEX idx_event_log_correlation ON kernel.event_log(correlation_id);

-- Partition by time for scalability
-- CREATE TABLE kernel.event_log_2024q1 PARTITION OF kernel.event_log
--     FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

-- =============================================================================
-- MUTATIONS (Change Data Capture)
-- =============================================================================

CREATE TYPE kernel.mutation_type AS ENUM (
    'insert',
    'update',
    'delete',
    'truncate'
);

CREATE TABLE kernel.mutations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    mutation_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Source
    source_table TEXT NOT NULL,
    source_schema TEXT DEFAULT 'kernel',
    
    -- Operation
    mutation_type kernel.mutation_type NOT NULL,
    
    -- Data
    primary_key UUID,
    primary_key_values JSONB,
    
    old_data JSONB,
    new_data JSONB,
    changed_fields TEXT[],
    
    -- Context
    transaction_id BIGINT,
    lsn TEXT,  -- Log Sequence Number
    
    -- Timing
    committed_at TIMESTAMP WITH TIME ZONE,
    captured_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Processing
    processed BOOLEAN DEFAULT FALSE,
    processed_at TIMESTAMP WITH TIME ZONE,
    processor_id UUID,
    
    -- Error handling
    retry_count INTEGER DEFAULT 0,
    error_message TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_mutations_table ON kernel.mutations(source_schema, source_table, committed_at DESC);
CREATE INDEX idx_mutations_unprocessed ON kernel.mutations(processed) WHERE processed = FALSE;
CREATE INDEX idx_mutations_pkey ON kernel.mutations(primary_key, committed_at DESC);

-- =============================================================================
-- CHANGE DATA CAPTURE CONFIGURATION
-- =============================================================================

CREATE TABLE kernel.cdc_configurations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    config_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Source table
    source_schema TEXT NOT NULL DEFAULT 'kernel',
    source_table TEXT NOT NULL,
    
    -- Configuration
    capture_inserts BOOLEAN DEFAULT TRUE,
    capture_updates BOOLEAN DEFAULT TRUE,
    capture_deletes BOOLEAN DEFAULT TRUE,
    
    -- Filtering
    row_filter TEXT,  -- SQL WHERE clause
    column_filter TEXT[],  -- Only these columns
    
    -- Destination
    target_stream_id UUID REFERENCES kernel.event_streams(stream_id),
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(source_schema, source_table)
);

-- =============================================================================
-- MATERIALIZED VIEWS STATE
-- =============================================================================

CREATE TABLE kernel.materialized_view_state (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    view_name TEXT UNIQUE NOT NULL,
    
    -- Last update
    last_refresh_at TIMESTAMP WITH TIME ZONE,
    last_refresh_duration_ms INTEGER,
    
    -- Source tracking
    source_tables TEXT[],
    max_source_timestamp TIMESTAMP WITH TIME ZONE,
    
    -- Status
    is_fresh BOOLEAN DEFAULT FALSE,
    refresh_in_progress BOOLEAN DEFAULT FALSE,
    
    -- Statistics
    row_count BIGINT,
    size_bytes BIGINT,
    
    -- Incremental tracking
    last_processed_mutation_id UUID,
    
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Publish event
CREATE OR REPLACE FUNCTION kernel.publish_event(
    p_stream_name TEXT,
    p_event_type VARCHAR,
    p_payload JSONB,
    p_entity_type VARCHAR DEFAULT NULL,
    p_entity_id UUID DEFAULT NULL,
    p_correlation_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_event_id UUID;
    v_stream RECORD;
    v_offset BIGINT;
BEGIN
    SELECT * INTO v_stream FROM kernel.event_streams WHERE stream_name = p_stream_name;
    
    IF v_stream IS NULL THEN
        RAISE EXCEPTION 'Stream % not found', p_stream_name;
    END IF;
    
    -- Get next offset (simplified - would use proper sequence)
    SELECT COALESCE(MAX(offset), 0) + 1 INTO v_offset
    FROM kernel.event_log
    WHERE stream_name = p_stream_name;
    
    INSERT INTO kernel.event_log (
        stream_name, partition, offset, event_type, payload,
        entity_type, entity_id, correlation_id, partition_key
    ) VALUES (
        p_stream_name, 0, v_offset, p_event_type, p_payload,
        p_entity_type, p_entity_id, p_correlation_id,
        COALESCE(p_entity_id::TEXT, gen_random_uuid()::TEXT)
    )
    RETURNING event_id INTO v_event_id;
    
    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- Record mutation
CREATE OR REPLACE FUNCTION kernel.record_mutation()
RETURNS TRIGGER AS $$
DECLARE
    v_old_data JSONB;
    v_new_data JSONB;
    v_changed_fields TEXT[];
    v_pkey UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := NULL;
        v_pkey := OLD.id;
    ELSIF TG_OP = 'INSERT' THEN
        v_old_data := NULL;
        v_new_data := to_jsonb(NEW);
        v_pkey := NEW.id;
        v_changed_fields := ARRAY(SELECT key FROM jsonb_each_text(v_new_data));
    ELSE  -- UPDATE
        v_old_data := to_jsonb(OLD);
        v_new_data := to_jsonb(NEW);
        v_pkey := NEW.id;
        v_changed_fields := ARRAY(
            SELECT key 
            FROM jsonb_each_text(v_new_data)
            WHERE v_new_data->key IS DISTINCT FROM v_old_data->key
        );
    END IF;
    
    INSERT INTO kernel.mutations (
        source_schema, source_table, mutation_type,
        primary_key, primary_key_values, old_data, new_data, changed_fields,
        committed_at
    ) VALUES (
        TG_TABLE_SCHEMA, TG_TABLE_NAME,
        TG_OP::kernel.mutation_type,
        v_pkey, jsonb_build_object('id', v_pkey), v_old_data, v_new_data, v_changed_fields,
        NOW()
    );
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Process unprocessed mutations
CREATE OR REPLACE FUNCTION kernel.process_mutations(p_limit INTEGER DEFAULT 100)
RETURNS INTEGER AS $$
DECLARE
    v_processed INTEGER := 0;
    v_mutation RECORD;
BEGIN
    FOR v_mutation IN 
        SELECT * FROM kernel.mutations
        WHERE processed = FALSE
          AND retry_count < 3
        ORDER BY committed_at
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Publish to event stream if configured
        IF EXISTS (
            SELECT 1 FROM kernel.cdc_configurations
            WHERE source_schema = v_mutation.source_schema
              AND source_table = v_mutation.source_table
              AND is_active = TRUE
        ) THEN
            PERFORM kernel.publish_event(
                v_mutation.source_schema || '.' || v_mutation.source_table,
                v_mutation.mutation_type::TEXT,
                jsonb_build_object(
                    'table', v_mutation.source_table,
                    'operation', v_mutation.mutation_type,
                    'old', v_mutation.old_data,
                    'new', v_mutation.new_data
                ),
                v_mutation.source_table,
                v_mutation.primary_key
            );
        END IF;
        
        UPDATE kernel.mutations
        SET processed = TRUE, processed_at = NOW()
        WHERE mutation_id = v_mutation.mutation_id;
        
        v_processed := v_processed + 1;
    END LOOP;
    
    RETURN v_processed;
END;
$$ LANGUAGE plpgsql;

-- Refresh materialized view incrementally
CREATE OR REPLACE FUNCTION kernel.refresh_materialized_view(
    p_view_name TEXT,
    p_incremental BOOLEAN DEFAULT TRUE
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.materialized_view_state
    SET refresh_in_progress = TRUE
    WHERE view_name = p_view_name;
    
    -- Full refresh or incremental would be implemented here
    -- For now, just mark as refreshed
    
    UPDATE kernel.materialized_view_state
    SET 
        last_refresh_at = NOW(),
        is_fresh = TRUE,
        refresh_in_progress = FALSE
    WHERE view_name = p_view_name;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Create default event streams
INSERT INTO kernel.event_streams (stream_name, stream_type, topic_pattern, description) VALUES
    ('kernel.datoms', 'internal', 'kernel.datoms', 'Datom events for entity changes'),
    ('kernel.value_movements', 'internal', 'kernel.movements', 'Financial movement events'),
    ('kernel.claims', 'internal', 'kernel.claims', 'Insurance claim events'),
    ('kernel.policies', 'internal', 'kernel.policies', 'Insurance policy events'),
    ('kernel.audit.events', 'internal', 'kernel.audit', 'Audit trail events')
ON CONFLICT (stream_name) DO NOTHING;

-- Enable CDC for key tables
INSERT INTO kernel.cdc_configurations (source_schema, source_table, capture_inserts, capture_updates, capture_deletes) VALUES
    ('kernel', 'datoms', TRUE, FALSE, FALSE),
    ('kernel', 'value_movements', TRUE, TRUE, FALSE),
    ('kernel', 'claims', TRUE, TRUE, FALSE),
    ('kernel', 'insurance_policies', TRUE, TRUE, FALSE)
ON CONFLICT (source_schema, source_table) DO NOTHING;

SELECT 'Primitive 21: Streaming & Mutation initialized' AS status;
