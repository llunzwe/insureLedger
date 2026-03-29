-- =============================================================================
-- FILE: 007_value_containers.sql
-- PURPOSE: Primitive 4 - Value Container (universal accounts)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 4217, SOC 2
-- DEPENDENCIES: 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- VALUE CONTAINERS - Universal accounts
-- =============================================================================

CREATE TYPE kernel.account_class AS ENUM (
    'asset',
    'liability',
    'equity',
    'income',
    'expense'
);

CREATE TABLE kernel.value_containers (
    -- Identity & Immutability
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    -- Container Identity
    container_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,  -- NULL for system/global accounts
    
    -- Account Classification (Double-Entry)
    account_class kernel.account_class NOT NULL,
    account_type VARCHAR(32) NOT NULL,  -- wallet, escrow, settlement, premium, etc.
    
    -- Ownership
    owner_participant_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Currency & Balance
    currency_code CHAR(3) NOT NULL DEFAULT 'USD',
    balance DECIMAL(24, 6) NOT NULL DEFAULT 0,
    held_balance DECIMAL(24, 6) NOT NULL DEFAULT 0,  -- Ring-fenced/pending
    available_balance DECIMAL(24, 6) GENERATED ALWAYS AS (balance - held_balance) STORED,
    
    -- State
    state VARCHAR(16) DEFAULT 'active' CHECK (state IN ('active', 'frozen', 'closed', 'suspended')),
    state_reason TEXT,
    
    -- Hierarchy (for sub-ledger segregation)
    parent_container_id UUID REFERENCES kernel.value_containers(container_id),
    path LTREE,
    is_virtual BOOLEAN DEFAULT FALSE,
    master_container_id UUID REFERENCES kernel.value_containers(container_id),
    
    -- Limits & Constraints
    daily_debit_limit DECIMAL(24, 6),
    daily_credit_limit DECIMAL(24, 6),
    single_transaction_limit DECIMAL(24, 6),
    minimum_balance DECIMAL(24, 6) DEFAULT 0,
    maximum_balance DECIMAL(24, 6),
    
    -- Multi-currency support
    functional_currency_code CHAR(3) DEFAULT 'USD',
    
    -- Metadata
    account_name TEXT NOT NULL,
    account_description TEXT,
    account_reference TEXT,  -- External reference (e.g., bank account number)
    metadata JSONB,
    
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
    CONSTRAINT chk_value_containers_temporal_system 
        CHECK (system_from <= system_to OR system_to IS NULL),
    CONSTRAINT chk_value_containers_temporal_valid 
        CHECK (valid_from <= valid_to OR valid_to IS NULL),
    CONSTRAINT chk_value_containers_balance_available 
        CHECK (available_balance >= minimum_balance),
    CONSTRAINT chk_value_containers_currency 
        CHECK (currency_code IN (SELECT currency_code FROM kernel.currencies WHERE is_active = TRUE))
);

COMMENT ON TABLE kernel.value_containers IS 'Universal accounts for storing value with double-entry semantics';

CREATE INDEX idx_value_containers_container ON kernel.value_containers(container_id);
CREATE INDEX idx_value_containers_tenant ON kernel.value_containers(tenant_id) WHERE tenant_id IS NOT NULL;
CREATE INDEX idx_value_containers_owner ON kernel.value_containers(owner_participant_id);
CREATE INDEX idx_value_containers_class ON kernel.value_containers(account_class, account_type);
CREATE INDEX idx_value_containers_state ON kernel.value_containers(state);
CREATE INDEX idx_value_containers_path ON kernel.value_containers USING GIST(path);
CREATE INDEX idx_value_containers_master ON kernel.value_containers(master_container_id) WHERE master_container_id IS NOT NULL;

-- =============================================================================
-- CONTAINER CONSTRAINTS - Per-container limits
-- =============================================================================

CREATE TABLE kernel.container_constraints (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    container_id UUID NOT NULL REFERENCES kernel.value_containers(container_id),
    
    constraint_type VARCHAR(32) NOT NULL,  -- daily_limit, monthly_limit, counterparty_limit
    constraint_subtype VARCHAR(32),  -- debit, credit, both
    
    limit_amount DECIMAL(24, 6),
    limit_count INTEGER,
    
    window_type VARCHAR(16) NOT NULL CHECK (window_type IN ('transaction', 'minute', 'hour', 'day', 'week', 'month')),
    window_value INTEGER DEFAULT 1,
    
    allowed_counterparties UUID[],
    blocked_counterparties UUID[],
    allowed_schemes TEXT[],
    blocked_schemes TEXT[],
    
    is_active BOOLEAN DEFAULT TRUE,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_container_constraints_temporal 
        CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_container_constraints_container ON kernel.container_constraints(container_id);

-- =============================================================================
-- VELOCITY LIMITS - Sliding window counters
-- =============================================================================

CREATE TABLE kernel.velocity_limits (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    tracking_key TEXT NOT NULL,
    container_id UUID REFERENCES kernel.value_containers(container_id),
    instrument_id UUID,
    
    window_type VARCHAR(16) NOT NULL,  -- per_transaction, per_minute, per_hour, per_day
    window_start TIMESTAMP WITH TIME ZONE NOT NULL,
    window_end TIMESTAMP WITH TIME ZONE NOT NULL,
    
    current_amount DECIMAL(24, 6) DEFAULT 0,
    current_count INTEGER DEFAULT 0,
    
    limit_amount DECIMAL(24, 6),
    limit_count INTEGER,
    
    is_exceeded BOOLEAN DEFAULT FALSE,
    exceeded_at TIMESTAMP WITH TIME ZONE,
    
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE (tracking_key, window_start)
);

CREATE INDEX idx_velocity_limits_tracking ON kernel.velocity_limits(tracking_key, window_end);
CREATE INDEX idx_velocity_limits_container ON kernel.velocity_limits(container_id, window_type);

-- =============================================================================
-- CONTAINER BALANCES HISTORY
-- =============================================================================

CREATE TABLE kernel.container_balances_history (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    container_id UUID NOT NULL,
    snapshot_time TIMESTAMP WITH TIME ZONE NOT NULL,
    
    balance DECIMAL(24, 6) NOT NULL,
    held_balance DECIMAL(24, 6) NOT NULL,
    available_balance DECIMAL(24, 6) NOT NULL,
    
    day_debit_total DECIMAL(24, 6) DEFAULT 0,
    day_credit_total DECIMAL(24, 6) DEFAULT 0,
    day_transaction_count INTEGER DEFAULT 0,
    
    functional_currency_code CHAR(3),
    balance_in_functional DECIMAL(24, 6),
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_container_balances_container_time ON kernel.container_balances_history(container_id, snapshot_time DESC);

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

ALTER TABLE kernel.value_containers ENABLE ROW LEVEL SECURITY;

CREATE POLICY value_containers_tenant_isolation ON kernel.value_containers
    USING (tenant_id = security.get_tenant_context() OR tenant_id IS NULL);

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 4: Value Containers initialized' AS status;
