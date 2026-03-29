-- =============================================================================
-- FILE: 016_real_time_auth.sql
-- PURPOSE: Primitive 9 - Real-time Authorization
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: OAuth 2.0, RBAC, ABAC
-- DEPENDENCIES: 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- AUTHORIZATION REQUESTS
-- =============================================================================

CREATE TYPE kernel.auth_decision AS ENUM (
    'permit',
    'deny',
    'indeterminate',
    'not_applicable'
);

CREATE TABLE kernel.authorization_requests (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    request_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Subject
    subject_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    subject_type VARCHAR(32) DEFAULT 'user',
    
    -- Action
    action VARCHAR(64) NOT NULL,  -- read, write, delete, approve, etc.
    resource_type VARCHAR(64) NOT NULL,  -- policy, claim, device, etc.
    resource_id UUID,
    
    -- Context
    tenant_id UUID,
    client_ip INET,
    user_agent TEXT,
    
    -- Decision
    decision kernel.auth_decision,
    decision_reason TEXT,
    
    -- Policy evaluation
    policies_evaluated UUID[],
    policy_decisions JSONB,
    
    -- Timing
    requested_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    decided_at TIMESTAMP WITH TIME ZONE,
    latency_ms INTEGER,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_auth_requests_subject ON kernel.authorization_requests(subject_id, requested_at DESC);
CREATE INDEX idx_auth_requests_resource ON kernel.authorization_requests(resource_type, resource_id);
CREATE INDEX idx_auth_requests_decision ON kernel.authorization_requests(decision);

-- =============================================================================
-- SESSION MANAGEMENT
-- =============================================================================

CREATE TABLE kernel.sessions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    session_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    session_token TEXT UNIQUE NOT NULL,
    
    -- User
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Context
    tenant_id UUID,
    device_id UUID REFERENCES kernel.devices(device_id),
    
    -- Authentication
    auth_method VARCHAR(32),  -- password, mfa, sso, api_key
    auth_factors TEXT[],  -- Which factors were used
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_valid BOOLEAN DEFAULT TRUE,
    
    -- Timing
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    last_activity_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    terminated_at TIMESTAMP WITH TIME ZONE,
    
    -- Termination
    termination_reason TEXT,
    
    -- Metadata
    client_ip INET,
    user_agent TEXT,
    geo_location JSONB,
    
    CONSTRAINT chk_sessions_expires CHECK (expires_at > created_at)
);

CREATE INDEX idx_sessions_token ON kernel.sessions(session_token);
CREATE INDEX idx_sessions_participant ON kernel.sessions(participant_id, is_active);
CREATE INDEX idx_sessions_expires ON kernel.sessions(expires_at) WHERE is_active = TRUE;

-- =============================================================================
-- API KEYS
-- =============================================================================

CREATE TABLE kernel.api_keys (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    api_key_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    api_key_hash TEXT UNIQUE NOT NULL,  -- Hashed key (never store plaintext)
    api_key_prefix TEXT NOT NULL,  -- First 8 chars for identification
    
    -- Owner
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Scope
    tenant_id UUID,
    allowed_resources TEXT[],  -- Which resources this key can access
    allowed_actions TEXT[],    -- Which actions are permitted
    
    -- Rate limiting
    rate_limit_requests INTEGER DEFAULT 1000,
    rate_limit_window INTEGER DEFAULT 3600,  -- seconds
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Timing
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    last_used_at TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    
    CONSTRAINT chk_api_keys_expires CHECK (expires_at IS NULL OR expires_at > created_at)
);

CREATE INDEX idx_api_keys_hash ON kernel.api_keys(api_key_hash);
CREATE INDEX idx_api_keys_participant ON kernel.api_keys(participant_id, is_active);

-- =============================================================================
-- RATE LIMITING
-- =============================================================================

CREATE TABLE kernel.rate_limit_buckets (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    bucket_key TEXT UNIQUE NOT NULL,  -- participant_id:resource or api_key:resource
    
    -- Limits
    max_requests INTEGER NOT NULL,
    window_seconds INTEGER NOT NULL,
    
    -- Current state
    current_count INTEGER DEFAULT 0,
    window_start TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Tracking
    last_request_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_rate_limit_buckets_key ON kernel.rate_limit_buckets(bucket_key);

-- =============================================================================
-- AUTH TOKENS (JWT-style)
-- =============================================================================

CREATE TABLE kernel.auth_tokens (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    token_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    token_jti TEXT UNIQUE NOT NULL,  -- JWT ID
    
    -- Subject
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Token data
    token_type VARCHAR(16) DEFAULT 'access',  -- access, refresh, id
    scopes TEXT[],
    
    -- Status
    is_revoked BOOLEAN DEFAULT FALSE,
    revoked_at TIMESTAMP WITH TIME ZONE,
    revoked_reason TEXT,
    
    -- Timing
    issued_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    
    -- Usage
    usage_count INTEGER DEFAULT 0,
    last_used_at TIMESTAMP WITH TIME ZONE,
    
    CONSTRAINT chk_auth_tokens_expires CHECK (expires_at > issued_at)
);

CREATE INDEX idx_auth_tokens_jti ON kernel.auth_tokens(token_jti);
CREATE INDEX idx_auth_tokens_participant ON kernel.auth_tokens(participant_id, is_revoked);

-- =============================================================================
-- MFA DEVICES
-- =============================================================================

CREATE TABLE kernel.mfa_devices (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    mfa_device_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Device info
    mfa_type VARCHAR(32) NOT NULL,  -- totp, sms, email, hardware_key, biometric
    device_name TEXT,
    
    -- TOTP specific
    totp_secret_encrypted TEXT,
    
    -- Hardware key specific
    credential_id TEXT,
    public_key TEXT,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_verified BOOLEAN DEFAULT FALSE,
    
    -- Usage
    verified_at TIMESTAMP WITH TIME ZONE,
    last_used_at TIMESTAMP WITH TIME ZONE,
    use_count INTEGER DEFAULT 0,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_mfa_devices_participant ON kernel.mfa_devices(participant_id, is_active);

-- =============================================================================
-- MFA CHALLENGES
-- =============================================================================

CREATE TABLE kernel.mfa_challenges (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    challenge_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    mfa_device_id UUID REFERENCES kernel.mfa_devices(mfa_device_id),
    
    -- Challenge
    challenge_type VARCHAR(32) NOT NULL,
    challenge_code_hash TEXT,  -- For SMS/email, hashed
    
    -- Status
    is_verified BOOLEAN DEFAULT FALSE,
    verified_at TIMESTAMP WITH TIME ZONE,
    
    -- Timing
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    
    -- Context
    client_ip INET,
    user_agent TEXT
);

CREATE INDEX idx_mfa_challenges_challenge ON kernel.mfa_challenges(challenge_id);
CREATE INDEX idx_mfa_challenges_expires ON kernel.mfa_challenges(expires_at) WHERE is_verified = FALSE;

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Check authorization
CREATE OR REPLACE FUNCTION kernel.check_authorization(
    p_subject_id UUID,
    p_action VARCHAR,
    p_resource_type VARCHAR,
    p_resource_id UUID DEFAULT NULL
)
RETURNS kernel.auth_decision AS $$
DECLARE
    v_decision kernel.auth_decision := 'deny';
    v_request_id UUID;
    v_start_time TIMESTAMP;
BEGIN
    v_start_time := clock_timestamp();
    
    -- Record request
    INSERT INTO kernel.authorization_requests (
        subject_id, action, resource_type, resource_id
    ) VALUES (
        p_subject_id, p_action, p_resource_type, p_resource_id
    )
    RETURNING request_id INTO v_request_id;
    
    -- Simple RBAC check (would be expanded with actual policy engine)
    IF EXISTS (
        SELECT 1 FROM kernel.agent_relationships
        WHERE to_agent = p_subject_id
          AND relationship_type = 'has_role'
          AND status = 'active'
          AND system_to IS NULL
    ) THEN
        v_decision := 'permit';
    END IF;
    
    -- Update request with decision
    UPDATE kernel.authorization_requests
    SET decision = v_decision,
        decided_at = NOW(),
        latency_ms = EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
    WHERE request_id = v_request_id;
    
    RETURN v_decision;
END;
$$ LANGUAGE plpgsql;

-- Create session
CREATE OR REPLACE FUNCTION kernel.create_session(
    p_participant_id UUID,
    p_auth_method VARCHAR,
    p_expires_hours INTEGER DEFAULT 24
)
RETURNS TEXT AS $$
DECLARE
    v_token TEXT;
    v_session_id UUID;
BEGIN
    v_token := encode(gen_random_bytes(32), 'base64');
    
    INSERT INTO kernel.sessions (
        session_token, participant_id, auth_method, expires_at
    ) VALUES (
        v_token, p_participant_id, p_auth_method,
        NOW() + (p_expires_hours || ' hours')::INTERVAL
    )
    RETURNING session_id INTO v_session_id;
    
    RETURN v_token;
END;
$$ LANGUAGE plpgsql;

-- Validate session
CREATE OR REPLACE FUNCTION kernel.validate_session(p_token TEXT)
RETURNS TABLE(
    is_valid BOOLEAN,
    participant_id UUID,
    session_id UUID
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        TRUE,
        s.participant_id,
        s.session_id
    FROM kernel.sessions s
    WHERE s.session_token = p_token
      AND s.is_active = TRUE
      AND s.expires_at > NOW();
    
    -- Update last activity
    UPDATE kernel.sessions
    SET last_activity_at = NOW()
    WHERE session_token = p_token;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::UUID;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Rate limit check
CREATE OR REPLACE FUNCTION kernel.check_rate_limit(
    p_bucket_key TEXT,
    p_max_requests INTEGER DEFAULT 100,
    p_window_seconds INTEGER DEFAULT 3600
)
RETURNS TABLE(
    allowed BOOLEAN,
    remaining INTEGER,
    reset_at TIMESTAMP WITH TIME ZONE
) AS $$
DECLARE
    v_bucket RECORD;
    v_allowed BOOLEAN;
    v_remaining INTEGER;
    v_reset TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT * INTO v_bucket FROM kernel.rate_limit_buckets WHERE bucket_key = p_bucket_key;
    
    IF v_bucket IS NULL THEN
        INSERT INTO kernel.rate_limit_buckets (bucket_key, max_requests, window_seconds, current_count)
        VALUES (p_bucket_key, p_max_requests, p_window_seconds, 1)
        ON CONFLICT (bucket_key) DO UPDATE SET current_count = rate_limit_buckets.current_count + 1
        RETURNING * INTO v_bucket;
    ELSIF v_bucket.window_start + (p_window_seconds || ' seconds')::INTERVAL < NOW() THEN
        -- Reset window
        UPDATE kernel.rate_limit_buckets
        SET window_start = NOW(), current_count = 1, last_request_at = NOW()
        WHERE bucket_key = p_bucket_key
        RETURNING * INTO v_bucket;
    ELSE
        -- Increment
        UPDATE kernel.rate_limit_buckets
        SET current_count = current_count + 1, last_request_at = NOW()
        WHERE bucket_key = p_bucket_key
        RETURNING * INTO v_bucket;
    END IF;
    
    v_allowed := v_bucket.current_count <= p_max_requests;
    v_remaining := GREATEST(0, p_max_requests - v_bucket.current_count);
    v_reset := v_bucket.window_start + (p_window_seconds || ' seconds')::INTERVAL;
    
    RETURN QUERY SELECT v_allowed, v_remaining, v_reset;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 9: Real-time Authorization initialized' AS status;
