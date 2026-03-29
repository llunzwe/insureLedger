-- =============================================================================
-- FILE: 010_insurance_policy.sql
-- PURPOSE: Primitive 10 - Insurance Policy & Claim
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: IFRS 17 (Insurance Contracts), ISO 8601
-- DEPENDENCIES: 005_device_product.sql, 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- INSURANCE POLICIES
-- =============================================================================

CREATE TYPE kernel.coverage_type AS ENUM (
    'comprehensive',
    'screen_only',
    'accidental_damage',
    'theft',
    'loss',
    'extended_warranty'
);

CREATE TYPE kernel.policy_status AS ENUM (
    'active',
    'expired',
    'cancelled',
    'suspended',
    'pending'
);

CREATE TABLE kernel.insurance_policies (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    policy_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    policy_number TEXT UNIQUE NOT NULL,
    
    -- References
    device_id UUID NOT NULL REFERENCES kernel.devices(device_id),
    insurer_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    policyholder_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Product Contract (immutable terms)
    product_contract_hash UUID,  -- References product_contract_anchors
    
    -- Coverage
    coverage_type kernel.coverage_type NOT NULL,
    coverage_limit DECIMAL(15, 2) NOT NULL,
    deductible_amount DECIMAL(15, 2) NOT NULL,
    exclusions TEXT[],
    special_conditions TEXT,
    
    -- Premium
    premium_amount DECIMAL(15, 2) NOT NULL,
    billing_frequency VARCHAR(32) DEFAULT 'monthly',
    next_due_date DATE,
    total_paid_to_date DECIMAL(15, 2) DEFAULT 0,
    
    -- Term
    effective_start_date DATE NOT NULL,
    effective_end_date DATE NOT NULL,
    renewal_status VARCHAR(32) DEFAULT 'pending',
    renewal_policy_id UUID,
    
    -- Dynamic Pricing
    risk_score DECIMAL(5, 2),
    risk_factors JSONB,
    
    -- Claims tracking
    claims_count INTEGER DEFAULT 0,
    claims_total_amount DECIMAL(15, 2) DEFAULT 0,
    
    status kernel.policy_status DEFAULT 'pending',
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    signature TEXT,
    proof_inclusion UUID,
    
    CONSTRAINT chk_policies_temporal CHECK (system_from <= system_to OR system_to IS NULL),
    CONSTRAINT chk_policies_dates CHECK (effective_start_date < effective_end_date)
);

CREATE INDEX idx_policies_policy ON kernel.insurance_policies(policy_id);
CREATE INDEX idx_policies_device ON kernel.insurance_policies(device_id);
CREATE INDEX idx_policies_insurer ON kernel.insurance_policies(insurer_id);
CREATE INDEX idx_policies_status ON kernel.insurance_policies(status);

-- =============================================================================
-- CLAIMS
-- =============================================================================

CREATE TYPE kernel.claim_status AS ENUM (
    'filed',
    'under_review',
    'approved',
    'denied',
    'paid',
    'closed'
);

CREATE TYPE kernel.incident_type AS ENUM (
    'theft',
    'accidental_damage',
    'liquid_damage',
    'fire_damage',
    'natural_disaster',
    'mechanical_failure'
);

CREATE TABLE kernel.claims (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    claim_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    claim_number TEXT UNIQUE NOT NULL,
    
    policy_id UUID NOT NULL REFERENCES kernel.insurance_policies(policy_id),
    device_id UUID NOT NULL REFERENCES kernel.devices(device_id),
    
    -- Incident
    incident_date TIMESTAMP WITH TIME ZONE NOT NULL,
    incident_type kernel.incident_type NOT NULL,
    incident_description TEXT,
    incident_location JSONB,
    
    -- Evidence
    evidence_attachments JSONB,
    police_report_reference TEXT,
    
    -- Assessment
    adjuster_id UUID REFERENCES kernel.participants(participant_id),
    assessment_notes TEXT,
    assessed_amount DECIMAL(15, 2),
    
    -- Decision
    status kernel.claim_status DEFAULT 'filed',
    decision_timestamp TIMESTAMP WITH TIME ZONE,
    denial_reason TEXT,
    
    -- Payout
    approved_amount DECIMAL(15, 2),
    actual_payout_amount DECIMAL(15, 2),
    payout_method VARCHAR(32),
    payout_timestamp TIMESTAMP WITH TIME ZONE,
    
    -- Repair link
    repair_order_id UUID,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    signature TEXT,
    proof_inclusion UUID,
    
    CONSTRAINT chk_claims_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_claims_claim ON kernel.claims(claim_id);
CREATE INDEX idx_claims_policy ON kernel.claims(policy_id);
CREATE INDEX idx_claims_status ON kernel.claims(status);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION kernel.create_insurance_policy(
    p_device_id UUID,
    p_insurer_id UUID,
    p_policyholder_id UUID,
    p_coverage_type kernel.coverage_type,
    p_coverage_limit DECIMAL,
    p_deductible DECIMAL,
    p_premium DECIMAL,
    p_start_date DATE,
    p_end_date DATE
)
RETURNS UUID AS $$
DECLARE
    v_policy_id UUID;
    v_policy_number TEXT;
BEGIN
    v_policy_number := 'POL-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    
    INSERT INTO kernel.insurance_policies (
        policy_number, device_id, insurer_id, policyholder_id,
        coverage_type, coverage_limit, deductible_amount, premium_amount,
        effective_start_date, effective_end_date, created_by
    ) VALUES (
        v_policy_number, p_device_id, p_insurer_id, p_policyholder_id,
        p_coverage_type, p_coverage_limit, p_deductible, p_premium,
        p_start_date, p_end_date, security.get_participant_context()
    )
    RETURNING policy_id INTO v_policy_id;
    
    RETURN v_policy_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kernel.file_claim(
    p_policy_id UUID,
    p_incident_date TIMESTAMP WITH TIME ZONE,
    p_incident_type kernel.incident_type,
    p_description TEXT
)
RETURNS UUID AS $$
DECLARE
    v_claim_id UUID;
    v_device_id UUID;
    v_claim_number TEXT;
BEGIN
    SELECT device_id INTO v_device_id FROM kernel.insurance_policies WHERE policy_id = p_policy_id;
    
    v_claim_number := 'CLM-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    
    INSERT INTO kernel.claims (
        claim_number, policy_id, device_id, incident_date, incident_type,
        incident_description, created_by
    ) VALUES (
        v_claim_number, p_policy_id, v_device_id, p_incident_date, p_incident_type,
        p_description, security.get_participant_context()
    )
    RETURNING claim_id INTO v_claim_id;
    
    UPDATE kernel.insurance_policies
    SET claims_count = claims_count + 1
    WHERE policy_id = p_policy_id;
    
    RETURN v_claim_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 10: Insurance Policy & Claim initialized' AS status;
