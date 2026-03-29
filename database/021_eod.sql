-- =============================================================================
-- FILE: 021_eod.sql
-- PURPOSE: Primitive 15b - End of Day Processing
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Banking EOD standards, COBIT
-- DEPENDENCIES: 020_control_batch.sql
-- =============================================================================

-- =============================================================================
-- EOD PROCESSES
-- =============================================================================

CREATE TYPE kernel.eod_status AS ENUM (
    'pending',
    'pre_processing',
    'in_progress',
    'post_processing',
    'completed',
    'failed',
    'rollback'
);

CREATE TYPE kernel.eod_phase AS ENUM (
    'pre_eod',
    'cutoff',
    'processing',
    'post_eod',
    'next_day'
);

CREATE TABLE kernel.eod_processes (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    eod_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Business date being closed
    business_date DATE NOT NULL,
    
    -- Processing scope
    scope VARCHAR(32) DEFAULT 'full',  -- full, partial, retry
    scope_details JSONB DEFAULT '{}',
    
    -- Status
    current_phase kernel.eod_phase DEFAULT 'pre_eod',
    status kernel.eod_status DEFAULT 'pending',
    
    -- Timing
    scheduled_at TIMESTAMP WITH TIME ZONE,
    started_at TIMESTAMP WITH TIME ZONE,
    cutoff_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Processing stats
    steps_total INTEGER DEFAULT 0,
    steps_completed INTEGER DEFAULT 0,
    steps_failed INTEGER DEFAULT 0,
    
    -- Validation
    validation_passed BOOLEAN,
    validation_errors JSONB,
    
    -- Next day
    next_business_date DATE,
    next_day_opened_at TIMESTAMP WITH TIME ZONE,
    
    -- Rollback info
    rollback_reason TEXT,
    rolled_back_by UUID,
    rolled_back_at TIMESTAMP WITH TIME ZONE,
    
    -- Operator
    initiated_by UUID,
    approved_by UUID,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_eod_processes_date ON kernel.eod_processes(business_date);
CREATE INDEX idx_eod_processes_status ON kernel.eod_processes(status);

-- =============================================================================
-- EOD STEPS
-- =============================================================================

CREATE TYPE kernel.eod_step_status AS ENUM (
    'pending',
    'running',
    'completed',
    'failed',
    'skipped',
    'timeout'
);

CREATE TABLE kernel.eod_steps (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    step_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    eod_id UUID NOT NULL REFERENCES kernel.eod_processes(eod_id),
    
    -- Step definition
    step_number INTEGER NOT NULL,
    step_name TEXT NOT NULL,
    step_description TEXT,
    
    -- Dependencies
    depends_on_steps INTEGER[],
    
    -- Execution
    status kernel.eod_step_status DEFAULT 'pending',
    
    -- Timing
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Results
    records_processed INTEGER DEFAULT 0,
    result_summary JSONB,
    error_message TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(eod_id, step_number)
);

CREATE INDEX idx_eod_steps_eod ON kernel.eod_steps(eod_id, step_number);
CREATE INDEX idx_eod_steps_status ON kernel.eod_steps(status);

-- =============================================================================
-- EOD STEP DEFINITIONS (Template)
-- =============================================================================

CREATE TABLE kernel.eod_step_definitions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    definition_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    step_name TEXT NOT NULL,
    step_description TEXT,
    
    -- Default ordering
    default_sequence INTEGER NOT NULL,
    
    -- Function to execute
    execution_function TEXT NOT NULL,
    
    -- Dependencies
    default_dependencies INTEGER[],
    
    -- Criticality
    is_critical BOOLEAN DEFAULT TRUE,  -- If true, failure stops EOD
    
    -- Scope applicability
    applicable_scopes TEXT[] DEFAULT '{full,partial}',
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_eod_step_definitions_seq ON kernel.eod_step_definitions(default_sequence);

-- =============================================================================
-- BUSINESS DAY CALENDAR
-- =============================================================================

CREATE TABLE kernel.business_calendar (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    calendar_date DATE NOT NULL UNIQUE,
    
    -- Day type
    is_business_day BOOLEAN DEFAULT TRUE,
    day_type VARCHAR(32) DEFAULT 'regular',  -- regular, weekend, holiday, half_day
    
    -- Description
    description TEXT,
    holiday_name TEXT,
    
    -- Operating hours
    open_time TIME,
    close_time TIME,
    
    -- Jurisdiction (if holiday is jurisdiction-specific)
    jurisdiction_code VARCHAR(2),
    
    -- Next/Previous business days
    next_business_day DATE,
    previous_business_day DATE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_business_calendar_date ON kernel.business_calendar(calendar_date);
CREATE INDEX idx_business_calendar_is_business ON kernel.business_calendar(is_business_day) WHERE is_business_day = TRUE;

-- =============================================================================
-- EOD BALANCES SNAPSHOT
-- =============================================================================

CREATE TABLE kernel.eod_balance_snapshots (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    snapshot_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    eod_id UUID NOT NULL REFERENCES kernel.eod_processes(eod_id),
    
    -- Container
    container_id UUID NOT NULL REFERENCES kernel.value_containers(container_id),
    
    -- Business date
    business_date DATE NOT NULL,
    
    -- Balances
    opening_balance DECIMAL(24, 6) NOT NULL,
    closing_balance DECIMAL(24, 6) NOT NULL,
    
    -- Activity
    total_credits DECIMAL(24, 6) DEFAULT 0,
    total_debits DECIMAL(24, 6) DEFAULT 0,
    transaction_count INTEGER DEFAULT 0,
    
    -- Validation
    calculated_balance DECIMAL(24, 6) GENERATED ALWAYS AS (opening_balance + total_credits - total_debits) STORED,
    is_balanced BOOLEAN GENERATED ALWAYS AS (closing_balance = opening_balance + total_credits - total_debits) STORED,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(eod_id, container_id)
);

CREATE INDEX idx_eod_balance_snapshots_eod ON kernel.eod_balance_snapshots(eod_id);
CREATE INDEX idx_eod_balance_snapshots_container ON kernel.eod_balance_snapshots(container_id, business_date DESC);

-- =============================================================================
-- CUT-OFF TIMES
-- =============================================================================

CREATE TABLE kernel.cutoff_times (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    cutoff_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- What is being cut off
    process_type VARCHAR(64) NOT NULL,  -- payments, trades, instructions
    currency_code VARCHAR(3),
    
    -- Timing
    cutoff_time TIME NOT NULL,
    effective_days TEXT[],  -- ['MON','TUE','WED','THU','FRI']
    
    -- Jurisdiction
    jurisdiction_code VARCHAR(2),
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Initialize EOD process
CREATE OR REPLACE FUNCTION kernel.initiate_eod(
    p_business_date DATE,
    p_scope VARCHAR DEFAULT 'full'
)
RETURNS UUID AS $$
DECLARE
    v_eod_id UUID;
BEGIN
    INSERT INTO kernel.eod_processes (
        business_date, scope, scheduled_at, initiated_by
    ) VALUES (
        p_business_date, p_scope, NOW(), security.get_participant_context()
    )
    RETURNING eod_id INTO v_eod_id;
    
    -- Create steps from definitions
    INSERT INTO kernel.eod_steps (eod_id, step_number, step_name, step_description, depends_on_steps)
    SELECT v_eod_id, default_sequence, step_name, step_description, default_dependencies
    FROM kernel.eod_step_definitions
    WHERE is_active = TRUE
      AND p_scope = ANY(applicable_scopes)
    ORDER BY default_sequence;
    
    -- Update step count
    UPDATE kernel.eod_processes
    SET steps_total = (SELECT COUNT(*) FROM kernel.eod_steps WHERE eod_id = v_eod_id)
    WHERE eod_id = v_eod_id;
    
    RETURN v_eod_id;
END;
$$ LANGUAGE plpgsql;

-- Start EOD step
CREATE OR REPLACE FUNCTION kernel.start_eod_step(
    p_eod_id UUID,
    p_step_number INTEGER
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.eod_steps
    SET status = 'running', started_at = NOW()
    WHERE eod_id = p_eod_id AND step_number = p_step_number;
    
    UPDATE kernel.eod_processes
    SET current_phase = 'processing', started_at = COALESCE(started_at, NOW())
    WHERE eod_id = p_eod_id;
END;
$$ LANGUAGE plpgsql;

-- Complete EOD step
CREATE OR REPLACE FUNCTION kernel.complete_eod_step(
    p_eod_id UUID,
    p_step_number INTEGER,
    p_status kernel.eod_step_status,
    p_records_processed INTEGER DEFAULT NULL,
    p_result_summary JSONB DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.eod_steps
    SET status = p_status,
        completed_at = NOW(),
        records_processed = COALESCE(p_records_processed, records_processed),
        result_summary = p_result_summary,
        error_message = p_error_message
    WHERE eod_id = p_eod_id AND step_number = p_step_number;
    
    -- Update process counters
    IF p_status = 'completed' THEN
        UPDATE kernel.eod_processes
        SET steps_completed = steps_completed + 1
        WHERE eod_id = p_eod_id;
    ELSIF p_status = 'failed' THEN
        UPDATE kernel.eod_processes
        SET steps_failed = steps_failed + 1,
            status = CASE WHEN EXISTS (
                SELECT 1 FROM kernel.eod_steps es
                JOIN kernel.eod_step_definitions esd ON es.step_name = esd.step_name
                WHERE es.eod_id = p_eod_id AND es.step_number = p_step_number AND esd.is_critical
            ) THEN 'failed' ELSE status END
        WHERE eod_id = p_eod_id;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Complete EOD process
CREATE OR REPLACE FUNCTION kernel.complete_eod(
    p_eod_id UUID,
    p_next_business_date DATE DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.eod_processes
    SET status = 'completed',
        current_phase = 'next_day',
        completed_at = NOW(),
        next_business_date = COALESCE(p_next_business_date, business_date + 1),
        next_day_opened_at = NOW()
    WHERE eod_id = p_eod_id;
END;
$$ LANGUAGE plpgsql;

-- Get next business day
CREATE OR REPLACE FUNCTION kernel.get_next_business_day(p_date DATE DEFAULT CURRENT_DATE)
RETURNS DATE AS $$
DECLARE
    v_next_date DATE;
BEGIN
    SELECT next_business_day INTO v_next_date
    FROM kernel.business_calendar
    WHERE calendar_date = p_date;
    
    RETURN COALESCE(v_next_date, p_date + 1);
END;
$$ LANGUAGE plpgsql;

-- Check if business day
CREATE OR REPLACE FUNCTION kernel.is_business_day(p_date DATE DEFAULT CURRENT_DATE)
RETURNS BOOLEAN AS $$
DECLARE
    v_is_business BOOLEAN;
BEGIN
    SELECT is_business_day INTO v_is_business
    FROM kernel.business_calendar
    WHERE calendar_date = p_date;
    
    RETURN COALESCE(v_is_business, 
        EXTRACT(DOW FROM p_date) NOT IN (0, 6)  -- Default: not weekend
    );
END;
$$ LANGUAGE plpgsql;

-- Take balance snapshot
CREATE OR REPLACE FUNCTION kernel.take_eod_balance_snapshot(
    p_eod_id UUID,
    p_container_id UUID,
    p_business_date DATE
)
RETURNS UUID AS $$
DECLARE
    v_snapshot_id UUID;
    v_opening DECIMAL(24, 6);
    v_closing DECIMAL(24, 6);
    v_credits DECIMAL(24, 6);
    v_debits DECIMAL(24, 6);
    v_txn_count INTEGER;
BEGIN
    -- Calculate balances
    SELECT 
        COALESCE(SUM(CASE WHEN mp.posted_at < p_business_date THEN 
            CASE WHEN ml.direction = 'credit' THEN ml.amount ELSE -ml.amount END 
        ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN mp.posted_at <= p_business_date + INTERVAL '1 day' - INTERVAL '1 second' THEN 
            CASE WHEN ml.direction = 'credit' THEN ml.amount ELSE -ml.amount END 
        ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN ml.direction = 'credit' AND mp.posted_at::DATE = p_business_date THEN ml.amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN ml.direction = 'debit' AND mp.posted_at::DATE = p_business_date THEN ml.amount ELSE 0 END), 0),
        COUNT(CASE WHEN mp.posted_at::DATE = p_business_date THEN 1 END)
    INTO v_opening, v_closing, v_credits, v_debits, v_txn_count
    FROM kernel.movement_legs ml
    JOIN kernel.movement_postings mp ON ml.leg_id = mp.leg_id
    WHERE ml.container_id = p_container_id;
    
    INSERT INTO kernel.eod_balance_snapshots (
        eod_id, container_id, business_date, opening_balance, closing_balance,
        total_credits, total_debits, transaction_count
    ) VALUES (
        p_eod_id, p_container_id, p_business_date, v_opening, v_closing,
        v_credits, v_debits, v_txn_count
    )
    RETURNING snapshot_id INTO v_snapshot_id;
    
    RETURN v_snapshot_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Insert default EOD step definitions
INSERT INTO kernel.eod_step_definitions (step_name, step_description, default_sequence, execution_function, is_critical) VALUES
    ('pre_eod_validation', 'Validate system state before EOD', 1, 'kernel.validate_pre_eod', TRUE),
    ('close_business_day', 'Mark business day as closed for new transactions', 2, 'kernel.close_business_day', TRUE),
    ('process_pending_instructions', 'Process all pending settlement instructions', 3, 'kernel.process_pending_instructions', TRUE),
    ('execute_clearing', 'Execute clearing for net settlement', 4, 'kernel.execute_clearing', FALSE),
    ('take_balance_snapshots', 'Record EOD balances for all containers', 5, 'kernel.take_balance_snapshots', TRUE),
    ('generate_statements', 'Generate customer statements', 6, 'kernel.generate_eod_statements', FALSE),
    ('run_reconciliations', 'Run end-of-day reconciliations', 7, 'kernel.run_eod_reconciliations', TRUE),
    ('execute_controls', 'Run detective controls', 8, 'kernel.execute_eod_controls', TRUE),
    ('archive_data', 'Archive old transaction data', 9, 'kernel.archive_eod_data', FALSE),
    ('open_next_day', 'Open next business day', 10, 'kernel.open_next_business_day', TRUE)
ON CONFLICT DO NOTHING;

-- Populate business calendar for current year
INSERT INTO kernel.business_calendar (calendar_date, is_business_day, day_type, description)
SELECT 
    d::DATE,
    EXTRACT(DOW FROM d) NOT IN (0, 6),
    CASE 
        WHEN EXTRACT(DOW FROM d) = 0 THEN 'weekend'
        WHEN EXTRACT(DOW FROM d) = 6 THEN 'weekend'
        ELSE 'regular'
    END,
    CASE 
        WHEN EXTRACT(DOW FROM d) = 0 THEN 'Sunday'
        WHEN EXTRACT(DOW FROM d) = 6 THEN 'Saturday'
        ELSE 'Business Day'
    END
FROM generate_series(
    DATE_TRUNC('year', CURRENT_DATE)::DATE,
    (DATE_TRUNC('year', CURRENT_DATE) + INTERVAL '1 year' - INTERVAL '1 day')::DATE,
    INTERVAL '1 day'
) AS d
ON CONFLICT (calendar_date) DO NOTHING;

-- Update next/previous business days
UPDATE kernel.business_calendar bc
SET next_business_day = (
    SELECT MIN(calendar_date) 
    FROM kernel.business_calendar 
    WHERE calendar_date > bc.calendar_date AND is_business_day = TRUE
),
previous_business_day = (
    SELECT MAX(calendar_date) 
    FROM kernel.business_calendar 
    WHERE calendar_date < bc.calendar_date AND is_business_day = TRUE
);

SELECT 'Primitive 15b: End of Day Processing initialized' AS status;
