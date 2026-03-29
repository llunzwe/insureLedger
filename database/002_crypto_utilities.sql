-- =============================================================================
-- FILE: 002_crypto_utilities.sql
-- PURPOSE: Cryptographic hashing functions, signature utilities, key management
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: FIPS 180-4 (SHA-256), RFC 8032 (Ed25519), Post-quantum ready
-- DEPENDENCIES: 000_schema_setup.sql, 001_common_types.sql
-- =============================================================================

-- =============================================================================
-- KEY MANAGEMENT TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS security.participant_keys (
    key_id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    participant_id UUID NOT NULL,
    
    -- Key metadata
    key_type VARCHAR(32) NOT NULL DEFAULT 'ed25519',
    key_algorithm VARCHAR(64) NOT NULL DEFAULT 'Ed25519',
    key_purpose VARCHAR(64) NOT NULL DEFAULT 'signing',  -- signing, encryption, authentication
    
    -- Public key (private keys stored in HSM/KMS only)
    public_key TEXT NOT NULL,
    public_key_fingerprint TEXT,  -- Hash of public key for quick lookup
    
    -- Certificate (if applicable)
    certificate_pem TEXT,
    certificate_id TEXT,
    certificate_chain TEXT[],
    
    -- Validity
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Revocation
    is_revoked BOOLEAN DEFAULT FALSE,
    revoked_at TIMESTAMP WITH TIME ZONE,
    revoked_reason TEXT,
    
    -- Key derivation
    parent_key_id UUID REFERENCES security.participant_keys(key_id),
    derivation_path TEXT,  -- For hierarchical deterministic keys
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID,
    
    -- Constraints
    UNIQUE (participant_id, key_purpose, valid_from)
);

COMMENT ON TABLE security.participant_keys IS 'Public key storage for digital signature verification. Private keys must be stored in HSM/KMS only.';

CREATE INDEX idx_participant_keys_participant ON security.participant_keys(participant_id);
CREATE INDEX idx_participant_keys_active ON security.participant_keys(participant_id, is_active) WHERE is_active = TRUE;

-- =============================================================================
-- HASHING FUNCTIONS
-- =============================================================================

-- SHA-256 hash of input data
CREATE OR REPLACE FUNCTION crypto.sha256_hash(input_data TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN encode(digest(input_data, 'sha256'), 'hex');
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

COMMENT ON FUNCTION crypto.sha256_hash(TEXT) IS 'Compute SHA-256 hash (FIPS 180-4) and return as hex string';

-- SHA-256 hash of binary data
CREATE OR REPLACE FUNCTION crypto.sha256_hash_binary(input_data BYTEA)
RETURNS TEXT AS $$
BEGIN
    RETURN encode(digest(input_data, 'sha256'), 'hex');
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

-- Double SHA-256 (used in some blockchain implementations)
CREATE OR REPLACE FUNCTION crypto.sha256d(input_data TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN crypto.sha256_hash(crypto.sha256_hash(input_data));
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

-- =============================================================================
-- RECORD HASHING
-- =============================================================================

-- Generate composite hash from JSONB record
CREATE OR REPLACE FUNCTION crypto.hash_record(p_data JSONB)
RETURNS TEXT AS $$
BEGIN
    -- Sort keys for deterministic hashing
    RETURN crypto.sha256_hash(p_data::TEXT);
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

COMMENT ON FUNCTION crypto.hash_record(JSONB) IS 'Generate deterministic SHA-256 hash of JSONB record';

-- Chain hash: H(previous_hash || current_data)
CREATE OR REPLACE FUNCTION crypto.chain_hash(
    p_previous_hash TEXT,
    p_current_data JSONB
)
RETURNS TEXT AS $$
BEGIN
    RETURN crypto.sha256_hash(
        COALESCE(p_previous_hash, 'genesis') || ':' || p_current_data::TEXT
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION crypto.chain_hash(TEXT, JSONB) IS 'Compute chain hash linking to previous record';

-- =============================================================================
-- MERKLE TREE FUNCTIONS
-- =============================================================================

-- Generate Merkle leaf hash (prepend 0x00 for leaf differentiation)
CREATE OR REPLACE FUNCTION crypto.merkle_leaf_hash(p_data TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN crypto.sha256_hash('\x00' || p_data);
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

-- Generate Merkle node hash (combining two children)
CREATE OR REPLACE FUNCTION crypto.merkle_node_hash(
    p_left_hash TEXT,
    p_right_hash TEXT
)
RETURNS TEXT AS $$
DECLARE
    v_combined TEXT;
BEGIN
    -- Sort hashes to ensure consistent ordering
    IF COALESCE(p_left_hash, '') < COALESCE(p_right_hash, '') THEN
        v_combined := '\x01' || COALESCE(p_left_hash, '') || COALESCE(p_right_hash, '');
    ELSE
        v_combined := '\x01' || COALESCE(p_right_hash, '') || COALESCE(p_left_hash, '');
    END IF;
    RETURN crypto.sha256_hash(v_combined);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION crypto.merkle_node_hash(TEXT, TEXT) IS 'Compute parent hash from two child hashes in Merkle tree';

-- Verify Merkle inclusion proof
CREATE OR REPLACE FUNCTION crypto.verify_merkle_proof(
    p_leaf_hash TEXT,
    p_proof_path TEXT[],
    p_expected_root TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_current_hash TEXT := p_leaf_hash;
    v_sibling TEXT;
BEGIN
    FOREACH v_sibling IN ARRAY p_proof_path
    LOOP
        v_current_hash := crypto.merkle_node_hash(v_current_hash, v_sibling);
    END LOOP;
    
    RETURN v_current_hash = p_expected_root;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION crypto.verify_merkle_proof(TEXT, TEXT[], TEXT) IS 'Verify inclusion proof against Merkle root';

-- =============================================================================
-- DIGITAL SIGNATURE FUNCTIONS (RFC 8032 Ed25519 placeholders)
-- =============================================================================

-- Note: For production, use pg_crypto with ed25519 or external signing service
-- These are simplified implementations using HMAC for demonstration

-- Sign data with a key (placeholder for Ed25519)
CREATE OR REPLACE FUNCTION crypto.sign_data(
    p_data TEXT,
    p_private_key TEXT
)
RETURNS TEXT AS $$
BEGIN
    -- In production, replace with actual Ed25519 signing
    -- This is a simplified placeholder using HMAC
    RETURN encode(
        hmac(p_data, p_private_key, 'sha256'),
        'base64'
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION crypto.sign_data(TEXT, TEXT) IS 'Sign data with private key (placeholder - use HSM in production)';

-- Verify signature (placeholder for Ed25519)
CREATE OR REPLACE FUNCTION crypto.verify_signature(
    p_data TEXT,
    p_signature TEXT,
    p_public_key TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_expected_sig TEXT;
BEGIN
    -- In production, replace with actual Ed25519 verification
    -- This is a simplified placeholder
    v_expected_sig := crypto.sign_data(p_data, p_public_key);
    RETURN p_signature = v_expected_sig;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION crypto.verify_signature(TEXT, TEXT, TEXT) IS 'Verify signature against data and public key';

-- =============================================================================
-- RECORD SIGNATURE UTILITIES
-- =============================================================================

-- Generate canonical signature payload
CREATE OR REPLACE FUNCTION crypto.generate_sign_payload(
    p_entity_type TEXT,
    p_entity_id UUID,
    p_version_data JSONB,
    p_timestamp TIMESTAMP WITH TIME ZONE
)
RETURNS TEXT AS $$
DECLARE
    v_payload JSONB;
BEGIN
    v_payload := jsonb_build_object(
        'entity_type', p_entity_type,
        'entity_id', p_entity_id,
        'data', p_version_data,
        'timestamp', p_timestamp
    );
    RETURN v_payload::TEXT;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Verify record signature using stored public key
CREATE OR REPLACE FUNCTION crypto.verify_record_signature(
    p_entity_type TEXT,
    p_entity_id UUID,
    p_data JSONB,
    p_timestamp TIMESTAMP WITH TIME ZONE,
    p_signature TEXT,
    p_signer_participant_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
    v_public_key TEXT;
    v_payload TEXT;
BEGIN
    -- Get active public key for signer
    SELECT public_key INTO v_public_key
    FROM security.participant_keys
    WHERE participant_id = p_signer_participant_id
      AND is_active = TRUE
      AND valid_to IS NULL
      AND is_revoked = FALSE
    ORDER BY valid_from DESC
    LIMIT 1;
    
    IF v_public_key IS NULL THEN
        RETURN FALSE;
    END IF;
    
    -- Generate payload and verify
    v_payload := crypto.generate_sign_payload(p_entity_type, p_entity_id, p_data, p_timestamp);
    RETURN crypto.verify_signature(v_payload, p_signature, v_public_key);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION crypto.verify_record_signature(TEXT, UUID, JSONB, TIMESTAMP WITH TIME ZONE, TEXT, UUID) 
IS 'Verify digital signature of a record using stored public key';

-- =============================================================================
-- NONCE GENERATION
-- =============================================================================

-- Generate cryptographically secure nonce
CREATE OR REPLACE FUNCTION crypto.generate_nonce()
RETURNS TEXT AS $$
BEGIN
    RETURN encode(gen_random_bytes(32), 'hex');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION crypto.generate_nonce() IS 'Generate 256-bit cryptographically secure random nonce';

-- Generate idempotency key
CREATE OR REPLACE FUNCTION crypto.generate_idempotency_key()
RETURNS TEXT AS $$
BEGIN
    RETURN 'idmp_' || encode(gen_random_bytes(16), 'hex') || '_' || extract(epoch from now())::bigint::text;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- POST-QUANTUM READINESS
-- =============================================================================

-- Table to track algorithm agility
CREATE TABLE crypto.algorithm_registry (
    algorithm_id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    algorithm_name VARCHAR(64) NOT NULL,
    algorithm_type VARCHAR(32) NOT NULL,  -- hash, signature, encryption
    algorithm_version VARCHAR(16),
    security_level INTEGER,  -- bits of security
    is_quantum_resistant BOOLEAN DEFAULT FALSE,
    is_deprecated BOOLEAN DEFAULT FALSE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    migration_path TEXT  -- How to migrate from previous algorithm
);

-- Insert standard algorithms
INSERT INTO crypto.algorithm_registry (algorithm_name, algorithm_type, algorithm_version, security_level, is_quantum_resistant) VALUES
    ('SHA-256', 'hash', 'FIPS 180-4', 128, FALSE),
    ('SHA-3-256', 'hash', 'FIPS 202', 128, FALSE),
    ('Ed25519', 'signature', 'RFC 8032', 128, FALSE),
    ('ML-DSA', 'signature', 'FIPS 204', 128, TRUE),  -- CRYSTALS-Dilithium
    ('SLH-DSA', 'signature', 'FIPS 205', 128, TRUE),  -- SPHINCS+
    ('AES-256-GCM', 'encryption', 'NIST', 256, FALSE),
    ('ML-KEM', 'encryption', 'FIPS 203', 128, TRUE)   -- CRYSTALS-Kyber
ON CONFLICT DO NOTHING;

-- =============================================================================
-- INITIALIZATION COMPLETE
-- =============================================================================

SELECT 'Cryptographic utilities initialized' AS status;
