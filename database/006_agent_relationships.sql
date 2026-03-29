-- =============================================================================
-- FILE: 006_agent_relationships.sql
-- PURPOSE: Primitive 3 - Economic Agents & Relationships (KYC, sanctions)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: FATF, ISO 8601
-- DEPENDENCIES: 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- AGENT RELATIONSHIPS - Directed edges between agents
-- =============================================================================

CREATE TYPE kernel.relationship_type AS ENUM (
    'ownership',
    'control',
    'employment',
    'representation',
    'agency',
    'guarantee',
    'beneficiary',
    'custody',
    'group_membership',
    'family',
    'trade',
    'authorized_signatory',
    'trustee'
);

CREATE TABLE kernel.agent_relationships (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    relationship_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Directed edge
    from_agent_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    to_agent_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    relationship_type kernel.relationship_type NOT NULL,
    
    -- Relationship details
    percentage DECIMAL(5, 2),  -- For ownership/control percentages
    description TEXT,
    
    -- Verification
    verification_status VARCHAR(32) DEFAULT 'pending',  -- pending, verified, rejected
    verification_method VARCHAR(32),
    verified_by UUID,
    verified_at TIMESTAMP WITH TIME ZONE,
    supporting_documents UUID[],  -- References to documents
    
    -- Bitemporal
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_agent_relationships_temporal 
        CHECK (system_from <= system_to OR system_to IS NULL),
    CONSTRAINT chk_agent_relationships_no_self 
        CHECK (from_agent_id != to_agent_id)
);

COMMENT ON TABLE kernel.agent_relationships IS 'Directed relationships between agents (ownership, control, employment, etc.)';

CREATE INDEX idx_agent_relationships_from ON kernel.agent_relationships(from_agent_id);
CREATE INDEX idx_agent_relationships_to ON kernel.agent_relationships(to_agent_id);
CREATE INDEX idx_agent_relationships_type ON kernel.agent_relationships(relationship_type);
CREATE INDEX idx_agent_relationships_active ON kernel.agent_relationships(from_agent_id, to_agent_id) 
    WHERE system_to IS NULL AND valid_to IS NULL;

-- =============================================================================
-- SANCTIONS SCREENINGS - Log of sanctions checks
-- =============================================================================

CREATE TABLE kernel.sanctions_screenings (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    screening_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Screening details
    screening_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    screening_provider VARCHAR(32),  -- Dow Jones, Refinitiv, etc.
    screening_list VARCHAR(32),  -- OFAC, UN, EU, HMT
    
    -- Results
    match_status VARCHAR(32),  -- clear, potential_match, confirmed_match
    match_confidence DECIMAL(5, 2),
    matched_name TEXT,
    matched_entity_details JSONB,
    
    -- Resolution
    resolved_by UUID,
    resolved_at TIMESTAMP WITH TIME ZONE,
    resolution VARCHAR(32),  -- false_positive, true_positive, under_review
    resolution_notes TEXT,
    
    -- Alert
    alert_generated BOOLEAN DEFAULT FALSE,
    alert_cleared BOOLEAN DEFAULT FALSE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

COMMENT ON TABLE kernel.sanctions_screenings IS 'Log of sanctions list screenings per FATF requirements';

CREATE INDEX idx_sanctions_screenings_participant ON kernel.sanctions_screenings(participant_id, screening_timestamp DESC);
CREATE INDEX idx_sanctions_screenings_status ON kernel.sanctions_screenings(match_status) WHERE match_status != 'clear';

-- =============================================================================
-- KYC VERIFICATIONS - Know Your Customer event log
-- =============================================================================

CREATE TYPE kernel.kyc_level AS ENUM (
    'basic',      -- Name, DOB verified
    'standard',   -- + Address verified
    'enhanced',   -- + ID documents verified
    'ongoing'     -- Continuous monitoring
);

CREATE TABLE kernel.kyc_verifications (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    verification_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Verification details
    kyc_level kernel.kyc_level NOT NULL,
    verification_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    verification_provider VARCHAR(32),  -- Jumio, Onfido, etc.
    
    -- Documents verified
    identity_document_verified BOOLEAN DEFAULT FALSE,
    address_document_verified BOOLEAN DEFAULT FALSE,
    face_match_verified BOOLEAN DEFAULT FALSE,
    liveness_check_passed BOOLEAN DEFAULT FALSE,
    
    -- Risk assessment
    risk_rating VARCHAR(16),  -- low, medium, high
    risk_factors JSONB,
    pep_status VARCHAR(16),  -- politically_exposed_person status
    adverse_media_found BOOLEAN DEFAULT FALSE,
    
    -- Expiry
    valid_until TIMESTAMP WITH TIME ZONE,
    
    -- Re-verification trigger
    requires_reverification BOOLEAN DEFAULT FALSE,
    reverification_due_date DATE,
    
    -- Audit
    verified_by UUID,
    verification_documents UUID[],  -- References to documents
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

COMMENT ON TABLE kernel.kyc_verifications IS 'KYC verification events with document checks and risk assessment';

CREATE INDEX idx_kyc_verifications_participant ON kernel.kyc_verifications(participant_id, verification_timestamp DESC);
CREATE INDEX idx_kyc_verifications_expiry ON kernel.kyc_verifications(valid_until) WHERE valid_until < NOW() + INTERVAL '30 days';

-- =============================================================================
-- CIRCULAR OWNERSHIP DETECTION
-- =============================================================================

-- Function to detect circular ownership
CREATE OR REPLACE FUNCTION kernel.detect_circular_ownership(
    p_start_agent_id UUID,
    p_max_depth INTEGER DEFAULT 10
)
RETURNS TABLE(
    is_circular BOOLEAN,
    cycle_path UUID[],
    cycle_length INTEGER
) AS $$
DECLARE
    v_visited UUID[];
    v_current UUID;
    v_next UUID;
    v_depth INTEGER := 0;
    v_path UUID[];
BEGIN
    v_current := p_start_agent_id;
    v_path := ARRAY[p_start_agent_id];
    
    WHILE v_depth < p_max_depth LOOP
        -- Find next agent in ownership chain
        SELECT to_agent_id INTO v_next
        FROM kernel.agent_relationships
        WHERE from_agent_id = v_current
          AND relationship_type = 'ownership'
          AND system_to IS NULL
          AND valid_to IS NULL
        LIMIT 1;
        
        IF v_next IS NULL THEN
            RETURN QUERY SELECT FALSE, v_path, v_depth;
            RETURN;
        END IF;
        
        -- Check if we've looped back to start
        IF v_next = p_start_agent_id THEN
            RETURN QUERY SELECT TRUE, v_path || v_next, v_depth + 1;
            RETURN;
        END IF;
        
        -- Check if we've seen this agent before (other cycle)
        IF v_next = ANY(v_path) THEN
            RETURN QUERY SELECT TRUE, v_path || v_next, v_depth + 1;
            RETURN;
        END IF;
        
        v_path := v_path || v_next;
        v_current := v_next;
        v_depth := v_depth + 1;
    END LOOP;
    
    RETURN QUERY SELECT FALSE, v_path, v_depth;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.detect_circular_ownership(UUID, INTEGER) IS 'Detect circular ownership structures for compliance';

-- Trigger to prevent circular ownership on insert
CREATE OR REPLACE FUNCTION kernel.prevent_circular_ownership()
RETURNS TRIGGER AS $$
DECLARE
    v_result RECORD;
BEGIN
    IF NEW.relationship_type = 'ownership' THEN
        SELECT * INTO v_result
        FROM kernel.detect_circular_ownership(NEW.to_agent_id);
        
        IF v_result.is_circular THEN
            RAISE EXCEPTION 'Circular ownership detected: %', v_result.cycle_path;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_circular_ownership
    BEFORE INSERT ON kernel.agent_relationships
    FOR EACH ROW EXECUTE FUNCTION kernel.prevent_circular_ownership();

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 3: Economic Agents & Relationships initialized' AS status;
