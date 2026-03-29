-- =============================================================================
-- FILE: 020_control_batch.sql
-- PURPOSE: Primitive 15 - Control & Batch Processing
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: COBIT, ISO 27001
-- DEPENDENCIES: 007_value_containers.sql
-- =============================================================================

-- =============================================================================
-- CONTROL DEFINITIONS
-- =============================================================================

CREATE TYPE kernel.control_type AS ENUM (
    'preventive',
    'detective',
    'corrective',
    'compensating'
);

CREATE TYPE kernel.control_frequency AS ENUM (
    'continuous',
    'daily',
    'weekly',
    'monthly',
    'quarterly',
    'annual',
    'ad_hoc'
);

CREATE TYPE kernel.control_status AS ENUM (
    'active',
    'inactive',
    'under_review',
    'deprecated'
);

CREATE TABLE kernel.controls (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    control_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    control_code TEXT UNIQUE NOT NULL,
    
    -- Basic info
    name TEXT NOT NULL,
    description TEXT,
    purpose TEXT,
    
    -- Classification
    control_type kernel.control_type NOT NULL,
    frequency kernel.control_frequency NOT NULL,
    
    -- Risk linkage
    risk_id TEXT,  -- Reference to risk register
    compliance_requirement TEXT,  -- SOX, PCI, GDPR, etc.
    
    -- Implementation
    implementation_details TEXT,
    automation_level VARCHAR(32) DEFAULT 'manual',  -- manual, semi_automated, automated
    
    -- Ownership
    owner_id UUID REFERENCES kernel.participants(participant_id),
    reviewer_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Status
    status kernel.control_status DEFAULT 'active',
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_controls_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_controls_control ON kernel.controls(control_id);
CREATE INDEX idx_controls_code ON kernel.controls(control_code);
CREATE INDEX idx_controls_status ON kernel.controls(status);

-- =============================================================================
-- CONTROL EXECUTIONS
-- =============================================================================

CREATE TYPE kernel.control_result AS ENUM (
    'passed',
    'failed',
    'warning',
    'error',
    'not_applicable'
);

CREATE TABLE kernel.control_executions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    execution_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    control_id UUID NOT NULL REFERENCES kernel.controls(control_id),
    
    -- Execution context
    execution_type VARCHAR(32) NOT NULL,  -- scheduled, manual, event_triggered
    triggered_by UUID REFERENCES kernel.participants(participant_id),
    
    -- Parameters
    execution_parameters JSONB DEFAULT '{}',
    scope_container_id UUID REFERENCES kernel.value_containers(container_id),
    
    -- Timing
    scheduled_at TIMESTAMP WITH TIME ZONE,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Result
    result kernel.control_result,
    result_details JSONB,
    evidence TEXT,  -- Link to evidence
    
    -- Findings
    findings_count INTEGER DEFAULT 0,
    exceptions_count INTEGER DEFAULT 0,
    
    -- Review
    reviewed_by UUID,
    reviewed_at TIMESTAMP WITH TIME ZONE,
    review_notes TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_control_executions_control ON kernel.control_executions(control_id, started_at DESC);
CREATE INDEX idx_control_executions_result ON kernel.control_executions(result);

-- =============================================================================
-- CONTROL FINDINGS
-- =============================================================================

CREATE TABLE kernel.control_findings (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    finding_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    execution_id UUID NOT NULL REFERENCES kernel.control_executions(execution_id),
    control_id UUID NOT NULL REFERENCES kernel.controls(control_id),
    
    -- Finding details
    severity VARCHAR(16) NOT NULL,  -- critical, high, medium, low
    category VARCHAR(32),  -- data_integrity, authorization, segregation, etc.
    title TEXT NOT NULL,
    description TEXT,
    
    -- Affected items
    affected_container_id UUID REFERENCES kernel.value_containers(container_id),
    affected_transaction_id UUID,
    affected_records JSONB,
    
    -- Impact
    financial_impact DECIMAL(24, 6),
    
    -- Status
    status VARCHAR(16) DEFAULT 'open',  -- open, remediated, accepted, transferred
    
    -- Remediation
    remediation_plan TEXT,
    remediation_owner UUID REFERENCES kernel.participants(participant_id),
    remediation_due_date DATE,
    remediated_at TIMESTAMP WITH TIME ZONE,
    remediated_by UUID,
    remediation_evidence TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_control_findings_execution ON kernel.control_findings(execution_id);
CREATE INDEX idx_control_findings_status ON kernel.control_findings(status);

-- =============================================================================
-- BATCH JOBS
-- =============================================================================

CREATE TYPE kernel.batch_job_status AS ENUM (
    'pending',
    'queued',
    'running',
    'completed',
    'failed',
    'cancelled',
    'timeout'
);

CREATE TABLE kernel.batch_jobs (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    job_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    job_name TEXT NOT NULL,
    job_type VARCHAR(64) NOT NULL,  -- report, reconciliation, statement, cleanup
    
    -- Schedule
    schedule_type VARCHAR(32) NOT NULL,  -- immediate, once, recurring
    cron_expression TEXT,  -- For recurring jobs
    next_run_at TIMESTAMP WITH TIME ZONE,
    
    -- Current run
    current_status kernel.batch_job_status DEFAULT 'pending',
    current_run_id UUID,
    
    -- Configuration
    job_parameters JSONB DEFAULT '{}',
    
    -- Ownership
    owner_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Notifications
    notify_on_completion BOOLEAN DEFAULT FALSE,
    notify_emails TEXT[],
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_run_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_batch_jobs_job ON kernel.batch_jobs(job_id);
CREATE INDEX idx_batch_jobs_status ON kernel.batch_jobs(current_status);
CREATE INDEX idx_batch_jobs_next_run ON kernel.batch_jobs(next_run_at) WHERE is_active = TRUE;

-- =============================================================================
-- BATCH RUNS
-- =============================================================================

CREATE TABLE kernel.batch_runs (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    run_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    job_id UUID NOT NULL REFERENCES kernel.batch_jobs(job_id),
    
    -- Execution
    status kernel.batch_job_status DEFAULT 'pending',
    
    -- Timing
    queued_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Progress
    total_items INTEGER DEFAULT 0,
    processed_items INTEGER DEFAULT 0,
    failed_items INTEGER DEFAULT 0,
    progress_percent DECIMAL(5, 2) DEFAULT 0,
    
    -- Results
    output_location TEXT,
    result_summary JSONB,
    error_message TEXT,
    
    -- Resources
    executor_node TEXT,
    memory_used_mb INTEGER,
    cpu_seconds INTEGER,
    
    triggered_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_batch_runs_job ON kernel.batch_runs(job_id, started_at DESC);
CREATE INDEX idx_batch_runs_status ON kernel.batch_runs(status);

-- =============================================================================
-- BATCH RUN ITEMS (Detailed tracking)
-- =============================================================================

CREATE TABLE kernel.batch_run_items (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    run_id UUID NOT NULL REFERENCES kernel.batch_runs(run_id),
    
    -- Item details
    item_type VARCHAR(32) NOT NULL,
    item_id UUID,
    item_reference TEXT,
    
    -- Status
    status VARCHAR(16) DEFAULT 'pending',  -- pending, processing, completed, failed
    
    -- Processing
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Results
    result_data JSONB,
    error_code TEXT,
    error_message TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_batch_run_items_run ON kernel.batch_run_items(run_id);
CREATE INDEX idx_batch_run_items_status ON kernel.batch_run_items(status);

-- =============================================================================
-- STATEMENT GENERATION
-- =============================================================================

CREATE TABLE kernel.statements (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    statement_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    statement_number TEXT UNIQUE NOT NULL,
    
    -- Recipient
    participant_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    container_id UUID REFERENCES kernel.value_containers(container_id),
    
    -- Period
    statement_date DATE NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    
    -- Content
    opening_balance DECIMAL(24, 6) NOT NULL,
    closing_balance DECIMAL(24, 6) NOT NULL,
    total_credits DECIMAL(24, 6) DEFAULT 0,
    total_debits DECIMAL(24, 6) DEFAULT 0,
    transaction_count INTEGER DEFAULT 0,
    
    -- Delivery
    delivery_method VARCHAR(32) DEFAULT 'email',  -- email, portal, api, paper
    delivered_at TIMESTAMP WITH TIME ZONE,
    delivery_status VARCHAR(32) DEFAULT 'pending',
    
    -- Storage
    storage_path TEXT,
    document_hash TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_statements_participant ON kernel.statements(participant_id, statement_date DESC);
CREATE INDEX idx_statements_container ON kernel.statements(container_id, statement_date DESC);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create control
CREATE OR REPLACE FUNCTION kernel.create_control(
    p_control_code TEXT,
    p_name TEXT,
    p_control_type kernel.control_type,
    p_frequency kernel.control_frequency
)
RETURNS UUID AS $$
DECLARE
    v_control_id UUID;
BEGIN
    INSERT INTO kernel.controls (
        control_code, name, control_type, frequency, created_by
    ) VALUES (
        p_control_code, p_name, p_control_type, p_frequency,
        security.get_participant_context()
    )
    RETURNING control_id INTO v_control_id;
    
    RETURN v_control_id;
END;
$$ LANGUAGE plpgsql;

-- Execute control
CREATE OR REPLACE FUNCTION kernel.execute_control(
    p_control_id UUID,
    p_parameters JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_execution_id UUID;
BEGIN
    INSERT INTO kernel.control_executions (
        control_id, execution_type, execution_parameters, triggered_by
    ) VALUES (
        p_control_id, 'manual', p_parameters, security.get_participant_context()
    )
    RETURNING execution_id INTO v_execution_id;
    
    RETURN v_execution_id;
END;
$$ LANGUAGE plpgsql;

-- Create batch job
CREATE OR REPLACE FUNCTION kernel.create_batch_job(
    p_job_name TEXT,
    p_job_type VARCHAR,
    p_schedule_type VARCHAR,
    p_parameters JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_job_id UUID;
BEGIN
    INSERT INTO kernel.batch_jobs (
        job_name, job_type, schedule_type, job_parameters, created_by
    ) VALUES (
        p_job_name, p_job_type, p_schedule_type, p_parameters,
        security.get_participant_context()
    )
    RETURNING job_id INTO v_job_id;
    
    RETURN v_job_id;
END;
$$ LANGUAGE plpgsql;

-- Start batch run
CREATE OR REPLACE FUNCTION kernel.start_batch_run(p_job_id UUID)
RETURNS UUID AS $$
DECLARE
    v_run_id UUID;
BEGIN
    INSERT INTO kernel.batch_runs (
        job_id, status, started_at, triggered_by
    ) VALUES (
        p_job_id, 'running', NOW(), security.get_participant_context()
    )
    RETURNING run_id INTO v_run_id;
    
    UPDATE kernel.batch_jobs
    SET current_run_id = v_run_id, current_status = 'running', last_run_at = NOW()
    WHERE job_id = p_job_id;
    
    RETURN v_run_id;
END;
$$ LANGUAGE plpgsql;

-- Complete batch run
CREATE OR REPLACE FUNCTION kernel.complete_batch_run(
    p_run_id UUID,
    p_status kernel.batch_job_status,
    p_result_summary JSONB DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
    v_job_id UUID;
BEGIN
    UPDATE kernel.batch_runs
    SET status = p_status, completed_at = NOW(), result_summary = p_result_summary
    WHERE run_id = p_run_id
    RETURNING job_id INTO v_job_id;
    
    UPDATE kernel.batch_jobs
    SET current_status = p_status,
        current_run_id = NULL,
        next_run_at = CASE 
            WHEN schedule_type = 'recurring' AND cron_expression IS NOT NULL 
            THEN NOW() + INTERVAL '1 day'  -- Simplified
            ELSE NULL 
        END
    WHERE job_id = v_job_id;
END;
$$ LANGUAGE plpgsql;

-- Create statement
CREATE OR REPLACE FUNCTION kernel.generate_statement(
    p_participant_id UUID,
    p_container_id UUID,
    p_period_start DATE,
    p_period_end DATE
)
RETURNS UUID AS $$
DECLARE
    v_statement_id UUID;
    v_statement_number TEXT;
    v_opening_balance DECIMAL(24, 6);
    v_closing_balance DECIMAL(24, 6);
    v_total_credits DECIMAL(24, 6);
    v_total_debits DECIMAL(24, 6);
    v_txn_count INTEGER;
BEGIN
    v_statement_number := 'STM-' || to_char(p_period_end, 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 6);
    
    -- Calculate balances (simplified)
    SELECT 
        COALESCE(SUM(CASE WHEN mp.posted_at < p_period_start THEN 
            CASE WHEN ml.direction = 'credit' THEN ml.amount ELSE -ml.amount END 
        ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN mp.posted_at <= p_period_end THEN 
            CASE WHEN ml.direction = 'credit' THEN ml.amount ELSE -ml.amount END 
        ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN ml.direction = 'credit' AND mp.posted_at BETWEEN p_period_start AND p_period_end THEN ml.amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN ml.direction = 'debit' AND mp.posted_at BETWEEN p_period_start AND p_period_end THEN ml.amount ELSE 0 END), 0),
        COUNT(CASE WHEN mp.posted_at BETWEEN p_period_start AND p_period_end THEN 1 END)
    INTO v_opening_balance, v_closing_balance, v_total_credits, v_total_debits, v_txn_count
    FROM kernel.movement_legs ml
    JOIN kernel.movement_postings mp ON ml.leg_id = mp.leg_id
    WHERE ml.container_id = p_container_id;
    
    INSERT INTO kernel.statements (
        statement_number, participant_id, container_id, statement_date,
        period_start, period_end, opening_balance, closing_balance,
        total_credits, total_debits, transaction_count
    ) VALUES (
        v_statement_number, p_participant_id, p_container_id, p_period_end,
        p_period_start, p_period_end, v_opening_balance, v_closing_balance,
        v_total_credits, v_total_debits, v_txn_count
    )
    RETURNING statement_id INTO v_statement_id;
    
    RETURN v_statement_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Insert default controls
INSERT INTO kernel.controls (control_code, name, control_type, frequency, description, automation_level) VALUES
    ('CTRL-001', 'Segregation of Duties', 'preventive', 'continuous', 'Ensure no single person can authorize and execute transactions', 'automated'),
    ('CTRL-002', 'Daily Balance Reconciliation', 'detective', 'daily', 'Reconcile internal ledger balances with external statements', 'automated'),
    ('CTRL-003', 'Transaction Authorization', 'preventive', 'continuous', 'All transactions above threshold require dual authorization', 'automated'),
    ('CTRL-004', 'Access Review', 'detective', 'quarterly', 'Review and validate user access permissions', 'semi_automated'),
    ('CTRL-005', 'Data Integrity Check', 'detective', 'daily', 'Verify hash chain integrity for all tables', 'automated')
ON CONFLICT (control_code) DO NOTHING;

SELECT 'Primitive 15: Control & Batch Processing initialized' AS status;
