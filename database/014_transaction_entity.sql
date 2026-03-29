-- =============================================================================
-- FILE: 014_transaction_entity.sql
-- PURPOSE: Primitive 7 - Transaction (Entity management)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: CRDT, Event Sourcing
-- DEPENDENCIES: 013_datoms.sql
-- =============================================================================

-- =============================================================================
-- TRANSACTION ENTITIES - Composite operations
-- =============================================================================

CREATE TYPE kernel.transaction_status AS ENUM (
    'pending',
    'validating',
    'executing',
    'committed',
    'failed',
    'compensating',
    'compensated'
);

CREATE TABLE kernel.transaction_entities (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    transaction_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    transaction_reference TEXT UNIQUE,  -- External reference
    
    -- Classification
    transaction_type VARCHAR(64) NOT NULL,  -- payment, transfer, claim, etc.
    transaction_category VARCHAR(32),       -- financial, operational, system
    
    -- Status
    status kernel.transaction_status DEFAULT 'pending',
    
    -- Participants
    initiator_id UUID REFERENCES kernel.participants(participant_id),
    beneficiary_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Amount
    amount DECIMAL(24, 6),
    currency_code VARCHAR(3),
    
    -- Timestamps
    initiated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    validated_at TIMESTAMP WITH TIME ZONE,
    executed_at TIMESTAMP WITH TIME ZONE,
    committed_at TIMESTAMP WITH TIME ZONE,
    failed_at TIMESTAMP WITH TIME ZONE,
    
    -- Datom references
    datom_transaction_id UUID REFERENCES kernel.datom_transactions(transaction_id),
    
    -- Rollback/Compensation
    compensation_transaction_id UUID,
    compensation_reason TEXT,
    
    -- Metadata
    context JSONB DEFAULT '{}',
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_transaction_entities_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_transaction_entities_txn ON kernel.transaction_entities(transaction_id);
CREATE INDEX idx_transaction_entities_status ON kernel.transaction_entities(status);
CREATE INDEX idx_transaction_entities_type ON kernel.transaction_entities(transaction_type);
CREATE INDEX idx_transaction_entities_initiator ON kernel.transaction_entities(initiator_id);

-- =============================================================================
-- TRANSACTION PARTICIPANTS (many-to-many)
-- =============================================================================

CREATE TABLE kernel.transaction_participants (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    transaction_id UUID NOT NULL REFERENCES kernel.transaction_entities(transaction_id),
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    role VARCHAR(32) NOT NULL,  -- initiator, beneficiary, approver, witness
    
    -- Signature
    signed_at TIMESTAMP WITH TIME ZONE,
    signature TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(transaction_id, participant_id, role)
);

CREATE INDEX idx_txn_participants_txn ON kernel.transaction_participants(transaction_id);
CREATE INDEX idx_txn_participants_participant ON kernel.transaction_participants(participant_id);

-- =============================================================================
-- TRANSACTION OPERATIONS - Steps within a transaction
-- =============================================================================

CREATE TABLE kernel.transaction_operations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    operation_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    transaction_id UUID NOT NULL REFERENCES kernel.transaction_entities(transaction_id),
    
    -- Operation details
    sequence_number INTEGER NOT NULL,
    operation_type VARCHAR(64) NOT NULL,
    
    -- Target entity
    target_entity_type VARCHAR(64),
    target_entity_id UUID,
    
    -- Operation data
    operation_data JSONB NOT NULL DEFAULT '{}',
    
    -- Status
    status VARCHAR(32) DEFAULT 'pending',  -- pending, executing, completed, failed
    
    -- Execution
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    error_message TEXT,
    
    -- Compensation
    compensation_operation_id UUID,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(transaction_id, sequence_number)
);

CREATE INDEX idx_txn_ops_txn ON kernel.transaction_operations(transaction_id);
CREATE INDEX idx_txn_ops_status ON kernel.transaction_operations(status);

-- =============================================================================
-- TRANSACTION JOURNAL - Audit trail
-- =============================================================================

CREATE TABLE kernel.transaction_journal (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    transaction_id UUID NOT NULL REFERENCES kernel.transaction_entities(transaction_id),
    
    -- Event
    event_type VARCHAR(64) NOT NULL,  -- initiated, validated, executed, failed, committed
    event_data JSONB,
    
    -- Actor
    participant_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Timestamp
    event_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Hash chain
    previous_hash TEXT,
    current_hash TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_txn_journal_txn ON kernel.transaction_journal(transaction_id, event_time DESC);

-- =============================================================================
-- SAGA COORDINATION - Long-running transactions
-- =============================================================================

CREATE TABLE kernel.saga_instances (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    saga_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    saga_type VARCHAR(64) NOT NULL,  -- claim_processing, policy_issuance, etc.
    
    -- Status
    status VARCHAR(32) DEFAULT 'running',  -- running, completed, failed, compensating
    
    -- Current step
    current_step INTEGER DEFAULT 0,
    total_steps INTEGER,
    
    -- Context
    context JSONB DEFAULT '{}',
    
    -- Results
    result_data JSONB,
    error_data JSONB,
    
    -- Timing
    started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE kernel.saga_steps (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    saga_id UUID NOT NULL REFERENCES kernel.saga_instances(saga_id),
    step_number INTEGER NOT NULL,
    
    step_name VARCHAR(64) NOT NULL,
    step_type VARCHAR(32) NOT NULL,  -- action, compensation, validation
    
    -- Execution
    status VARCHAR(32) DEFAULT 'pending',  -- pending, executing, completed, failed
    
    -- Transaction link
    transaction_id UUID REFERENCES kernel.transaction_entities(transaction_id),
    
    -- Data
    input_data JSONB,
    output_data JSONB,
    error_message TEXT,
    
    -- Timing
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(saga_id, step_number)
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create a new transaction
CREATE OR REPLACE FUNCTION kernel.create_transaction(
    p_transaction_type VARCHAR,
    p_initiator_id UUID,
    p_context JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_transaction_id UUID;
BEGIN
    INSERT INTO kernel.transaction_entities (
        transaction_type, initiator_id, context, created_by
    ) VALUES (
        p_transaction_type, p_initiator_id, p_context,
        security.get_participant_context()
    )
    RETURNING transaction_id INTO v_transaction_id;
    
    -- Add initiator as participant
    INSERT INTO kernel.transaction_participants (
        transaction_id, participant_id, role
    ) VALUES (
        v_transaction_id, p_initiator_id, 'initiator'
    );
    
    -- Log initiation
    INSERT INTO kernel.transaction_journal (
        transaction_id, event_type, event_data, participant_id
    ) VALUES (
        v_transaction_id, 'initiated', jsonb_build_object('type', p_transaction_type),
        p_initiator_id
    );
    
    RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql;

-- Add operation to transaction
CREATE OR REPLACE FUNCTION kernel.add_transaction_operation(
    p_transaction_id UUID,
    p_sequence INTEGER,
    p_operation_type VARCHAR,
    p_target_type VARCHAR,
    p_target_id UUID,
    p_data JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_operation_id UUID;
BEGIN
    INSERT INTO kernel.transaction_operations (
        transaction_id, sequence_number, operation_type,
        target_entity_type, target_entity_id, operation_data
    ) VALUES (
        p_transaction_id, p_sequence, p_operation_type,
        p_target_type, p_target_id, p_data
    )
    RETURNING operation_id INTO v_operation_id;
    
    RETURN v_operation_id;
END;
$$ LANGUAGE plpgsql;

-- Execute transaction
CREATE OR REPLACE FUNCTION kernel.execute_transaction(p_transaction_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_op RECORD;
    v_success BOOLEAN := TRUE;
BEGIN
    UPDATE kernel.transaction_entities
    SET status = 'executing', executed_at = NOW()
    WHERE transaction_id = p_transaction_id;
    
    FOR v_op IN 
        SELECT * FROM kernel.transaction_operations
        WHERE transaction_id = p_transaction_id
        ORDER BY sequence_number
    LOOP
        UPDATE kernel.transaction_operations
        SET status = 'executing', started_at = NOW()
        WHERE operation_id = v_op.operation_id;
        
        -- Operations would be dispatched here based on type
        -- This is a simplified version
        
        UPDATE kernel.transaction_operations
        SET status = 'completed', completed_at = NOW()
        WHERE operation_id = v_op.operation_id;
    END LOOP;
    
    IF v_success THEN
        UPDATE kernel.transaction_entities
        SET status = 'committed', committed_at = NOW()
        WHERE transaction_id = p_transaction_id;
        
        INSERT INTO kernel.transaction_journal (
            transaction_id, event_type, event_data
        ) VALUES (
            p_transaction_id, 'committed',
            jsonb_build_object('operations_completed', 
                (SELECT COUNT(*) FROM kernel.transaction_operations WHERE transaction_id = p_transaction_id)
            )
        );
    ELSE
        UPDATE kernel.transaction_entities
        SET status = 'failed', failed_at = NOW()
        WHERE transaction_id = p_transaction_id;
    END IF;
    
    RETURN v_success;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 7: Transaction (Entity management) initialized' AS status;
