-- =============================================================================
-- FILE: 022_jurisdictions.sql
-- PURPOSE: Primitive 17 - Jurisdictions & Regulatory
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 3166-2, FATF, Basel III
-- DEPENDENCIES: 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- JURISDICTIONS
-- =============================================================================

CREATE TYPE kernel.risk_rating AS ENUM (
    'low',
    'moderate',
    'high',
    'prohibited'
);

CREATE TABLE kernel.jurisdictions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    jurisdiction_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    jurisdiction_code VARCHAR(2) NOT NULL,  -- ISO 3166-1 alpha-2
    subdivision_code VARCHAR(6),  -- ISO 3166-2 for states/provinces
    
    -- Names
    name TEXT NOT NULL,
    official_name TEXT,
    local_name TEXT,
    
    -- Hierarchy
    parent_jurisdiction_id UUID REFERENCES kernel.jurisdictions(jurisdiction_id),
    jurisdiction_level VARCHAR(16) NOT NULL,  -- country, state, province, city
    
    -- Risk
    fatf_risk_rating kernel.risk_rating DEFAULT 'low',
    eu_high_risk_third_country BOOLEAN DEFAULT FALSE,
    ofac_sanctioned BOOLEAN DEFAULT FALSE,
    
    -- Regulatory
    regulatory_framework TEXT[],  -- GDPR, SOX, PCI_DSS, etc.
    currency_codes VARCHAR(3)[],  -- Official currencies
    timezone TEXT,
    
    -- Banking
    central_bank_name TEXT,
    swift_country_code VARCHAR(2),
    iban_country_code VARCHAR(2),
    iban_length INTEGER,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    effective_from DATE DEFAULT CURRENT_DATE,
    effective_to DATE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(jurisdiction_code, subdivision_code)
);

CREATE INDEX idx_jurisdictions_code ON kernel.jurisdictions(jurisdiction_code);
CREATE INDEX idx_jurisdictions_risk ON kernel.jurisdictions(fatf_risk_rating);
CREATE INDEX idx_jurisdictions_parent ON kernel.jurisdictions(parent_jurisdiction_id);

-- =============================================================================
-- REGULATORY BODIES
-- =============================================================================

CREATE TABLE kernel.regulatory_bodies (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    body_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    body_code TEXT UNIQUE NOT NULL,
    
    name TEXT NOT NULL,
    full_name TEXT,
    abbreviation TEXT,
    
    -- Jurisdiction
    jurisdiction_id UUID NOT NULL REFERENCES kernel.jurisdictions(jurisdiction_id),
    
    -- Type
    body_type VARCHAR(32),  -- central_bank, securities_regulator, data_protection, etc.
    
    -- Contact
    website TEXT,
    contact_email TEXT,
    contact_phone TEXT,
    address JSONB,
    
    -- Scope
    regulatory_scope TEXT[],  -- banking, securities, insurance, payments, data
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_regulatory_bodies_jurisdiction ON kernel.regulatory_bodies(jurisdiction_id);

-- =============================================================================
-- REGULATORY REQUIREMENTS
-- =============================================================================

CREATE TYPE kernel.requirement_type AS ENUM (
    'reporting',
    'licensing',
    'capital',
    'kyc',
    'aml',
    'data_protection',
    'audit',
    'disclosure'
);

CREATE TYPE kernel.compliance_frequency AS ENUM (
    'one_time',
    'event_driven',
    'daily',
    'weekly',
    'monthly',
    'quarterly',
    'semi_annual',
    'annual'
);

CREATE TABLE kernel.regulatory_requirements (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    requirement_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    requirement_code TEXT UNIQUE NOT NULL,
    
    -- Description
    name TEXT NOT NULL,
    description TEXT,
    regulatory_reference TEXT,  -- Legal citation
    
    -- Applicability
    requirement_type kernel.requirement_type NOT NULL,
    jurisdiction_id UUID REFERENCES kernel.jurisdictions(jurisdiction_id),
    regulatory_body_id UUID REFERENCES kernel.regulatory_bodies(body_id),
    
    -- Frequency
    frequency kernel.compliance_frequency NOT NULL,
    due_day_of_month INTEGER,
    due_month INTEGER,
    
    -- Thresholds
    applies_to_participant_types TEXT[],
    minimum_assets_threshold DECIMAL(24, 6),
    minimum_transaction_volume DECIMAL(24, 6),
    
    -- Requirements
    required_documents TEXT[],
    required_data_fields TEXT[],
    
    -- Penalties
    penalty_description TEXT,
    
    is_active BOOLEAN DEFAULT TRUE,
    effective_from DATE DEFAULT CURRENT_DATE,
    effective_to DATE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_regulatory_requirements_type ON kernel.regulatory_requirements(requirement_type);
CREATE INDEX idx_regulatory_requirements_jurisdiction ON kernel.regulatory_requirements(jurisdiction_id);

-- =============================================================================
-- COMPLIANCE REGISTRATIONS
-- =============================================================================

CREATE TABLE kernel.compliance_registrations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    registration_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Registrant
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    jurisdiction_id UUID NOT NULL REFERENCES kernel.jurisdictions(jurisdiction_id),
    
    -- Registration details
    registration_type VARCHAR(32) NOT NULL,  -- license, authorization, exemption
    registration_number TEXT,
    
    -- Regulatory body
    regulatory_body_id UUID REFERENCES kernel.regulatory_bodies(body_id),
    
    -- Status
    status VARCHAR(32) DEFAULT 'active',  -- active, suspended, revoked, expired
    
    -- Validity
    issued_date DATE,
    effective_date DATE NOT NULL,
    expiration_date DATE,
    
    -- Conditions
    conditions TEXT[],
    restrictions TEXT[],
    
    -- Documents
    license_document_url TEXT,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_compliance_registrations_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_compliance_registrations_participant ON kernel.compliance_registrations(participant_id);
CREATE INDEX idx_compliance_registrations_jurisdiction ON kernel.compliance_registrations(jurisdiction_id);

-- =============================================================================
-- COMPLIANCE REPORTING
-- =============================================================================

CREATE TABLE kernel.compliance_reports (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    report_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Report details
    requirement_id UUID NOT NULL REFERENCES kernel.regulatory_requirements(requirement_id),
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Period
    reporting_period_start DATE NOT NULL,
    reporting_period_end DATE NOT NULL,
    
    -- Status
    status VARCHAR(32) DEFAULT 'draft',  -- draft, submitted, accepted, rejected
    
    -- Submission
    submitted_at TIMESTAMP WITH TIME ZONE,
    submitted_by UUID,
    submission_reference TEXT,
    
    -- Response
    regulatory_response TEXT,
    responded_at TIMESTAMP WITH TIME ZONE,
    
    -- Content
    report_data JSONB,
    attachments JSONB,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_compliance_reports_requirement ON kernel.compliance_reports(requirement_id);
CREATE INDEX idx_compliance_reports_participant ON kernel.compliance_reports(participant_id);

-- =============================================================================
-- TAX INFORMATION
-- =============================================================================

CREATE TABLE kernel.tax_information (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    tax_info_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    jurisdiction_id UUID NOT NULL REFERENCES kernel.jurisdictions(jurisdiction_id),
    
    -- Tax ID
    tax_id_type VARCHAR(32) NOT NULL,  -- tin, vat, gst, ein, etc.
    tax_id_number TEXT NOT NULL,
    
    -- Validation
    is_verified BOOLEAN DEFAULT FALSE,
    verified_at TIMESTAMP WITH TIME ZONE,
    verified_by UUID,
    
    -- Withholding
    withholding_rate DECIMAL(5, 4) DEFAULT 0,  -- 0.0000 to 1.0000
    withholding_exempt BOOLEAN DEFAULT FALSE,
    exemption_certificate TEXT,
    
    -- FATCA/CRS
    fatca_status VARCHAR(32),  -- compliant, non_compliant, recalcitrant
    crs_classification VARCHAR(32),  -- tax_resident, non_resident, dual_resident
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_tax_information_temporal CHECK (system_from <= system_to OR system_to IS NULL),
    UNIQUE(participant_id, jurisdiction_id, tax_id_type)
);

CREATE INDEX idx_tax_information_participant ON kernel.tax_information(participant_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Get jurisdiction risk rating
CREATE OR REPLACE FUNCTION kernel.get_jurisdiction_risk_rating(p_jurisdiction_code VARCHAR)
RETURNS kernel.risk_rating AS $$
DECLARE
    v_rating kernel.risk_rating;
BEGIN
    SELECT fatf_risk_rating INTO v_rating
    FROM kernel.jurisdictions
    WHERE jurisdiction_code = p_jurisdiction_code
      AND is_active = TRUE;
    
    RETURN COALESCE(v_rating, 'high');
END;
$$ LANGUAGE plpgsql;

-- Check if participant is compliant in jurisdiction
CREATE OR REPLACE FUNCTION kernel.is_participant_compliant(
    p_participant_id UUID,
    p_jurisdiction_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
    v_is_compliant BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM kernel.compliance_registrations
        WHERE participant_id = p_participant_id
          AND jurisdiction_id = p_jurisdiction_id
          AND status = 'active'
          AND (expiration_date IS NULL OR expiration_date > CURRENT_DATE)
          AND system_to IS NULL
    ) INTO v_is_compliant;
    
    RETURN v_is_compliant;
END;
$$ LANGUAGE plpgsql;

-- Register compliance
CREATE OR REPLACE FUNCTION kernel.register_compliance(
    p_participant_id UUID,
    p_jurisdiction_id UUID,
    p_registration_type VARCHAR,
    p_registration_number TEXT,
    p_effective_date DATE,
    p_expiration_date DATE DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_registration_id UUID;
BEGIN
    INSERT INTO kernel.compliance_registrations (
        participant_id, jurisdiction_id, registration_type, registration_number,
        effective_date, expiration_date, created_by
    ) VALUES (
        p_participant_id, p_jurisdiction_id, p_registration_type, p_registration_number,
        p_effective_date, p_expiration_date, security.get_participant_context()
    )
    RETURNING registration_id INTO v_registration_id;
    
    RETURN v_registration_id;
END;
$$ LANGUAGE plpgsql;

-- Submit compliance report
CREATE OR REPLACE FUNCTION kernel.submit_compliance_report(
    p_requirement_id UUID,
    p_participant_id UUID,
    p_period_start DATE,
    p_period_end DATE,
    p_report_data JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_report_id UUID;
BEGIN
    INSERT INTO kernel.compliance_reports (
        requirement_id, participant_id, reporting_period_start, reporting_period_end,
        report_data, submitted_at, submitted_by, status
    ) VALUES (
        p_requirement_id, p_participant_id, p_period_start, p_period_end,
        p_report_data, NOW(), security.get_participant_context(), 'submitted'
    )
    RETURNING report_id INTO v_report_id;
    
    RETURN v_report_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Insert common jurisdictions
INSERT INTO kernel.jurisdictions (jurisdiction_code, name, jurisdiction_level, fatf_risk_rating, currency_codes, timezone) VALUES
    ('US', 'United States', 'country', 'low', ARRAY['USD'], 'America/New_York'),
    ('GB', 'United Kingdom', 'country', 'low', ARRAY['GBP'], 'Europe/London'),
    ('DE', 'Germany', 'country', 'low', ARRAY['EUR'], 'Europe/Berlin'),
    ('FR', 'France', 'country', 'low', ARRAY['EUR'], 'Europe/Paris'),
    ('JP', 'Japan', 'country', 'low', ARRAY['JPY'], 'Asia/Tokyo'),
    ('SG', 'Singapore', 'country', 'low', ARRAY['SGD'], 'Asia/Singapore'),
    ('CH', 'Switzerland', 'country', 'low', ARRAY['CHF'], 'Europe/Zurich'),
    ('AU', 'Australia', 'country', 'low', ARRAY['AUD'], 'Australia/Sydney'),
    ('CA', 'Canada', 'country', 'low', ARRAY['CAD'], 'America/Toronto'),
    ('HK', 'Hong Kong', 'country', 'low', ARRAY['HKD'], 'Asia/Hong_Kong'),
    ('NL', 'Netherlands', 'country', 'low', ARRAY['EUR'], 'Europe/Amsterdam'),
    ('LU', 'Luxembourg', 'country', 'low', ARRAY['EUR'], 'Europe/Luxembourg')
ON CONFLICT (jurisdiction_code, subdivision_code) DO NOTHING;

-- Insert regulatory bodies
INSERT INTO kernel.regulatory_bodies (body_code, name, full_name, jurisdiction_id, body_type, regulatory_scope) VALUES
    ('FCA', 'FCA', 'Financial Conduct Authority', 
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'GB'),
        'securities_regulator', ARRAY['banking', 'securities', 'payments']),
    ('PRA', 'PRA', 'Prudential Regulation Authority',
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'GB'),
        'central_bank', ARRAY['banking', 'insurance']),
    ('ECB', 'ECB', 'European Central Bank',
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'DE'),
        'central_bank', ARRAY['banking', 'payments']),
    ('SEC', 'SEC', 'Securities and Exchange Commission',
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'US'),
        'securities_regulator', ARRAY['securities']),
    ('FINMA', 'FINMA', 'Swiss Financial Market Supervisory Authority',
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'CH'),
        'securities_regulator', ARRAY['banking', 'securities', 'insurance']),
    ('MAS', 'MAS', 'Monetary Authority of Singapore',
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'SG'),
        'central_bank', ARRAY['banking', 'securities', 'payments']),
    ('JFSA', 'JFSA', 'Japan Financial Services Agency',
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'JP'),
        'securities_regulator', ARRAY['banking', 'securities', 'insurance']),
    ('APRA', 'APRA', 'Australian Prudential Regulation Authority',
        (SELECT jurisdiction_id FROM kernel.jurisdictions WHERE jurisdiction_code = 'AU'),
        'central_bank', ARRAY['banking', 'insurance'])
ON CONFLICT (body_code) DO NOTHING;

SELECT 'Primitive 17: Jurisdictions & Regulatory initialized' AS status;
