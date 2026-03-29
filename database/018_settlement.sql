-- =============================================================================
-- FILE: 018_settlement.sql
-- PURPOSE: Primitive 13 - Settlement & Clearing
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 20022, SWIFT MT/MX, TARGET2, CLS
-- DEPENDENCIES: 007_value_containers.sql, 008_value_movements.sql
-- =============================================================================

-- =============================================================================
-- SETTLEMENT INSTRUCTIONS
-- =============================================================================

CREATE TYPE kernel.settlement_status AS ENUM (
    'pending',
    'validated',
    'authorized',
    'in_clearing',
    'settled',
    'failed',
    'cancelled'
);

CREATE TYPE kernel.settlement_method AS ENUM (
    'real_time_gross',
    'net_batch',
    'delivery_vs_payment',
    'payment_vs_payment'
);

CREATE TABLE kernel.settlement_instructions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    instruction_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    instruction_reference TEXT UNIQUE NOT NULL,
    
    -- Movement reference
    movement_id UUID REFERENCES kernel.value_movements(movement_id),
    
    -- Parties
    payer_container_id UUID NOT NULL REFERENCES kernel.value_containers(container_id),
    payee_container_id UUID NOT NULL REFERENCES kernel.value_containers(container_id),
    
    -- Amount
    amount DECIMAL(24, 6) NOT NULL,
    currency_code VARCHAR(3) NOT NULL,
    
    -- Settlement method
    method kernel.settlement_method DEFAULT 'real_time_gross',
    priority INTEGER DEFAULT 5,  -- 1 = highest
    
    -- Timing
    requested_settlement_date DATE NOT NULL,
    actual_settlement_timestamp TIMESTAMP WITH TIME ZONE,
    
    -- Status
    status kernel.settlement_status DEFAULT 'pending',
    
    -- Clearing info
    clearing_system VARCHAR(32),  -- TARGET2, CHIPS, Fedwire, etc.
    clearing_reference TEXT,
    
    -- Correspondent banks
    payer_correspondent_id UUID REFERENCES kernel.participants(participant_id),
    payee_correspondent_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Links
    related_instruction_id UUID REFERENCES kernel.settlement_instructions(instruction_id),
    
    -- ISO 20022 fields
    uetr UUID,  -- Unique End-to-end Transaction Reference
    end_to_end_id TEXT,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    signature TEXT,
    proof_inclusion UUID,
    
    CONSTRAINT chk_settlement_instructions_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_settlement_instructions_inst ON kernel.settlement_instructions(instruction_id);
CREATE INDEX idx_settlement_instructions_status ON kernel.settlement_instructions(status);
CREATE INDEX idx_settlement_instructions_date ON kernel.settlement_instructions(requested_settlement_date);

-- =============================================================================
-- CLEARING BATCHES
-- =============================================================================

CREATE TABLE kernel.clearing_batches (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    batch_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    batch_reference TEXT UNIQUE NOT NULL,
    
    -- Batch details
    clearing_system VARCHAR(32) NOT NULL,
    settlement_date DATE NOT NULL,
    
    -- Totals
    instruction_count INTEGER NOT NULL DEFAULT 0,
    total_debit_amount DECIMAL(24, 6) NOT NULL DEFAULT 0,
    total_credit_amount DECIMAL(24, 6) NOT NULL DEFAULT 0,
    net_position DECIMAL(24, 6) GENERATED ALWAYS AS (total_credit_amount - total_debit_amount) STORED,
    
    -- Status
    status VARCHAR(32) DEFAULT 'open',  -- open, closed, submitted, settled
    
    -- Timing
    opened_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    closed_at TIMESTAMP WITH TIME ZONE,
    submitted_at TIMESTAMP WITH TIME ZONE,
    settled_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_clearing_batches_batch ON kernel.clearing_batches(batch_id);
CREATE INDEX idx_clearing_batches_date ON kernel.clearing_batches(settlement_date);

-- =============================================================================
-- CLEARING BATCH ITEMS
-- =============================================================================

CREATE TABLE kernel.clearing_batch_items (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    batch_id UUID NOT NULL REFERENCES kernel.clearing_batches(batch_id),
    instruction_id UUID NOT NULL REFERENCES kernel.settlement_instructions(instruction_id),
    
    -- Position in batch
    sequence_number INTEGER NOT NULL,
    
    -- Direction
    direction VARCHAR(6) NOT NULL,  -- debit, credit
    amount DECIMAL(24, 6) NOT NULL,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(batch_id, sequence_number)
);

CREATE INDEX idx_clearing_batch_items_batch ON kernel.clearing_batch_items(batch_id);

-- =============================================================================
-- NETTING POSITIONS
-- =============================================================================

CREATE TABLE kernel.netting_positions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    position_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Participants
    participant_a_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    participant_b_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Currency
    currency_code VARCHAR(3) NOT NULL,
    
    -- Position
    amount_a_owed DECIMAL(24, 6) DEFAULT 0,  -- A owes B
    amount_b_owed DECIMAL(24, 6) DEFAULT 0,  -- B owes A
    net_position DECIMAL(24, 6) GENERATED ALWAYS AS (amount_b_owed - amount_a_owed) STORED,
    
    -- Direction
    net_debtor_id UUID REFERENCES kernel.participants(participant_id),
    net_amount DECIMAL(24, 6) GENERATED ALWAYS AS (GREATEST(amount_a_owed, amount_b_owed) - LEAST(amount_a_owed, amount_b_owed)) STORED,
    
    -- Last update
    last_instruction_id UUID,
    last_updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Settlement
    settlement_instruction_id UUID,
    settled_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(participant_a_id, participant_b_id, currency_code)
);

CREATE INDEX idx_netting_positions_participants ON kernel.netting_positions(participant_a_id, participant_b_id);

-- =============================================================================
-- SETTLEMENT FAILURES
-- =============================================================================

CREATE TABLE kernel.settlement_failures (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    failure_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    instruction_id UUID NOT NULL REFERENCES kernel.settlement_instructions(instruction_id),
    
    -- Failure details
    failure_type VARCHAR(32) NOT NULL,  -- insufficient_funds, account_closed, invalid_instruction, timeout
    failure_reason TEXT NOT NULL,
    
    -- Resolution
    resolution_action VARCHAR(32),  -- retry, cancel, manual_intervention
    resolved_by UUID,
    resolved_at TIMESTAMP WITH TIME ZONE,
    resolution_notes TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create settlement instruction
CREATE OR REPLACE FUNCTION kernel.create_settlement_instruction(
    p_movement_id UUID,
    p_payer_container_id UUID,
    p_payee_container_id UUID,
    p_amount DECIMAL,
    p_currency_code VARCHAR,
    p_settlement_date DATE,
    p_method kernel.settlement_method DEFAULT 'real_time_gross'
)
RETURNS UUID AS $$
DECLARE
    v_instruction_id UUID;
    v_reference TEXT;
    v_uetr UUID;
BEGIN
    v_reference := 'STL-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    v_uetr := gen_random_uuid();
    
    INSERT INTO kernel.settlement_instructions (
        instruction_reference, movement_id, payer_container_id, payee_container_id,
        amount, currency_code, requested_settlement_date, method, uetr, created_by
    ) VALUES (
        v_reference, p_movement_id, p_payer_container_id, p_payee_container_id,
        p_amount, p_currency_code, p_settlement_date, p_method, v_uetr,
        security.get_participant_context()
    )
    RETURNING instruction_id INTO v_instruction_id;
    
    RETURN v_instruction_id;
END;
$$ LANGUAGE plpgsql;

-- Create clearing batch
CREATE OR REPLACE FUNCTION kernel.create_clearing_batch(
    p_clearing_system VARCHAR,
    p_settlement_date DATE
)
RETURNS UUID AS $$
DECLARE
    v_batch_id UUID;
    v_reference TEXT;
BEGIN
    v_reference := 'BAT-' || p_clearing_system || '-' || to_char(p_settlement_date, 'YYYYMMDD');
    
    INSERT INTO kernel.clearing_batches (
        batch_reference, clearing_system, settlement_date
    ) VALUES (
        v_reference, p_clearing_system, p_settlement_date
    )
    RETURNING batch_id INTO v_batch_id;
    
    RETURN v_batch_id;
END;
$$ LANGUAGE plpgsql;

-- Add instruction to batch
CREATE OR REPLACE FUNCTION kernel.add_to_clearing_batch(
    p_batch_id UUID,
    p_instruction_id UUID
)
RETURNS VOID AS $$
DECLARE
    v_instruction RECORD;
    v_seq INTEGER;
    v_direction VARCHAR(6);
BEGIN
    SELECT * INTO v_instruction FROM kernel.settlement_instructions WHERE instruction_id = p_instruction_id;
    
    -- Determine sequence
    SELECT COALESCE(MAX(sequence_number), 0) + 1 INTO v_seq
    FROM kernel.clearing_batch_items WHERE batch_id = p_batch_id;
    
    -- For simplicity, assume payer = debit, payee = credit
    -- In real system, would look at participant's position
    v_direction := 'debit';
    
    INSERT INTO kernel.clearing_batch_items (
        batch_id, instruction_id, sequence_number, direction, amount
    ) VALUES (
        p_batch_id, p_instruction_id, v_seq, v_direction, v_instruction.amount
    );
    
    -- Update instruction status
    UPDATE kernel.settlement_instructions
    SET status = 'in_clearing'
    WHERE instruction_id = p_instruction_id;
    
    -- Update batch totals
    UPDATE kernel.clearing_batches
    SET instruction_count = instruction_count + 1,
        total_debit_amount = total_debit_amount + v_instruction.amount
    WHERE batch_id = p_batch_id;
END;
$$ LANGUAGE plpgsql;

-- Execute settlement
CREATE OR REPLACE FUNCTION kernel.execute_settlement(p_instruction_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_instruction RECORD;
    v_available DECIMAL(24, 6);
BEGIN
    SELECT * INTO v_instruction FROM kernel.settlement_instructions WHERE instruction_id = p_instruction_id;
    
    -- Check available funds
    SELECT COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE -amount END), 0)
    INTO v_available
    FROM kernel.movement_legs
    WHERE container_id = v_instruction.payer_container_id;
    
    IF v_available < v_instruction.amount THEN
        -- Record failure
        INSERT INTO kernel.settlement_failures (
            instruction_id, failure_type, failure_reason
        ) VALUES (
            p_instruction_id, 'insufficient_funds', 
            'Available: ' || v_available || ', Required: ' || v_instruction.amount
        );
        
        UPDATE kernel.settlement_instructions
        SET status = 'failed'
        WHERE instruction_id = p_instruction_id;
        
        RETURN FALSE;
    END IF;
    
    -- Mark as settled
    UPDATE kernel.settlement_instructions
    SET status = 'settled', actual_settlement_timestamp = NOW()
    WHERE instruction_id = p_instruction_id;
    
    -- Create movement legs if not already created
    -- (Integration with value_movements would happen here)
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Update netting position
CREATE OR REPLACE FUNCTION kernel.update_netting_position(
    p_participant_a_id UUID,
    p_participant_b_id UUID,
    p_currency_code VARCHAR,
    p_amount DECIMAL,
    p_direction VARCHAR  -- 'a_to_b' or 'b_to_a'
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO kernel.netting_positions (
        participant_a_id, participant_b_id, currency_code,
        amount_a_owed, amount_b_owed
    ) VALUES (
        p_participant_a_id, p_participant_b_id, p_currency_code,
        CASE WHEN p_direction = 'a_to_b' THEN p_amount ELSE 0 END,
        CASE WHEN p_direction = 'b_to_a' THEN p_amount ELSE 0 END
    )
    ON CONFLICT (participant_a_id, participant_b_id, currency_code) DO UPDATE SET
        amount_a_owed = kernel.netting_positions.amount_a_owed + 
            CASE WHEN p_direction = 'a_to_b' THEN p_amount ELSE 0 END,
        amount_b_owed = kernel.netting_positions.amount_b_owed + 
            CASE WHEN p_direction = 'b_to_a' THEN p_amount ELSE 0 END,
        last_updated_at = NOW();
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 13: Settlement & Clearing initialized' AS status;
