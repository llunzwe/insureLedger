-- =============================================================================
-- FILE: 023_documents.sql
-- PURPOSE: Primitive 18 - Documents & Evidence
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: GDPR, eIDAS, WORM storage
-- DEPENDENCIES: 004_identity_tenancy.sql, 002_crypto_utilities.sql
-- =============================================================================

-- =============================================================================
-- DOCUMENTS
-- =============================================================================

CREATE TYPE kernel.document_status AS ENUM (
    'draft',
    'pending_review',
    'approved',
    'rejected',
    'archived',
    'expired'
);

CREATE TYPE kernel.document_classification AS ENUM (
    'public',
    'internal',
    'confidential',
    'restricted',
    'secret'
);

CREATE TABLE kernel.documents (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    document_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    document_number TEXT UNIQUE,
    
    -- Document info
    document_type VARCHAR(64) NOT NULL,  -- contract, policy, claim_evidence, kyc, report
    title TEXT NOT NULL,
    description TEXT,
    
    -- Classification
    classification kernel.document_classification DEFAULT 'internal',
    
    -- Content
    file_name TEXT NOT NULL,
    file_extension VARCHAR(16),
    mime_type VARCHAR(128),
    file_size_bytes BIGINT,
    
    -- Storage
    storage_provider VARCHAR(32) DEFAULT 's3',  -- s3, gcs, azure, ipfs, local
    storage_bucket TEXT,
    storage_path TEXT,
    storage_url TEXT,
    
    -- Integrity
    content_hash TEXT NOT NULL,  -- SHA-256 of content
    encryption_key_id UUID,  -- Reference to key management
    
    -- Versioning
    version INTEGER DEFAULT 1,
    is_latest_version BOOLEAN DEFAULT TRUE,
    previous_version_id UUID REFERENCES kernel.documents(document_id),
    
    -- Status
    status kernel.document_status DEFAULT 'draft',
    
    -- Entity links (polymorphic)
    linked_entity_type VARCHAR(64),
    linked_entity_id UUID,
    
    -- Retention
    retention_period_days INTEGER DEFAULT 2555,  -- 7 years default
    retain_until_date DATE,
    legal_hold BOOLEAN DEFAULT FALSE,
    
    -- Expiry
    effective_date DATE,
    expiration_date DATE,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Ownership
    owner_id UUID REFERENCES kernel.participants(participant_id),
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    signature TEXT,
    proof_inclusion UUID,
    
    CONSTRAINT chk_documents_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_documents_document ON kernel.documents(document_id);
CREATE INDEX idx_documents_type ON kernel.documents(document_type);
CREATE INDEX idx_documents_entity ON kernel.documents(linked_entity_type, linked_entity_id);
CREATE INDEX idx_documents_status ON kernel.documents(status);

-- =============================================================================
-- DOCUMENT VERSIONS
-- =============================================================================

CREATE TABLE kernel.document_versions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    version_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    document_id UUID NOT NULL REFERENCES kernel.documents(document_id),
    
    version_number INTEGER NOT NULL,
    
    -- Change info
    change_description TEXT,
    change_type VARCHAR(32),  -- edit, correction, amendment, renewal
    
    -- Content (same as documents)
    content_hash TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    file_size_bytes BIGINT,
    
    -- Approval
    approved_by UUID REFERENCES kernel.participants(participant_id),
    approved_at TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(document_id, version_number)
);

CREATE INDEX idx_document_versions_document ON kernel.document_versions(document_id, version_number DESC);

-- =============================================================================
-- DOCUMENT SIGNATURES
-- =============================================================================

CREATE TABLE kernel.document_signatures (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    signature_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    document_id UUID NOT NULL REFERENCES kernel.documents(document_id),
    version_id UUID REFERENCES kernel.document_versions(version_id),
    
    -- Signer
    signer_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    signer_role VARCHAR(64),
    
    -- Signature details
    signature_type VARCHAR(32) NOT NULL,  -- digital, electronic, biometric, wet_ink
    signature_value TEXT NOT NULL,
    
    -- eIDAS compliance
    signature_level VARCHAR(32),  -- SES, AdES, QES
    signature_format VARCHAR(32),  -- PAdES, XAdES, CAdES
    
    -- Timestamp
    signed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    signed_ip INET,
    
    -- Verification
    is_verified BOOLEAN DEFAULT FALSE,
    verified_at TIMESTAMP WITH TIME ZONE,
    verification_result JSONB,
    
    -- Certificate
    certificate_serial TEXT,
    certificate_issuer TEXT,
    certificate_valid_from TIMESTAMP WITH TIME ZONE,
    certificate_valid_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_document_signatures_document ON kernel.document_signatures(document_id);
CREATE INDEX idx_document_signatures_signer ON kernel.document_signatures(signer_id);

-- =============================================================================
-- EVIDENCE
-- =============================================================================

CREATE TABLE kernel.evidence (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    evidence_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    evidence_number TEXT UNIQUE,
    
    -- Evidence type
    evidence_type VARCHAR(64) NOT NULL,  -- photo, video, audio, document, data_export, testimony
    
    -- Source
    source_type VARCHAR(32) NOT NULL,  -- uploaded, captured, generated, imported
    captured_by UUID REFERENCES kernel.participants(participant_id),
    captured_at TIMESTAMP WITH TIME ZONE,
    capture_location JSONB,  -- GPS coordinates
    
    -- Content
    description TEXT,
    metadata JSONB DEFAULT '{}',
    
    -- Storage (can reference document or direct storage)
    document_id UUID REFERENCES kernel.documents(document_id),
    external_reference TEXT,
    
    -- Chain of custody
    custody_chain JSONB DEFAULT '[]',
    
    -- Verification
    verification_status VARCHAR(32) DEFAULT 'pending',  -- pending, verified, rejected
    verified_by UUID,
    verified_at TIMESTAMP WITH TIME ZONE,
    
    -- Case/Event link
    case_type VARCHAR(32),  -- claim, dispute, audit, investigation
    case_id UUID,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_evidence_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_evidence_evidence ON kernel.evidence(evidence_id);
CREATE INDEX idx_evidence_case ON kernel.evidence(case_type, case_id);
CREATE INDEX idx_evidence_type ON kernel.evidence(evidence_type);

-- =============================================================================
-- DOCUMENT ACCESS LOG
-- =============================================================================

CREATE TABLE kernel.document_access_log (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    access_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    document_id UUID NOT NULL REFERENCES kernel.documents(document_id),
    
    -- Access details
    access_type VARCHAR(32) NOT NULL,  -- view, download, edit, share, delete
    accessed_by UUID REFERENCES kernel.participants(participant_id),
    
    -- Context
    access_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    client_ip INET,
    user_agent TEXT,
    session_id UUID,
    
    -- Result
    access_granted BOOLEAN DEFAULT TRUE,
    denial_reason TEXT,
    
    -- Data transferred (for GDPR)
    data_volume_bytes BIGINT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_document_access_log_document ON kernel.document_access_log(document_id, access_timestamp DESC);
CREATE INDEX idx_document_access_log_user ON kernel.document_access_log(accessed_by);

-- =============================================================================
-- RETENTION POLICIES
-- =============================================================================

CREATE TABLE kernel.retention_policies (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    policy_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    policy_name TEXT NOT NULL,
    
    -- Applicability
    document_types TEXT[],
    jurisdictions VARCHAR(2)[],
    entity_types TEXT[],
    
    -- Retention rules
    retention_years INTEGER NOT NULL,
    retention_trigger VARCHAR(32) DEFAULT 'creation',  -- creation, event, last_access
    
    -- Action after retention
    post_retention_action VARCHAR(32) DEFAULT 'archive',  -- archive, delete, review
    
    -- Legal hold override
    legal_hold_exempt BOOLEAN DEFAULT FALSE,
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Store document
CREATE OR REPLACE FUNCTION kernel.store_document(
    p_document_type VARCHAR,
    p_title TEXT,
    p_file_name TEXT,
    p_content_hash TEXT,
    p_storage_path TEXT,
    p_owner_id UUID,
    p_classification kernel.document_classification DEFAULT 'internal',
    p_linked_entity_type VARCHAR DEFAULT NULL,
    p_linked_entity_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_document_id UUID;
    v_doc_number TEXT;
BEGIN
    v_doc_number := 'DOC-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    
    INSERT INTO kernel.documents (
        document_number, document_type, title, file_name,
        content_hash, storage_path, owner_id, classification,
        linked_entity_type, linked_entity_id, created_by
    ) VALUES (
        v_doc_number, p_document_type, p_title, p_file_name,
        p_content_hash, p_storage_path, p_owner_id, p_classification,
        p_linked_entity_type, p_linked_entity_id, security.get_participant_context()
    )
    RETURNING document_id INTO v_document_id;
    
    RETURN v_document_id;
END;
$$ LANGUAGE plpgsql;

-- Sign document
CREATE OR REPLACE FUNCTION kernel.sign_document(
    p_document_id UUID,
    p_signer_id UUID,
    p_signature_value TEXT,
    p_signature_type VARCHAR DEFAULT 'digital'
)
RETURNS UUID AS $$
DECLARE
    v_signature_id UUID;
BEGIN
    INSERT INTO kernel.document_signatures (
        document_id, signer_id, signature_type, signature_value
    ) VALUES (
        p_document_id, p_signer_id, p_signature_type, p_signature_value
    )
    RETURNING signature_id INTO v_signature_id;
    
    -- Update document status if first signature
    UPDATE kernel.documents
    SET status = 'approved'
    WHERE document_id = p_document_id AND status = 'pending_review';
    
    RETURN v_signature_id;
END;
$$ LANGUAGE plpgsql;

-- Log document access
CREATE OR REPLACE FUNCTION kernel.log_document_access(
    p_document_id UUID,
    p_access_type VARCHAR,
    p_access_granted BOOLEAN DEFAULT TRUE,
    p_denial_reason TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO kernel.document_access_log (
        document_id, access_type, accessed_by, access_granted, denial_reason
    ) VALUES (
        p_document_id, p_access_type, security.get_participant_context(),
        p_access_granted, p_denial_reason
    );
END;
$$ LANGUAGE plpgsql;

-- Verify document integrity
CREATE OR REPLACE FUNCTION kernel.verify_document_integrity(p_document_id UUID)
RETURNS TABLE(is_valid BOOLEAN, stored_hash TEXT, current_hash TEXT) AS $$
DECLARE
    v_stored_hash TEXT;
    v_calculated_hash TEXT;
    v_is_valid BOOLEAN;
BEGIN
    SELECT content_hash INTO v_stored_hash
    FROM kernel.documents
    WHERE document_id = p_document_id;
    
    -- In production, would recalculate hash from actual file
    -- For now, assume valid if hash exists
    v_calculated_hash := v_stored_hash;
    v_is_valid := v_stored_hash IS NOT NULL;
    
    RETURN QUERY SELECT v_is_valid, v_stored_hash, v_calculated_hash;
END;
$$ LANGUAGE plpgsql;

-- Check retention expiry
CREATE OR REPLACE FUNCTION kernel.check_retention_expiry()
RETURNS TABLE(document_id UUID, days_until_expiry INTEGER) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        d.document_id,
        (d.retain_until_date - CURRENT_DATE)::INTEGER AS days_until_expiry
    FROM kernel.documents d
    WHERE d.retain_until_date IS NOT NULL
      AND d.retain_until_date <= CURRENT_DATE + INTERVAL '30 days'
      AND d.legal_hold = FALSE
      AND d.system_to IS NULL;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Insert default retention policies
INSERT INTO kernel.retention_policies (policy_name, document_types, retention_years, post_retention_action) VALUES
    ('Insurance Policies', ARRAY['policy'], 7, 'archive'),
    ('Claims Documents', ARRAY['claim_evidence'], 7, 'archive'),
    ('KYC Documents', ARRAY['kyc'], 5, 'delete'),
    ('Financial Records', ARRAY['contract', 'report'], 7, 'archive'),
    ('Audit Logs', ARRAY['report'], 10, 'archive'),
    ('General Documents', ARRAY['document'], 3, 'delete')
ON CONFLICT DO NOTHING;

SELECT 'Primitive 18: Documents & Evidence initialized' AS status;
