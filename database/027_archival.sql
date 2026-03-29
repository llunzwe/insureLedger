-- =============================================================================
-- FILE: 027_archival.sql
-- PURPOSE: Primitive 23 - Archival & Tiering
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: WORM, GDPR Right to Erasure, SEC 17a-4
-- DEPENDENCIES: 013_datoms.sql
-- =============================================================================

-- =============================================================================
-- ARCHIVAL POLICIES
-- =============================================================================

CREATE TYPE kernel.archival_tier AS ENUM (
    'hot',       -- Primary database
    'warm',      -- Read replicas
    'cold',      -- Object storage
    'glacier',   -- Deep archive
    'tape'       -- Physical/offline
);

CREATE TABLE kernel.archival_policies (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    policy_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    policy_name TEXT UNIQUE NOT NULL,
    
    -- Scope
    source_schema TEXT NOT NULL DEFAULT 'kernel',
    source_table TEXT NOT NULL,
    row_filter TEXT,  -- SQL WHERE clause for selective archival
    
    -- Conditions
    archive_after_days INTEGER NOT NULL,  -- Move to cold after N days
    delete_after_days INTEGER,  -- Hard delete after N days (NULL = keep forever)
    
    -- Tiering
    tier_progression JSONB DEFAULT '["hot", "warm", "cold", "glacier"]'::JSONB,
    
    -- Compliance
    worm_required BOOLEAN DEFAULT FALSE,
    legal_hold_exempt BOOLEAN DEFAULT FALSE,
    gdpr_category VARCHAR(32),  -- personal_data, sensitive, none
    
    -- Encryption
    encryption_key_id UUID,
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_archival_policies_table ON kernel.archival_policies(source_schema, source_table);

-- =============================================================================
-- ARCHIVE JOBS
-- =============================================================================

CREATE TYPE kernel.archive_job_status AS ENUM (
    'pending',
    'scanning',
    'archiving',
    'verifying',
    'completed',
    'failed',
    'paused'
);

CREATE TABLE kernel.archive_jobs (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    job_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    job_name TEXT NOT NULL,
    
    -- Policy
    policy_id UUID NOT NULL REFERENCES kernel.archival_policies(policy_id),
    
    -- Scope
    source_table TEXT NOT NULL,
    date_range_start DATE,
    date_range_end DATE,
    
    -- Target
    target_tier kernel.archival_tier NOT NULL,
    target_location TEXT,  -- S3 bucket, GCS path, etc.
    
    -- Status
    status kernel.archive_job_status DEFAULT 'pending',
    
    -- Progress
    total_records INTEGER,
    processed_records INTEGER DEFAULT 0,
    archived_records INTEGER DEFAULT 0,
    failed_records INTEGER DEFAULT 0,
    deleted_records INTEGER DEFAULT 0,
    
    -- Size
    source_size_bytes BIGINT,
    archive_size_bytes BIGINT,
    compression_ratio DECIMAL(5, 2),
    
    -- Timing
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Verification
    checksum TEXT,
    verification_passed BOOLEAN,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_archive_jobs_status ON kernel.archive_jobs(status);
CREATE INDEX idx_archive_jobs_policy ON kernel.archive_jobs(policy_id);

-- =============================================================================
-- ARCHIVED DATA MANIFEST
-- =============================================================================

CREATE TABLE kernel.archive_manifest (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    archive_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    job_id UUID NOT NULL REFERENCES kernel.archive_jobs(job_id),
    
    -- Original record reference
    source_schema TEXT NOT NULL,
    source_table TEXT NOT NULL,
    source_record_id UUID NOT NULL,
    
    -- Archival details
    archived_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    archive_tier kernel.archival_tier NOT NULL,
    archive_location TEXT NOT NULL,
    archive_path TEXT NOT NULL,
    
    -- Original timestamps
    original_created_at TIMESTAMP WITH TIME ZONE,
    original_system_from TIMESTAMP WITH TIME ZONE,
    
    -- Metadata
    record_summary JSONB,  -- Key fields for searching without full restore
    content_hash TEXT,  -- Integrity verification
    
    -- Restoration
    restored_at TIMESTAMP WITH TIME ZONE,
    restored_by UUID,
    restoration_expires_at TIMESTAMP WITH TIME ZONE,
    
    -- Legal hold
    legal_hold BOOLEAN DEFAULT FALSE,
    legal_hold_reason TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_archive_manifest_job ON kernel.archive_manifest(job_id);
CREATE INDEX idx_archive_manifest_source ON kernel.archive_manifest(source_schema, source_table, source_record_id);
CREATE INDEX idx_archive_manifest_location ON kernel.archive_manifest(archive_location, archive_path);

-- =============================================================================
-- DATA TIERING STATE
-- =============================================================================

CREATE TABLE kernel.data_tier_state (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    record_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Source reference
    source_schema TEXT NOT NULL,
    source_table TEXT NOT NULL,
    source_record_id UUID NOT NULL,
    
    -- Current tier
    current_tier kernel.archival_tier DEFAULT 'hot',
    
    -- Tier history
    tier_history JSONB DEFAULT '[]',
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_accessed_at TIMESTAMP WITH TIME ZONE,
    last_tier_change_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Access tracking
    access_count INTEGER DEFAULT 0,
    
    UNIQUE(source_schema, source_table, source_record_id)
);

CREATE INDEX idx_data_tier_state_tier ON kernel.data_tier_state(current_tier);
CREATE INDEX idx_data_tier_state_table ON kernel.data_tier_state(source_schema, source_table);

-- =============================================================================
-- LEGAL HOLDS
-- =============================================================================

CREATE TABLE kernel.legal_holds (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    hold_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    hold_reference TEXT UNIQUE NOT NULL,
    
    -- Description
    hold_name TEXT NOT NULL,
    hold_description TEXT,
    hold_reason TEXT NOT NULL,  -- litigation, investigation, audit, regulatory
    
    -- Scope
    scope_type VARCHAR(32) NOT NULL,  -- table, query, participant, date_range
    scope_criteria JSONB NOT NULL,
    
    -- Affected records count
    affected_records_estimate INTEGER,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Parties
    issued_by UUID NOT NULL,
    authorized_by UUID,
    
    -- Timing
    issued_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    effective_date DATE NOT NULL,
    expiration_date DATE,
    released_at TIMESTAMP WITH TIME ZONE,
    released_by UUID,
    release_reason TEXT,
    
    -- External reference
    case_number TEXT,
    matter_id TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_legal_holds_active ON kernel.legal_holds(is_active, effective_date);

-- =============================================================================
-- GDPR DELETION REQUESTS
-- =============================================================================

CREATE TYPE kernel.gdpr_request_type AS ENUM (
    'access',
    'rectification',
    'erasure',
    'restriction',
    'portability',
    'objection'
);

CREATE TYPE kernel.gdpr_request_status AS ENUM (
    'pending',
    'under_review',
    'in_progress',
    'completed',
    'rejected',
    'appealed'
);

CREATE TABLE kernel.gdpr_requests (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    request_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    request_reference TEXT UNIQUE NOT NULL,
    
    -- Requester
    requester_participant_id UUID REFERENCES kernel.participants(participant_id),
    requester_email TEXT,
    requester_verified BOOLEAN DEFAULT FALSE,
    
    -- Request details
    request_type kernel.gdpr_request_type NOT NULL,
    request_description TEXT,
    
    -- Scope
    scope_participant_id UUID,
    scope_data_types TEXT[],
    scope_date_from DATE,
    scope_date_to DATE,
    
    -- Status
    status kernel.gdpr_request_status DEFAULT 'pending',
    
    -- Legal hold check
    legal_hold_blocks BOOLEAN DEFAULT FALSE,
    blocking_hold_ids UUID[],
    
    -- Response
    response_data JSONB,
    response_delivered_at TIMESTAMP WITH TIME ZONE,
    response_method VARCHAR(32),  -- email, portal, postal
    
    -- Timing
    deadline_date DATE NOT NULL,  -- 30 days from request
    submitted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Processing
    processed_by UUID,
    processing_notes TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_gdpr_requests_status ON kernel.gdpr_requests(status, deadline_date);
CREATE INDEX idx_gdpr_requests_requester ON kernel.gdpr_requests(requester_participant_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create archival job
CREATE OR REPLACE FUNCTION kernel.create_archive_job(
    p_policy_id UUID,
    p_job_name TEXT,
    p_target_tier kernel.archival_tier,
    p_date_range_start DATE DEFAULT NULL,
    p_date_range_end DATE DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_job_id UUID;
    v_policy RECORD;
BEGIN
    SELECT * INTO v_policy FROM kernel.archival_policies WHERE policy_id = p_policy_id;
    
    INSERT INTO kernel.archive_jobs (
        policy_id, job_name, source_table, target_tier,
        date_range_start, date_range_end, created_by
    ) VALUES (
        p_policy_id, p_job_name, v_policy.source_table, p_target_tier,
        p_date_range_start, p_date_range_end, security.get_participant_context()
    )
    RETURNING job_id INTO v_job_id;
    
    RETURN v_job_id;
END;
$$ LANGUAGE plpgsql;

-- Check if record can be deleted (legal hold, GDPR)
CREATE OR REPLACE FUNCTION kernel.can_delete_record(
    p_schema TEXT,
    p_table TEXT,
    p_record_id UUID
)
RETURNS TABLE(can_delete BOOLEAN, reason TEXT) AS $$
DECLARE
    v_has_legal_hold BOOLEAN;
    v_has_gdpr_request BOOLEAN;
BEGIN
    -- Check legal holds
    SELECT EXISTS (
        SELECT 1 FROM kernel.legal_holds
        WHERE is_active = TRUE
          AND (effective_date <= CURRENT_DATE OR effective_date IS NULL)
          AND (expiration_date IS NULL OR expiration_date >= CURRENT_DATE)
          AND (
              (scope_type = 'table' AND scope_criteria->>'schema' = p_schema AND scope_criteria->>'table' = p_table)
              OR (scope_type = 'query' AND p_record_id IN (
                  -- Would execute scope_criteria->>'query' here
                  SELECT id FROM kernel.datoms WHERE entity_id = p_record_id
              ))
          )
    ) INTO v_has_legal_hold;
    
    IF v_has_legal_hold THEN
        RETURN QUERY SELECT FALSE, 'Active legal hold exists'::TEXT;
        RETURN;
    END IF;
    
    -- Check GDPR requests
    SELECT EXISTS (
        SELECT 1 FROM kernel.gdpr_requests
        WHERE request_type = 'erasure'
          AND status IN ('pending', 'under_review', 'in_progress')
          AND scope_participant_id = p_record_id
    ) INTO v_has_gdpr_request;
    
    IF v_has_gdpr_request THEN
        RETURN QUERY SELECT FALSE, 'Pending GDPR erasure request'::TEXT;
        RETURN;
    END IF;
    
    RETURN QUERY SELECT TRUE, NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Create GDPR request
CREATE OR REPLACE FUNCTION kernel.create_gdpr_request(
    p_request_type kernel.gdpr_request_type,
    p_requester_participant_id UUID,
    p_description TEXT,
    p_scope_participant_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_request_id UUID;
    v_reference TEXT;
BEGIN
    v_reference := 'GDPR-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    
    INSERT INTO kernel.gdpr_requests (
        request_reference, request_type, requester_participant_id,
        request_description, scope_participant_id, deadline_date
    ) VALUES (
        v_reference, p_request_type, p_requester_participant_id,
        p_description, p_scope_participant_id, CURRENT_DATE + INTERVAL '30 days'
    )
    RETURNING request_id INTO v_request_id;
    
    RETURN v_request_id;
END;
$$ LANGUAGE plpgsql;

-- Apply legal hold
CREATE OR REPLACE FUNCTION kernel.apply_legal_hold(
    p_hold_name TEXT,
    p_hold_reason TEXT,
    p_scope_type VARCHAR,
    p_scope_criteria JSONB,
    p_effective_date DATE DEFAULT CURRENT_DATE
)
RETURNS UUID AS $$
DECLARE
    v_hold_id UUID;
    v_reference TEXT;
BEGIN
    v_reference := 'LH-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 6);
    
    INSERT INTO kernel.legal_holds (
        hold_reference, hold_name, hold_reason, scope_type, scope_criteria,
        effective_date, issued_by
    ) VALUES (
        v_reference, p_hold_name, p_hold_reason, p_scope_type, p_scope_criteria,
        p_effective_date, security.get_participant_context()
    )
    RETURNING hold_id INTO v_hold_id;
    
    RETURN v_hold_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Create default archival policies
INSERT INTO kernel.archival_policies (policy_name, source_table, archive_after_days, delete_after_days, worm_required) VALUES
    ('Audit Logs Archival', 'audit_log_entries', 90, 2555, TRUE),
    ('Event Log Archival', 'event_log', 30, 365, FALSE),
    ('Mutation Archival', 'mutations', 30, 730, FALSE),
    ('Session Archival', 'sessions', 7, 90, FALSE),
    ('Old Claims Archival', 'claims', 365, NULL, TRUE),
    ('Old Policies Archival', 'insurance_policies', 730, NULL, TRUE)
ON CONFLICT (policy_name) DO NOTHING;

SELECT 'Primitive 23: Archival & Tiering initialized' AS status;
