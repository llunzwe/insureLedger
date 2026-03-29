-- =============================================================================
-- FILE: 004_identity_tenancy.sql
-- PURPOSE: Primitive 1 - Identity & Tenancy (participants, technicians, sequences)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 17442 (LEI), ISO 9362 (BIC), GDPR (PII protection)
-- DEPENDENCIES: 000-003
-- =============================================================================

-- =============================================================================
-- PARTICIPANTS - All actors in the ecosystem
-- =============================================================================

CREATE TABLE kernel.participants (
    -- Identity & Immutability (Common Columns)
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    -- Participant Identity
    participant_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    participant_type kernel.participant_type NOT NULL,
    
    -- Decentralized Identity (DID)
    did TEXT UNIQUE,
    did_document_location TEXT,
    verification_methods JSONB,  -- Array of verification methods per DID spec
    
    -- ISO 17442 LEI (Legal Entity Identifier)
    lei_code TEXT,
    lei_issuer TEXT,
    lei_valid_from DATE,
    lei_valid_to DATE,
    
    -- ISO 9362 BIC (Bank Identifier Code)
    bic_code TEXT,
    
    -- Contact & Legal (GDPR - hashed/encrypted)
    business_name TEXT,
    individual_name TEXT,
    trading_name TEXT,
    
    -- Address reference (FK added in 029_kernel_wiring.sql after addresses table exists)
    registered_address_id UUID
    
    -- Contact info (hashed for GDPR)
    tax_identifier_hash TEXT,  -- Hashed tax ID
    contact_email_hash TEXT,   -- Hashed email
    phone_hash TEXT,           -- Hashed phone
    
    -- Unencrypted contact (for operational use)
    contact_email_encrypted TEXT,  -- AEAD encrypted
    phone_encrypted TEXT,
    
    -- Credentials & Verification
    verifiable_credentials JSONB,  -- Array of VC references
    kyc_status VARCHAR(32) DEFAULT 'pending',
    kyc_verified_at TIMESTAMP WITH TIME ZONE,
    kyc_expires_at TIMESTAMP WITH TIME ZONE,
    aml_verified BOOLEAN DEFAULT FALSE,
    aml_verified_at TIMESTAMP WITH TIME ZONE,
    
    -- Sanctions screening
    sanctions_status VARCHAR(32) DEFAULT 'clear',  -- clear, watch, blocked
    last_sanctions_check TIMESTAMP WITH TIME ZONE,
    
    -- Risk scoring
    risk_score INTEGER CHECK (risk_score BETWEEN 0 AND 100),
    risk_category VARCHAR(32),
    
    -- Roles & Permissions
    roles TEXT[],
    permission_set_id UUID,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    activation_date DATE,
    suspension_history JSONB,  -- Array of suspension records
    
    -- GDPR consent
    gdpr_consent BOOLEAN DEFAULT FALSE,
    gdpr_consent_at TIMESTAMP WITH TIME ZONE,
    marketing_consent BOOLEAN DEFAULT FALSE,
    
    -- Bitemporal Tracking
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit Trail
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    -- Multi-tenancy (NULL for non-tenant entities)
    tenant_id UUID,
    
    -- Verification
    signature TEXT,
    proof_inclusion UUID,
    
    -- Constraints
    CONSTRAINT chk_participants_temporal_system 
        CHECK (system_from <= system_to OR system_to IS NULL),
    CONSTRAINT chk_participants_temporal_valid 
        CHECK (valid_from <= valid_to OR valid_to IS NULL),
    CONSTRAINT chk_participants_name 
        CHECK (business_name IS NOT NULL OR individual_name IS NOT NULL),
    CONSTRAINT chk_participants_lei 
        CHECK (lei_code IS NULL OR kernel.validate_lei(lei_code)),
    CONSTRAINT chk_participants_bic 
        CHECK (bic_code IS NULL OR kernel.validate_bic(bic_code))
);

COMMENT ON TABLE kernel.participants IS 
'All actors in the insureLedger ecosystem: customers, insurers, OEMs, e-commerce, technicians, regulators. Implements ISO 17442 LEI, GDPR-compliant PII handling.';

-- Indexes
CREATE INDEX idx_participants_participant_id ON kernel.participants(participant_id);
CREATE INDEX idx_participants_type ON kernel.participants(participant_type);
CREATE INDEX idx_participants_did ON kernel.participants(did) WHERE did IS NOT NULL;
CREATE INDEX idx_participants_lei ON kernel.participants(lei_code) WHERE lei_code IS NOT NULL;
CREATE INDEX idx_participants_system_current ON kernel.participants(system_from, system_to) WHERE system_to IS NULL;
CREATE INDEX idx_participants_active ON kernel.participants(participant_id, system_from, system_to) WHERE system_to IS NULL;
CREATE INDEX idx_participants_risk ON kernel.participants(risk_score) WHERE risk_score > 50;
CREATE INDEX idx_participants_sanctions ON kernel.participants(sanctions_status) WHERE sanctions_status != 'clear';

-- =============================================================================
-- PARTICIPANT IDENTIFIERS - Multiple identifiers per participant
-- =============================================================================

CREATE TABLE kernel.participant_identifiers (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    identifier_type VARCHAR(32) NOT NULL,  -- email, phone, national_id, tax_id, passport, driver_license
    identifier_value_hash TEXT NOT NULL,   -- Hashed value
    identifier_value_encrypted TEXT,       -- Encrypted value (for recovery)
    
    -- Verification
    is_verified BOOLEAN DEFAULT FALSE,
    verified_at TIMESTAMP WITH TIME ZONE,
    verification_method VARCHAR(32),  -- otp, document, third_party
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_primary BOOLEAN DEFAULT FALSE,
    
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE (participant_id, identifier_type, identifier_value_hash)
);

COMMENT ON TABLE kernel.participant_identifiers IS 'Multiple identifiers per participant with verification status (GDPR-compliant)';

CREATE INDEX idx_participant_identifiers_participant ON kernel.participant_identifiers(participant_id);
CREATE INDEX idx_participant_identifiers_active ON kernel.participant_identifiers(participant_id, identifier_type) WHERE is_active = TRUE;

-- =============================================================================
-- TECHNICIAN TENANTS - Specialized participant for repair shops
-- =============================================================================

CREATE TABLE kernel.technician_tenants (
    -- Identity & Immutability
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    -- Reference to base participant
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Tenant Identity
    tenant_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    business_type kernel.business_type NOT NULL DEFAULT 'individual',
    
    -- Certifications (OEM authorizations, ISO)
    certifications JSONB,  -- [{type, issuer, issued_date, expiry_date, vc_reference}]
    
    -- Geographic Scope
    serviceable_regions TEXT[],  -- Region codes
    serviceable_country_codes TEXT[],  -- ISO 3166
    
    -- Shop locations (references addresses table)
    shop_location_ids UUID[],
    
    -- Operational Details
    max_concurrent_repairs INTEGER DEFAULT 1,
    average_turnaround_hours INTEGER,
    specialties TEXT[],  -- e.g., ['screen_repair', 'battery_replacement', 'water_damage']
    
    -- Reputation
    rating DECIMAL(3,2) CHECK (rating >= 0 AND rating <= 5),
    total_reviews INTEGER DEFAULT 0,
    dispute_count INTEGER DEFAULT 0,
    dispute_history JSONB,  -- Array of dispute references
    
    -- Financial
    settlement_account_id UUID,  -- References value_containers
    
    -- Bitemporal Tracking
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit Trail
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    -- Verification
    signature TEXT,
    proof_inclusion UUID,
    
    -- Constraints
    CONSTRAINT chk_tech_tenant_temporal_system 
        CHECK (system_from <= system_to OR system_to IS NULL),
    CONSTRAINT chk_tech_tenant_temporal_valid 
        CHECK (valid_from <= valid_to OR valid_to IS NULL)
);

COMMENT ON TABLE kernel.technician_tenants IS 'Specialized participant for repair technicians/shops with tenant isolation';

CREATE INDEX idx_technician_tenants_participant ON kernel.technician_tenants(participant_id);
CREATE INDEX idx_technician_tenants_tenant ON kernel.technician_tenants(tenant_id);
CREATE INDEX idx_technician_tenants_system_current ON kernel.technician_tenants(system_from, system_to) WHERE system_to IS NULL;
CREATE INDEX idx_technician_tenants_regions ON kernel.technician_tenants USING GIN(serviceable_regions);

-- =============================================================================
-- ENTITY SEQUENCES - Human-readable codes per tenant
-- =============================================================================

CREATE TABLE kernel.entity_sequences (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    tenant_id UUID,  -- NULL for global sequences
    
    sequence_name VARCHAR(64) NOT NULL,  -- repair_order, claim, policy
    sequence_prefix VARCHAR(16) NOT NULL,  -- RPR, CLM, POL
    
    current_year INTEGER NOT NULL DEFAULT EXTRACT(YEAR FROM NOW()),
    current_number INTEGER NOT NULL DEFAULT 0,
    
    padding_length INTEGER DEFAULT 6,  -- e.g., 000123
    
    UNIQUE (tenant_id, sequence_name, current_year)
);

COMMENT ON TABLE kernel.entity_sequences IS 'Human-readable sequential codes per tenant (e.g., RPR-2024-000123)';

-- Function to get next sequence number
CREATE OR REPLACE FUNCTION kernel.get_next_sequence(
    p_tenant_id UUID,
    p_sequence_name VARCHAR(64),
    p_prefix VARCHAR(16)
)
RETURNS TEXT AS $$
DECLARE
    v_year INTEGER := EXTRACT(YEAR FROM NOW());
    v_number INTEGER;
    v_record RECORD;
BEGIN
    -- Try to update existing row
    UPDATE kernel.entity_sequences
    SET current_number = current_number + 1
    WHERE tenant_id = p_tenant_id
      AND sequence_name = p_sequence_name
      AND current_year = v_year
    RETURNING * INTO v_record;
    
    -- If no row, insert new
    IF v_record IS NULL THEN
        INSERT INTO kernel.entity_sequences (
            tenant_id, sequence_name, sequence_prefix, 
            current_year, current_number
        ) VALUES (
            p_tenant_id, p_sequence_name, p_prefix,
            v_year, 1
        )
        ON CONFLICT (tenant_id, sequence_name, current_year) 
        DO UPDATE SET current_number = entity_sequences.current_number + 1
        RETURNING * INTO v_record;
    END IF;
    
    RETURN v_record.sequence_prefix || '-' || 
           v_record.current_year || '-' ||
           LPAD(v_record.current_number::TEXT, v_record.padding_length, '0');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.get_next_sequence(UUID, VARCHAR, VARCHAR) IS 'Generate next human-readable sequence number';

-- =============================================================================
-- RLS POLICIES FOR IDENTITY TABLES
-- =============================================================================

ALTER TABLE kernel.participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.technician_tenants ENABLE ROW LEVEL SECURITY;

-- Participants can see their own record
CREATE POLICY participants_self_access ON kernel.participants
    FOR ALL
    USING (participant_id = security.get_participant_context());

-- Public profile for verified entities
CREATE POLICY participants_public_profile ON kernel.participants
    FOR SELECT
    USING (
        participant_type IN ('oem', 'certification_body', 'regulator')
        OR (is_active = TRUE AND kyc_status = 'verified')
    );

-- Regulators see all
CREATE POLICY participants_regulator_access ON kernel.participants
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM kernel.participants p
            WHERE p.participant_id = security.get_participant_context()
              AND p.participant_type = 'regulator'
        )
    );

-- Technician tenant isolation
CREATE POLICY technician_tenant_isolation ON kernel.technician_tenants
    USING (tenant_id = security.get_tenant_context());

-- =============================================================================
-- INITIALIZATION COMPLETE
-- =============================================================================

SELECT 'Primitive 1: Identity & Tenancy initialized' AS status;
