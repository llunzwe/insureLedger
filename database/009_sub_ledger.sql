-- =============================================================================
-- FILE: 009_sub_ledger.sql
-- PURPOSE: Primitive 19 - Sub-Ledger & Segregation (CASS compliance)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: FCA CASS, ISO 4217, SOC 2
-- DEPENDENCIES: 007_value_containers.sql, 008_value_movements.sql
-- =============================================================================

-- =============================================================================
-- MASTER ACCOUNTS - Omnibus/Escrow accounts for client money
-- =============================================================================

CREATE TYPE kernel.segregation_type AS ENUM (
    'client_money',
    'trust',
    'escrow',
    'segregated',
    'pooled'
);

CREATE TYPE kernel.regulatory_framework AS ENUM (
    'CASS',           -- UK Client Assets Sourcebook
    'SEC_15c3_3',     -- US SEC Rule 15c3-3
    'EMD',            -- European Market Infrastructure
    'MIFID_II',       -- MiFID II
    'LOCAL_REG',      -- Local regulations
    'NONE'
);

CREATE TABLE kernel.master_accounts (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    master_account_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Link to value container (the actual ledger account)
    container_id UUID NOT NULL REFERENCES kernel.value_containers(container_id),
    
    -- Account Type
    account_type VARCHAR(32) NOT NULL,  -- fbo_master, omnibus, escrow_master, trust_master
    segregation_type kernel.segregation_type NOT NULL,
    regulatory_framework kernel.regulatory_framework DEFAULT 'NONE',
    
    -- Regulatory info
    regulatory_reference TEXT,  -- CASS account reference
    custodian_participant_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Balances (must reconcile)
    master_physical_balance DECIMAL(24, 6) NOT NULL DEFAULT 0,  -- Actual bank balance
    total_subledger_balance DECIMAL(24, 6) NOT NULL DEFAULT 0,  -- Sum of sub-accounts
    reconciliation_gap DECIMAL(24, 6) GENERATED ALWAYS AS (master_physical_balance - total_subledger_balance) STORED,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    status VARCHAR(16) DEFAULT 'open',  -- open, frozen, closed
    
    -- Reconciliation
    last_reconciled_at TIMESTAMP WITH TIME ZONE,
    last_reconciled_by UUID,
    reconciliation_tolerance DECIMAL(24, 6) DEFAULT 0.01,
    
    -- Bitemporal
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    CONSTRAINT chk_master_accounts_temporal 
        CHECK (system_from <= system_to OR system_to IS NULL),
    CONSTRAINT chk_master_accounts_gap 
        CHECK (ABS(reconciliation_gap) <= reconciliation_tolerance)
);

COMMENT ON TABLE kernel.master_accounts IS 'Omnibus and escrow master accounts for client money segregation per CASS';

CREATE INDEX idx_master_accounts_master ON kernel.master_accounts(master_account_id);
CREATE INDEX idx_master_accounts_container ON kernel.master_accounts(container_id);
CREATE INDEX idx_master_accounts_regulatory ON kernel.master_accounts(regulatory_framework, segregation_type);

-- =============================================================================
-- SUB ACCOUNTS - Client-level accounts
-- =============================================================================

CREATE TABLE kernel.sub_accounts (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    sub_account_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Hierarchy
    master_account_id UUID NOT NULL REFERENCES kernel.master_accounts(master_account_id),
    container_id UUID REFERENCES kernel.value_containers(container_id),
    
    -- Owner
    owner_participant_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Account Details
    sub_account_code TEXT NOT NULL,
    virtual_iban TEXT,
    virtual_account_number TEXT,
    
    -- Balances
    balance DECIMAL(24, 6) NOT NULL DEFAULT 0,
    blocked_balance DECIMAL(24, 6) DEFAULT 0,  -- Court orders, etc.
    available_balance DECIMAL(24, 6) GENERATED ALWAYS AS (balance - blocked_balance) STORED,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    status VARCHAR(16) DEFAULT 'active',  -- active, suspended, closed
    status_reason TEXT,
    
    -- Opening/Closing
    opened_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    opened_by UUID,
    closed_at TIMESTAMP WITH TIME ZONE,
    closed_by UUID,
    closure_reason TEXT,
    
    -- Bitemporal
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    CONSTRAINT chk_sub_accounts_temporal 
        CHECK (system_from <= system_to OR system_to IS NULL),
    UNIQUE (master_account_id, sub_account_code)
);

COMMENT ON TABLE kernel.sub_accounts IS 'Client-level sub-accounts within master accounts';

CREATE INDEX idx_sub_accounts_sub ON kernel.sub_accounts(sub_account_id);
CREATE INDEX idx_sub_accounts_master ON kernel.sub_accounts(master_account_id);
CREATE INDEX idx_sub_accounts_owner ON kernel.sub_accounts(owner_participant_id);

-- =============================================================================
-- SUB-LEDGER BALANCES HISTORY
-- =============================================================================

CREATE TABLE kernel.sub_ledger_balances (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    master_account_id UUID NOT NULL REFERENCES kernel.master_accounts(master_account_id),
    snapshot_time TIMESTAMP WITH TIME ZONE NOT NULL,
    
    master_balance DECIMAL(24, 6) NOT NULL,
    sub_ledger_total DECIMAL(24, 6) NOT NULL,
    gap_amount DECIMAL(24, 6) NOT NULL,
    
    sub_account_count INTEGER,
    active_sub_account_count INTEGER,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_sub_ledger_balances_master ON kernel.sub_ledger_balances(master_account_id, snapshot_time DESC);

-- =============================================================================
-- SUB-LEDGER RECONCILIATIONS
-- =============================================================================

CREATE TABLE kernel.sub_ledger_reconciliations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    reconciliation_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    master_account_id UUID NOT NULL REFERENCES kernel.master_accounts(master_account_id),
    
    recon_date DATE NOT NULL,
    recon_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    opening_master_balance DECIMAL(24, 6),
    closing_master_balance DECIMAL(24, 6),
    opening_subledger_total DECIMAL(24, 6),
    closing_subledger_total DECIMAL(24, 6),
    
    total_credits DECIMAL(24, 6),
    total_debits DECIMAL(24, 6),
    transaction_count INTEGER,
    
    opening_gap DECIMAL(24, 6),
    closing_gap DECIMAL(24, 6),
    is_balanced BOOLEAN,
    
    prepared_by UUID,
    prepared_at TIMESTAMP WITH TIME ZONE,
    approved_by UUID,
    approved_at TIMESTAMP WITH TIME ZONE,
    
    status VARCHAR(16) DEFAULT 'prepared',
    
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_sub_ledger_recon_master ON kernel.sub_ledger_reconciliations(master_account_id, recon_date DESC);

-- =============================================================================
-- CLIENT MONEY CALCULATIONS (CASS-style compliance)
-- =============================================================================

CREATE TABLE kernel.client_money_calculations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    calculation_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    master_account_id UUID NOT NULL REFERENCES kernel.master_accounts(master_account_id),
    
    calculation_date DATE NOT NULL,
    calculation_type VARCHAR(32) NOT NULL,  -- daily, weekly, monthly, adhoc
    
    -- Client Money Resource (CMR)
    total_client_money DECIMAL(24, 6) NOT NULL,
    
    -- Client Money Requirement
    unresolved_client_funds DECIMAL(24, 6),
    pending_settlements DECIMAL(24, 6),
    margin_requirements DECIMAL(24, 6),
    total_requirement DECIMAL(24, 6),
    
    -- Comparison
    surplus_or_deficit DECIMAL(24, 6),
    is_compliant BOOLEAN,
    
    calculated_by UUID,
    calculated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    reviewed_by UUID,
    reviewed_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create master account
CREATE OR REPLACE FUNCTION kernel.create_master_account(
    p_container_id UUID,
    p_segregation_type kernel.segregation_type,
    p_regulatory_framework kernel.regulatory_framework,
    p_regulatory_reference TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_master_id UUID;
BEGIN
    INSERT INTO kernel.master_accounts (
        container_id, segregation_type, regulatory_framework, regulatory_reference,
        master_physical_balance, total_subledger_balance, created_by
    ) VALUES (
        p_container_id, p_segregation_type, p_regulatory_framework, p_regulatory_reference,
        0, 0, security.get_participant_context()
    )
    RETURNING master_account_id INTO v_master_id;
    
    RETURN v_master_id;
END;
$$ LANGUAGE plpgsql;

-- Create sub-account
CREATE OR REPLACE FUNCTION kernel.create_sub_account(
    p_master_account_id UUID,
    p_owner_participant_id UUID,
    p_sub_account_code TEXT
)
RETURNS UUID AS $$
DECLARE
    v_sub_id UUID;
BEGIN
    INSERT INTO kernel.sub_accounts (
        master_account_id, owner_participant_id, sub_account_code, opened_by
    ) VALUES (
        p_master_account_id, p_owner_participant_id, p_sub_account_code,
        security.get_participant_context()
    )
    RETURNING sub_account_id INTO v_sub_id;
    
    RETURN v_sub_id;
END;
$$ LANGUAGE plpgsql;

-- Update sub-ledger totals trigger
CREATE OR REPLACE FUNCTION kernel.update_sub_ledger_totals()
RETURNS TRIGGER AS $$
DECLARE
    v_master_id UUID;
    v_total DECIMAL(24, 6);
BEGIN
    SELECT master_account_id INTO v_master_id
    FROM kernel.sub_accounts
    WHERE sub_account_id = NEW.sub_account_id;
    
    SELECT COALESCE(SUM(balance), 0) INTO v_total
    FROM kernel.sub_accounts
    WHERE master_account_id = v_master_id
      AND is_active = TRUE
      AND system_to IS NULL;
    
    UPDATE kernel.master_accounts
    SET total_subledger_balance = v_total, last_modified_at = NOW()
    WHERE master_account_id = v_master_id;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sub_account_balance_update
    AFTER UPDATE OF balance ON kernel.sub_accounts
    FOR EACH ROW EXECUTE FUNCTION kernel.update_sub_ledger_totals();

-- Reconcile sub-ledger
CREATE OR REPLACE FUNCTION kernel.reconcile_sub_ledger(
    p_master_account_id UUID,
    p_recon_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE(is_balanced BOOLEAN, gap DECIMAL(24, 6)) AS $$
DECLARE
    v_master RECORD;
    v_sub_total DECIMAL(24, 6);
    v_is_balanced BOOLEAN;
    v_gap DECIMAL(24, 6);
BEGIN
    SELECT * INTO v_master FROM kernel.master_accounts WHERE master_account_id = p_master_account_id;
    
    SELECT COALESCE(SUM(balance), 0) INTO v_sub_total
    FROM kernel.sub_accounts
    WHERE master_account_id = p_master_account_id AND is_active = TRUE AND system_to IS NULL;
    
    v_gap := v_master.master_physical_balance - v_sub_total;
    v_is_balanced := ABS(v_gap) <= v_master.reconciliation_tolerance;
    
    INSERT INTO kernel.sub_ledger_reconciliations (
        master_account_id, recon_date, closing_master_balance, closing_subledger_total,
        closing_gap, is_balanced, prepared_by
    ) VALUES (
        p_master_account_id, p_recon_date, v_master.master_physical_balance, v_sub_total,
        v_gap, v_is_balanced, security.get_participant_context()
    );
    
    UPDATE kernel.master_accounts
    SET total_subledger_balance = v_sub_total, last_reconciled_at = NOW(),
        last_reconciled_by = security.get_participant_context()
    WHERE master_account_id = p_master_account_id;
    
    RETURN QUERY SELECT v_is_balanced, v_gap;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 19: Sub-Ledger & Segregation initialized' AS status;
