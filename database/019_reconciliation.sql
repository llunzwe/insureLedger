-- =============================================================================
-- FILE: 019_reconciliation.sql
-- PURPOSE: Primitive 14 - Reconciliation & Matching
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: SWIFT MT950, ISO 20022 camt.053, Nostro/Vostro reconciliation
-- DEPENDENCIES: 007_value_containers.sql, 008_value_movements.sql
-- =============================================================================

-- =============================================================================
-- RECONCILIATION RUNS
-- =============================================================================

CREATE TYPE kernel.recon_status AS ENUM (
    'pending',
    'in_progress',
    'completed',
    'failed',
    'approved'
);

CREATE TYPE kernel.recon_type AS ENUM (
    'bank_statement',
    'internal_ledger',
    'nostro_vostro',
    'inter_system',
    'custodian',
    'card_network'
);

CREATE TABLE kernel.reconciliation_runs (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    recon_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    recon_reference TEXT UNIQUE NOT NULL,
    
    -- Type
    recon_type kernel.recon_type NOT NULL,
    
    -- Scope
    container_id UUID REFERENCES kernel.value_containers(container_id),
    external_system VARCHAR(64),
    
    -- Period
    recon_date DATE NOT NULL,
    period_start TIMESTAMP WITH TIME ZONE NOT NULL,
    period_end TIMESTAMP WITH TIME ZONE NOT NULL,
    
    -- Status
    status kernel.recon_status DEFAULT 'pending',
    
    -- Totals
    internal_item_count INTEGER DEFAULT 0,
    external_item_count INTEGER DEFAULT 0,
    matched_count INTEGER DEFAULT 0,
    unmatched_internal_count INTEGER DEFAULT 0,
    unmatched_external_count INTEGER DEFAULT 0,
    disputed_count INTEGER DEFAULT 0,
    
    internal_total DECIMAL(24, 6) DEFAULT 0,
    external_total DECIMAL(24, 6) DEFAULT 0,
    difference DECIMAL(24, 6) GENERATED ALWAYS AS (external_total - internal_total) STORED,
    
    -- Timing
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    approved_at TIMESTAMP WITH TIME ZONE,
    approved_by UUID,
    
    -- Configuration
    match_tolerance DECIMAL(24, 6) DEFAULT 0.01,
    auto_match_rules JSONB DEFAULT '{}',
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_recon_runs_recon ON kernel.reconciliation_runs(recon_id);
CREATE INDEX idx_recon_runs_container ON kernel.reconciliation_runs(container_id, recon_date DESC);
CREATE INDEX idx_recon_runs_status ON kernel.reconciliation_runs(status);

-- =============================================================================
-- RECONCILIATION ITEMS - Internal transactions
-- =============================================================================

CREATE TABLE kernel.recon_internal_items (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    recon_id UUID NOT NULL REFERENCES kernel.reconciliation_runs(recon_id),
    
    -- Source
    movement_id UUID REFERENCES kernel.value_movements(movement_id),
    posting_id UUID REFERENCES kernel.movement_postings(posting_id),
    
    -- Transaction details
    transaction_date TIMESTAMP WITH TIME ZONE NOT NULL,
    transaction_reference TEXT,
    description TEXT,
    
    -- Amount
    amount DECIMAL(24, 6) NOT NULL,
    currency_code VARCHAR(3) NOT NULL,
    direction VARCHAR(6) NOT NULL,  -- debit, credit
    
    -- Status
    status VARCHAR(32) DEFAULT 'unmatched',  -- unmatched, matched, disputed, written_off
    
    -- Matching
    matched_to_external_item_id UUID,
    matched_at TIMESTAMP WITH TIME ZONE,
    match_confidence DECIMAL(5, 2),  -- 0-100
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_recon_internal_items_recon ON kernel.recon_internal_items(recon_id);
CREATE INDEX idx_recon_internal_items_status ON kernel.recon_internal_items(status);
CREATE INDEX idx_recon_internal_items_movement ON kernel.recon_internal_items(movement_id);

-- =============================================================================
-- RECONCILIATION ITEMS - External transactions
-- =============================================================================

CREATE TABLE kernel.recon_external_items (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    recon_id UUID NOT NULL REFERENCES kernel.reconciliation_runs(recon_id),
    
    -- External reference
    external_transaction_id TEXT NOT NULL,
    external_reference TEXT,
    
    -- Transaction details
    transaction_date TIMESTAMP WITH TIME ZONE NOT NULL,
    value_date DATE,
    description TEXT,
    
    -- Amount
    amount DECIMAL(24, 6) NOT NULL,
    currency_code VARCHAR(3) NOT NULL,
    direction VARCHAR(6) NOT NULL,  -- debit, credit
    
    -- Raw data
    raw_data JSONB,
    
    -- Status
    status VARCHAR(32) DEFAULT 'unmatched',
    
    -- Matching
    matched_to_internal_item_id UUID,
    matched_at TIMESTAMP WITH TIME ZONE,
    match_confidence DECIMAL(5, 2),
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_recon_external_items_recon ON kernel.recon_external_items(recon_id);
CREATE INDEX idx_recon_external_items_status ON kernel.recon_external_items(status);

-- =============================================================================
-- MATCHING RULES
-- =============================================================================

CREATE TABLE kernel.recon_matching_rules (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    rule_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    rule_name TEXT NOT NULL,
    
    -- Priority (lower = evaluated first)
    priority INTEGER DEFAULT 100,
    
    -- Conditions
    match_fields JSONB NOT NULL,  -- ["reference", "amount", "date"]
    tolerance_amount DECIMAL(24, 6) DEFAULT 0,
    tolerance_days INTEGER DEFAULT 0,
    
    -- Scoring
    field_weights JSONB DEFAULT '{"reference": 0.4, "amount": 0.4, "date": 0.2}',
    
    -- Threshold
    match_threshold DECIMAL(5, 2) DEFAULT 80.00,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- BREAK ITEMS - Discrepancies
-- =============================================================================

CREATE TABLE kernel.recon_breaks (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    break_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    recon_id UUID NOT NULL REFERENCES kernel.reconciliation_runs(recon_id),
    
    -- Items involved
    internal_item_id UUID REFERENCES kernel.recon_internal_items(id),
    external_item_id UUID REFERENCES kernel.recon_external_items(id),
    
    -- Break details
    break_type VARCHAR(32) NOT NULL,  -- timing, amount, missing_internal, missing_external, duplicate
    break_reason TEXT NOT NULL,
    
    -- Amounts
    internal_amount DECIMAL(24, 6),
    external_amount DECIMAL(24, 6),
    difference DECIMAL(24, 6),
    
    -- Status
    status VARCHAR(32) DEFAULT 'open',  -- open, investigating, resolved, written_off
    
    -- Resolution
    resolution_action VARCHAR(32),  -- adjust, reverse, write_off, pending
    resolution_notes TEXT,
    resolved_by UUID,
    resolved_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_recon_breaks_recon ON kernel.recon_breaks(recon_id);
CREATE INDEX idx_recon_breaks_status ON kernel.recon_breaks(status);

-- =============================================================================
-- NOSTRO/VOSTRO ACCOUNTS
-- =============================================================================

CREATE TABLE kernel.nostro_accounts (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    nostro_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Owner
    owner_participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Correspondent bank
    correspondent_bank_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Account details
    account_number TEXT NOT NULL,
    account_currency VARCHAR(3) NOT NULL,
    
    -- Balance tracking
    ledger_balance DECIMAL(24, 6) DEFAULT 0,  -- Our books
    statement_balance DECIMAL(24, 6) DEFAULT 0,  -- Bank statement
    
    -- Reconciliation settings
    auto_reconcile BOOLEAN DEFAULT FALSE,
    last_recon_date DATE,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(owner_participant_id, correspondent_bank_id, account_currency)
);

CREATE INDEX idx_nostro_accounts_owner ON kernel.nostro_accounts(owner_participant_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create reconciliation run
CREATE OR REPLACE FUNCTION kernel.create_reconciliation_run(
    p_recon_type kernel.recon_type,
    p_container_id UUID,
    p_recon_date DATE,
    p_period_start TIMESTAMP WITH TIME ZONE,
    p_period_end TIMESTAMP WITH TIME ZONE
)
RETURNS UUID AS $$
DECLARE
    v_recon_id UUID;
    v_reference TEXT;
BEGIN
    v_reference := 'REC-' || p_recon_type || '-' || to_char(p_recon_date, 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 6);
    
    INSERT INTO kernel.reconciliation_runs (
        recon_reference, recon_type, container_id, recon_date,
        period_start, period_end, created_by
    ) VALUES (
        v_reference, p_recon_type, p_container_id, p_recon_date,
        p_period_start, p_period_end, security.get_participant_context()
    )
    RETURNING recon_id INTO v_recon_id;
    
    RETURN v_recon_id;
END;
$$ LANGUAGE plpgsql;

-- Add internal items to reconciliation
CREATE OR REPLACE FUNCTION kernel.add_internal_items_to_recon(
    p_recon_id UUID,
    p_container_id UUID,
    p_period_start TIMESTAMP WITH TIME ZONE,
    p_period_end TIMESTAMP WITH TIME ZONE
)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    INSERT INTO kernel.recon_internal_items (
        recon_id, movement_id, transaction_date, transaction_reference,
        description, amount, currency_code, direction
    )
    SELECT 
        p_recon_id,
        m.movement_id,
        m.entry_date,
        m.uetr::TEXT,
        m.narrative,
        CASE WHEN ml.direction = 'debit' THEN ml.amount ELSE -ml.amount END,
        m.currency_code,
        ml.direction
    FROM kernel.value_movements m
    JOIN kernel.movement_legs ml ON m.movement_id = ml.movement_id
    WHERE ml.container_id = p_container_id
      AND m.entry_date BETWEEN p_period_start AND p_period_end
    ON CONFLICT DO NOTHING;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    UPDATE kernel.reconciliation_runs
    SET internal_item_count = internal_item_count + v_count
    WHERE recon_id = p_recon_id;
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Auto-match items
CREATE OR REPLACE FUNCTION kernel.auto_match_recon_items(p_recon_id UUID)
RETURNS TABLE(matched INTEGER, unmatched INTEGER) AS $$
DECLARE
    v_matched INTEGER := 0;
    v_unmatched INTEGER;
    v_internal RECORD;
    v_external RECORD;
    v_score DECIMAL(5, 2);
BEGIN
    FOR v_internal IN 
        SELECT * FROM kernel.recon_internal_items 
        WHERE recon_id = p_recon_id AND status = 'unmatched'
    LOOP
        -- Find best matching external item
        SELECT * INTO v_external
        FROM kernel.recon_external_items
        WHERE recon_id = p_recon_id
          AND status = 'unmatched'
          AND ABS(amount - v_internal.amount) <= 0.01
          AND direction != v_internal.direction
          AND transaction_date BETWEEN v_internal.transaction_date - INTERVAL '3 days'
                                   AND v_internal.transaction_date + INTERVAL '3 days'
        ORDER BY ABS(EXTRACT(EPOCH FROM (transaction_date - v_internal.transaction_date)))
        LIMIT 1;
        
        IF FOUND THEN
            -- Calculate match score
            v_score := 90.0;  -- Simplified - would use actual algorithm
            
            IF v_internal.transaction_reference = v_external.external_reference THEN
                v_score := v_score + 10;
            END IF;
            
            -- Mark as matched
            UPDATE kernel.recon_internal_items
            SET status = 'matched', matched_to_external_item_id = v_external.id,
                matched_at = NOW(), match_confidence = LEAST(v_score, 100)
            WHERE id = v_internal.id;
            
            UPDATE kernel.recon_external_items
            SET status = 'matched', matched_to_internal_item_id = v_internal.id,
                matched_at = NOW(), match_confidence = LEAST(v_score, 100)
            WHERE id = v_external.id;
            
            v_matched := v_matched + 1;
        END IF;
    END LOOP;
    
    -- Count unmatched
    SELECT COUNT(*) INTO v_unmatched
    FROM kernel.recon_internal_items
    WHERE recon_id = p_recon_id AND status = 'unmatched';
    
    -- Update recon totals
    UPDATE kernel.reconciliation_runs
    SET matched_count = matched_count + v_matched,
        unmatched_internal_count = (SELECT COUNT(*) FROM kernel.recon_internal_items WHERE recon_id = p_recon_id AND status = 'unmatched'),
        unmatched_external_count = (SELECT COUNT(*) FROM kernel.recon_external_items WHERE recon_id = p_recon_id AND status = 'unmatched')
    WHERE recon_id = p_recon_id;
    
    RETURN QUERY SELECT v_matched, v_unmatched;
END;
$$ LANGUAGE plpgsql;

-- Create break item
CREATE OR REPLACE FUNCTION kernel.create_recon_break(
    p_recon_id UUID,
    p_internal_item_id UUID,
    p_external_item_id UUID,
    p_break_type VARCHAR,
    p_break_reason TEXT
)
RETURNS UUID AS $$
DECLARE
    v_break_id UUID;
    v_internal_amount DECIMAL(24, 6);
    v_external_amount DECIMAL(24, 6);
BEGIN
    SELECT amount INTO v_internal_amount FROM kernel.recon_internal_items WHERE id = p_internal_item_id;
    SELECT amount INTO v_external_amount FROM kernel.recon_external_items WHERE id = p_external_item_id;
    
    INSERT INTO kernel.recon_breaks (
        recon_id, internal_item_id, external_item_id,
        break_type, break_reason, internal_amount, external_amount,
        difference
    ) VALUES (
        p_recon_id, p_internal_item_id, p_external_item_id,
        p_break_type, p_break_reason, v_internal_amount, v_external_amount,
        COALESCE(v_external_amount, 0) - COALESCE(v_internal_amount, 0)
    )
    RETURNING break_id INTO v_break_id;
    
    -- Mark items as disputed
    UPDATE kernel.recon_internal_items SET status = 'disputed' WHERE id = p_internal_item_id;
    UPDATE kernel.recon_external_items SET status = 'disputed' WHERE id = p_external_item_id;
    
    UPDATE kernel.reconciliation_runs
    SET disputed_count = disputed_count + 1
    WHERE recon_id = p_recon_id;
    
    RETURN v_break_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Insert default matching rules
INSERT INTO kernel.recon_matching_rules (rule_name, priority, match_fields, tolerance_amount, tolerance_days, match_threshold) VALUES
    ('Exact Match', 1, '["reference", "amount", "date"]', 0, 0, 100.00),
    ('Amount and Date', 10, '["amount", "date"]', 0.01, 1, 90.00),
    ('Reference Only', 20, '["reference"]', 0, 3, 70.00)
ON CONFLICT DO NOTHING;

SELECT 'Primitive 14: Reconciliation & Matching initialized' AS status;
