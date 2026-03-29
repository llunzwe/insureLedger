-- =============================================================================
-- FILE: 008_value_movements.sql
-- PURPOSE: Primitive 5 - Value Movement & Double-Entry
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 20022, Double-Entry Accounting Principles
-- DEPENDENCIES: 007_value_containers.sql
-- =============================================================================

-- =============================================================================
-- MOVEMENT TYPES
-- =============================================================================

CREATE TYPE kernel.movement_type AS ENUM (
    'transfer',
    'exchange',
    'settlement',
    'reversal',
    'chargeback',
    'adjustment',
    'fee',
    'interest',
    'premium_payment',
    'claim_payout',
    'repair_payment',
    'refund',
    'escrow_release',
    'commission'
);

CREATE TYPE kernel.movement_status AS ENUM (
    'draft',
    'pending',
    'posted',
    'reversed',
    'cancelled'
);

-- =============================================================================
-- VALUE MOVEMENTS - Double-entry headers
-- =============================================================================

CREATE TABLE kernel.value_movements (
    -- Identity & Immutability
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    -- Movement Identity
    movement_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    movement_sequence BIGSERIAL,
    tenant_id UUID,
    
    -- Classification
    movement_type kernel.movement_type NOT NULL,
    movement_subtype VARCHAR(32),
    
    -- Reference & Status
    reference TEXT,
    external_reference TEXT,
    status kernel.movement_status DEFAULT 'draft',
    
    -- Dates
    entry_date DATE NOT NULL DEFAULT CURRENT_DATE,
    value_date DATE NOT NULL DEFAULT CURRENT_DATE,
    posting_timestamp TIMESTAMP WITH TIME ZONE,
    
    -- Totals (Double-entry conservation)
    total_debits DECIMAL(24, 6) NOT NULL DEFAULT 0,
    total_credits DECIMAL(24, 6) NOT NULL DEFAULT 0,
    
    -- Currency
    entry_currency CHAR(3) NOT NULL DEFAULT 'USD',
    functional_currency CHAR(3) DEFAULT 'USD',
    exchange_rate DECIMAL(18, 8) DEFAULT 1.0,
    
    -- Grouping
    batch_id UUID,
    transaction_id UUID,
    correlation_id UUID,
    idempotency_key TEXT,
    
    -- ISO 20022 Fields
    end_to_end_id VARCHAR(35),  -- ISO 20022 end-to-end identification
    uetr UUID,  -- ISO 20022 Universal End-to-End Transaction Reference
    instruction_id VARCHAR(35),
    
    -- Context
    initiated_by UUID REFERENCES kernel.participants(participant_id),
    session_id UUID,
    ip_address_hash TEXT,
    user_agent_hash TEXT,
    
    -- Reversal tracking
    is_reversal BOOLEAN DEFAULT FALSE,
    reversed_movement_id UUID REFERENCES kernel.value_movements(movement_id),
    reversal_reason TEXT,
    
    -- Bitemporal
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Verification
    signature TEXT,
    proof_inclusion UUID,
    
    -- Constraints
    CONSTRAINT chk_value_movements_conservation 
        CHECK (status != 'posted' OR total_debits = total_credits),
    CONSTRAINT chk_value_movements_positive 
        CHECK (total_debits >= 0 AND total_credits >= 0),
    CONSTRAINT chk_value_movements_temporal 
        CHECK (system_from <= system_to OR system_to IS NULL)
);

COMMENT ON TABLE kernel.value_movements IS 'Double-entry movement headers with conservation of value enforcement';

CREATE INDEX idx_value_movements_movement ON kernel.value_movements(movement_id);
CREATE INDEX idx_value_movements_sequence ON kernel.value_movements(movement_sequence);
CREATE INDEX idx_value_movements_status ON kernel.value_movements(status);
CREATE INDEX idx_value_movements_type ON kernel.value_movements(movement_type);
CREATE INDEX idx_value_movements_dates ON kernel.value_movements(entry_date, value_date);
CREATE INDEX idx_value_movements_uetr ON kernel.value_movements(uetr) WHERE uetr IS NOT NULL;
CREATE INDEX idx_value_movements_idempotency ON kernel.value_movements(idempotency_key) WHERE idempotency_key IS NOT NULL;

-- =============================================================================
-- MOVEMENT LEGS - Debit/Credit entries
-- =============================================================================

CREATE TABLE kernel.movement_legs (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    leg_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    movement_id UUID NOT NULL REFERENCES kernel.value_movements(movement_id),
    leg_sequence INTEGER NOT NULL,
    
    container_id UUID NOT NULL REFERENCES kernel.value_containers(container_id),
    
    direction VARCHAR(6) NOT NULL CHECK (direction IN ('debit', 'credit')),
    amount DECIMAL(24, 6) NOT NULL CHECK (amount > 0),
    amount_in_functional DECIMAL(24, 6),
    
    account_code VARCHAR(32),
    account_subcode VARCHAR(32),
    
    leg_description TEXT,
    leg_hash TEXT NOT NULL,
    
    related_leg_id UUID REFERENCES kernel.movement_legs(leg_id),
    
    metadata JSONB,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE (movement_id, leg_sequence)
);

COMMENT ON TABLE kernel.movement_legs IS 'Individual debit/credit legs of double-entry movements';

CREATE INDEX idx_movement_legs_movement ON kernel.movement_legs(movement_id);
CREATE INDEX idx_movement_legs_container ON kernel.movement_legs(container_id);

-- =============================================================================
-- MOVEMENT POSTINGS - Historical balance records
-- =============================================================================

CREATE TABLE kernel.movement_postings (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    container_id UUID NOT NULL,
    movement_id UUID NOT NULL REFERENCES kernel.value_movements(movement_id),
    leg_id UUID NOT NULL REFERENCES kernel.movement_legs(leg_id),
    
    posting_time TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    
    direction VARCHAR(6) NOT NULL,
    amount DECIMAL(24, 6) NOT NULL,
    
    running_balance DECIMAL(24, 6) NOT NULL,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_movement_postings_container_time ON kernel.movement_postings(container_id, posting_time DESC);
CREATE INDEX idx_movement_postings_movement ON kernel.movement_postings(movement_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Calculate leg hash
CREATE OR REPLACE FUNCTION crypto.calculate_leg_hash(
    p_movement_id UUID,
    p_container_id UUID,
    p_direction TEXT,
    p_amount DECIMAL
)
RETURNS TEXT AS $$
BEGIN
    RETURN crypto.sha256_hash(
        p_movement_id::TEXT || ':' || 
        p_container_id::TEXT || ':' || 
        p_direction || ':' || 
        p_amount::TEXT
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Post a movement (validate and execute)
CREATE OR REPLACE FUNCTION kernel.post_movement(p_movement_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_movement RECORD;
    v_leg RECORD;
    v_total_debits DECIMAL(24, 6) := 0;
    v_total_credits DECIMAL(24, 6) := 0;
    v_new_balance DECIMAL(24, 6);
BEGIN
    SELECT * INTO v_movement
    FROM kernel.value_movements
    WHERE movement_id = p_movement_id;
    
    IF v_movement IS NULL THEN
        RAISE EXCEPTION 'Movement not found: %', p_movement_id;
    END IF;
    
    IF v_movement.status = 'posted' THEN
        RAISE EXCEPTION 'Movement already posted: %', p_movement_id;
    END IF;
    
    SELECT 
        COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0),
        COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
    INTO v_total_debits, v_total_credits
    FROM kernel.movement_legs
    WHERE movement_id = p_movement_id;
    
    IF v_total_debits != v_total_credits THEN
        RAISE EXCEPTION 'Double-entry violation: debits (%) != credits (%)', 
            v_total_debits, v_total_credits;
    END IF;
    
    FOR v_leg IN 
        SELECT * FROM kernel.movement_legs 
        WHERE movement_id = p_movement_id
        ORDER BY leg_sequence
    LOOP
        IF v_leg.direction = 'debit' THEN
            UPDATE kernel.value_containers
            SET balance = balance - v_leg.amount
            WHERE container_id = v_leg.container_id
            RETURNING balance INTO v_new_balance;
        ELSE
            UPDATE kernel.value_containers
            SET balance = balance + v_leg.amount
            WHERE container_id = v_leg.container_id
            RETURNING balance INTO v_new_balance;
        END IF;
        
        INSERT INTO kernel.movement_postings (
            container_id, movement_id, leg_id, posting_time,
            direction, amount, running_balance
        ) VALUES (
            v_leg.container_id, p_movement_id, v_leg.leg_id, NOW(),
            v_leg.direction, v_leg.amount, v_new_balance
        );
    END LOOP;
    
    UPDATE kernel.value_movements
    SET status = 'posted',
        posting_timestamp = NOW(),
        total_debits = v_total_debits,
        total_credits = v_total_credits
    WHERE movement_id = p_movement_id;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Create transfer
CREATE OR REPLACE FUNCTION kernel.create_transfer(
    p_from_container_id UUID,
    p_to_container_id UUID,
    p_amount DECIMAL,
    p_currency CHAR(3) DEFAULT 'USD',
    p_reference TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_movement_id UUID;
    v_leg_1_id UUID;
    v_leg_2_id UUID;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive';
    END IF;
    
    INSERT INTO kernel.value_movements (
        movement_type, reference, entry_currency, initiated_by, idempotency_key
    ) VALUES ('transfer', p_reference, p_currency, 
              security.get_participant_context(), crypto.generate_nonce())
    RETURNING movement_id INTO v_movement_id;
    
    INSERT INTO kernel.movement_legs (
        movement_id, leg_sequence, container_id, direction, amount, leg_hash
    ) VALUES (v_movement_id, 1, p_from_container_id, 'debit', p_amount,
              crypto.calculate_leg_hash(v_movement_id, p_from_container_id, 'debit', p_amount))
    RETURNING leg_id INTO v_leg_1_id;
    
    INSERT INTO kernel.movement_legs (
        movement_id, leg_sequence, container_id, direction, amount, leg_hash, related_leg_id
    ) VALUES (v_movement_id, 2, p_to_container_id, 'credit', p_amount,
              crypto.calculate_leg_hash(v_movement_id, p_to_container_id, 'credit', p_amount), v_leg_1_id)
    RETURNING leg_id INTO v_leg_2_id;
    
    UPDATE kernel.movement_legs SET related_leg_id = v_leg_2_id WHERE leg_id = v_leg_1_id;
    
    PERFORM kernel.post_movement(v_movement_id);
    
    RETURN v_movement_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- RLS
-- =============================================================================

ALTER TABLE kernel.movement_legs ENABLE ROW LEVEL SECURITY;

CREATE POLICY movement_legs_container_access ON kernel.movement_legs
    USING (EXISTS (
        SELECT 1 FROM kernel.value_containers vc
        WHERE vc.container_id = movement_legs.container_id
          AND (vc.tenant_id = security.get_tenant_context() OR vc.tenant_id IS NULL)
    ));

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 5: Value Movement & Double-Entry initialized' AS status;
