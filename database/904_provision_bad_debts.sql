-- =============================================================================
-- FILE: 904_provision_bad_debts.sql
-- PURPOSE: Phase 5 - Provision for Bad Debts (IFRS 9)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: IFRS 9 (Financial Instruments)
-- DEPENDENCIES: 900_chart_of_accounts.sql
-- =============================================================================

-- =============================================================================
-- RECEIVABLES AGING BUCKETS
-- =============================================================================

CREATE TABLE kernel.receivables_aging_buckets (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    bucket_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Bucket Definition
    bucket_name VARCHAR(64) NOT NULL,
    min_days INTEGER NOT NULL,
    max_days INTEGER,
    
    -- Default Provision Rates
    default_loss_rate DECIMAL(5, 4) NOT NULL DEFAULT 0,  -- e.g., 0.05 = 5%
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

COMMENT ON TABLE kernel.receivables_aging_buckets IS 'Aging buckets for bad debt provisioning';

CREATE INDEX idx_aging_buckets_tenant ON kernel.receivables_aging_buckets(tenant_id, is_active);

-- =============================================================================
-- PROVISION FOR BAD DEBTS
-- =============================================================================

CREATE TABLE kernel.bad_debt_provisions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    provision_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- As Of Date
    provision_date DATE NOT NULL,
    fiscal_year INTEGER,
    period_number INTEGER,
    
    -- Receivable Type
    receivable_type VARCHAR(32) NOT NULL CHECK (receivable_type IN (
        'sales', 'insurance_premium', 'insurance_claim', 'repair_services'
    )),
    
    -- Aging Bucket
    aging_bucket_id UUID REFERENCES kernel.receivables_aging_buckets(bucket_id),
    bucket_name VARCHAR(64),
    days_overdue INTEGER,
    
    -- Amounts
    gross_receivable DECIMAL(15, 2) NOT NULL,
    loss_rate DECIMAL(5, 4) NOT NULL,
    provision_amount DECIMAL(15, 2) NOT NULL,
    
    -- Expected Credit Loss (IFRS 9)
    ecl_stage VARCHAR(16) NOT NULL DEFAULT 'stage_1' CHECK (ecl_stage IN ('stage_1', 'stage_2', 'stage_3')),
    -- Stage 1: 12-month ECL
    -- Stage 2: Lifetime ECL (significant increase in credit risk)
    -- Stage 3: Lifetime ECL (credit impaired)
    
    -- Link to value movement
    value_movement_id UUID REFERENCES kernel.value_movements(movement_id),
    
    -- Status
    is_posted BOOLEAN DEFAULT FALSE,
    posted_at TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_bad_debt_provisions_date ON kernel.bad_debt_provisions(tenant_id, provision_date);
CREATE INDEX idx_bad_debt_provisions_type ON kernel.bad_debt_provisions(receivable_type, provision_date);

-- =============================================================================
-- WRITE-OFFS
-- =============================================================================

CREATE TABLE kernel.bad_debt_writeoffs (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    writeoff_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Source
    receivable_type VARCHAR(32) NOT NULL,
    receivable_id UUID NOT NULL,  -- sales_order_id or policy_id
    
    -- Amounts
    gross_amount DECIMAL(15, 2) NOT NULL,
    provision_applied DECIMAL(15, 2) NOT NULL,
    net_writeoff DECIMAL(15, 2) NOT NULL,
    
    -- Reason
    writeoff_reason TEXT NOT NULL,
    approved_by UUID,
    
    -- Link
    value_movement_id UUID REFERENCES kernel.value_movements(movement_id),
    
    writeoff_date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_bad_debt_writeoffs_date ON kernel.bad_debt_writeoffs(tenant_id, writeoff_date);
CREATE INDEX idx_bad_debt_writeoffs_receivable ON kernel.bad_debt_writeoffs(receivable_type, receivable_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Get Age Bucket for Receivable
CREATE OR REPLACE FUNCTION kernel.get_receivable_age_bucket(
    p_days_overdue INTEGER,
    p_tenant_id UUID
)
RETURNS UUID AS $$
DECLARE
    v_bucket_id UUID;
BEGIN
    SELECT bucket_id INTO v_bucket_id
    FROM kernel.receivables_aging_buckets
    WHERE tenant_id = p_tenant_id
      AND is_active = TRUE
      AND min_days <= p_days_overdue
      AND (max_days IS NULL OR max_days >= p_days_overdue)
    ORDER BY min_days DESC
    LIMIT 1;
    
    RETURN v_bucket_id;
END;
$$ LANGUAGE plpgsql;

-- Calculate Aged Receivables
CREATE OR REPLACE FUNCTION kernel.calculate_aged_receivables(
    p_tenant_id UUID,
    p_as_of_date DATE
)
RETURNS TABLE (
    receivable_type VARCHAR,
    receivable_id UUID,
    customer_id UUID,
    customer_name TEXT,
    gross_amount DECIMAL,
    paid_amount DECIMAL,
    outstanding DECIMAL,
    invoice_date DATE,
    due_date DATE,
    days_overdue INTEGER,
    bucket_name VARCHAR,
    bucket_id UUID
) AS $$
BEGIN
    -- Sales Orders (Installment or Unpaid)
    RETURN QUERY
    SELECT 
        'sales'::VARCHAR AS receivable_type,
        o.order_id AS receivable_id,
        o.customer_id,
        c.name AS customer_name,
        o.total_amount AS gross_amount,
        COALESCE(o.total_paid, 0) AS paid_amount,
        o.total_amount - COALESCE(o.total_paid, 0) AS outstanding,
        o.order_date AS invoice_date,
        COALESCE(o.due_date, o.order_date + INTERVAL '30 days')::DATE AS due_date,
        GREATEST(p_as_of_date - COALESCE(o.due_date, o.order_date + INTERVAL '30 days')::DATE, 0) AS days_overdue,
        COALESCE(b.bucket_name, 'Current')::VARCHAR AS bucket_name,
        b.bucket_id
    FROM kernel.sales_orders o
    JOIN kernel.customers c ON o.customer_id = c.customer_id
    LEFT JOIN kernel.receivables_aging_buckets b ON b.bucket_id = kernel.get_receivable_age_bucket(
        GREATEST(p_as_of_date - COALESCE(o.due_date, o.order_date + INTERVAL '30 days')::DATE, 0),
        p_tenant_id
    )
    WHERE o.tenant_id = p_tenant_id
      AND o.status IN ('confirmed', 'shipped', 'invoiced', 'partial_paid')
      AND o.total_amount > COALESCE(o.total_paid, 0);
    
    -- Insurance Premiums (Add installments if exists)
    -- This is a simplified version - in reality, you'd join with premium installment schedules
    RETURN QUERY
    SELECT 
        'insurance_premium'::VARCHAR AS receivable_type,
        p.policy_id AS receivable_id,
        cp.customer_id,
        c.name AS customer_name,
        p.premium_amount AS gross_amount,
        0::DECIMAL AS paid_amount,
        p.premium_amount AS outstanding,
        p.effective_start_date AS invoice_date,
        p.effective_start_date AS due_date,
        GREATEST(p_as_of_date - p.effective_start_date, 0) AS days_overdue,
        COALESCE(b.bucket_name, 'Current')::VARCHAR AS bucket_name,
        b.bucket_id
    FROM kernel.insurance_policies p
    JOIN kernel.customers cp ON p.policyholder_id = cp.customer_id
    JOIN kernel.parties c ON cp.customer_id = c.party_id
    LEFT JOIN kernel.receivables_aging_buckets b ON b.bucket_id = kernel.get_receivable_age_bucket(
        GREATEST(p_as_of_date - p.effective_start_date, 0),
        p_tenant_id
    )
    WHERE p.tenant_id = p_tenant_id
      AND p.status = 'active'
      AND p.premium_amount > 0;
END;
$$ LANGUAGE plpgsql;

-- Calculate Bad Debt Provision
CREATE OR REPLACE FUNCTION kernel.calculate_bad_debt_provision(
    p_tenant_id UUID,
    p_as_of_date DATE
)
RETURNS TABLE (
    receivable_type VARCHAR,
    bucket_name VARCHAR,
    gross_amount DECIMAL,
    loss_rate DECIMAL,
    provision_amount DECIMAL,
    ecl_stage VARCHAR
) AS $$
DECLARE
    v_receivable RECORD;
    v_bucket RECORD;
    v_days INTEGER;
    v_stage VARCHAR;
BEGIN
    -- Group aged receivables by bucket and calculate provision
    RETURN QUERY
    WITH aged AS (
        SELECT * FROM kernel.calculate_aged_receivables(p_tenant_id, p_as_of_date)
    ),
    bucketed AS (
        SELECT 
            a.receivable_type,
            COALESCE(a.bucket_name, 'Current') AS bucket_name,
            a.bucket_id,
            SUM(a.outstanding) AS gross_amount,
            COALESCE(b.default_loss_rate, 0) AS loss_rate,
            -- ECL Stage based on days overdue
            CASE 
                WHEN a.days_overdue > 90 THEN 'stage_3'
                WHEN a.days_overdue > 30 THEN 'stage_2'
                ELSE 'stage_1'
            END AS ecl_stage
        FROM aged a
        LEFT JOIN kernel.receivables_aging_buckets b ON a.bucket_id = b.bucket_id
        WHERE a.outstanding > 0
        GROUP BY a.receivable_type, COALESCE(a.bucket_name, 'Current'), a.bucket_id, b.default_loss_rate,
                 CASE 
                    WHEN a.days_overdue > 90 THEN 'stage_3'
                    WHEN a.days_overdue > 30 THEN 'stage_2'
                    ELSE 'stage_1'
                 END
    )
    SELECT 
        b.receivable_type::VARCHAR,
        b.bucket_name::VARCHAR,
        b.gross_amount::DECIMAL,
        b.loss_rate::DECIMAL,
        ROUND(b.gross_amount * b.loss_rate, 2)::DECIMAL AS provision_amount,
        b.ecl_stage::VARCHAR
    FROM bucketed b
    ORDER BY b.receivable_type, b.bucket_name;
END;
$$ LANGUAGE plpgsql;

-- Post Bad Debt Provision
CREATE OR REPLACE FUNCTION kernel.post_bad_debt_provision(
    p_tenant_id UUID,
    p_as_of_date DATE
)
RETURNS DECIMAL AS $$
DECLARE
    v_total_provision DECIMAL := 0;
    v_calc RECORD;
    v_provision_id UUID;
    v_expense_account TEXT := '5410';  -- Provision for Bad Debts
    v_contra_account TEXT := '1130';   -- Allowance for Doubtful Accounts
BEGIN
    -- Clear existing unposted provisions for this date
    DELETE FROM kernel.bad_debt_provisions
    WHERE tenant_id = p_tenant_id
      AND provision_date = p_as_of_date
      AND is_posted = FALSE;
    
    -- Calculate and store new provisions
    FOR v_calc IN 
        SELECT * FROM kernel.calculate_bad_debt_provision(p_tenant_id, p_as_of_date)
        WHERE provision_amount > 0
    LOOP
        INSERT INTO kernel.bad_debt_provisions (
            tenant_id, provision_date, fiscal_year, period_number,
            receivable_type, bucket_name, gross_receivable, loss_rate, provision_amount,
            ecl_stage
        ) VALUES (
            p_tenant_id, p_as_of_date, EXTRACT(YEAR FROM p_as_of_date), EXTRACT(MONTH FROM p_as_of_date),
            v_calc.receivable_type, v_calc.bucket_name, v_calc.gross_amount, v_calc.loss_rate,
            v_calc.provision_amount, v_calc.ecl_stage
        )
        RETURNING provision_id INTO v_provision_id;
        
        v_total_provision := v_total_provision + v_calc.provision_amount;
    END LOOP;
    
    RETURN v_total_provision;
END;
$$ LANGUAGE plpgsql;

-- Write Off Bad Debt
CREATE OR REPLACE FUNCTION kernel.writeoff_bad_debt(
    p_tenant_id UUID,
    p_receivable_type VARCHAR,
    p_receivable_id UUID,
    p_writeoff_amount DECIMAL,
    p_writeoff_reason TEXT,
    p_approved_by UUID
)
RETURNS UUID AS $$
DECLARE
    v_outstanding DECIMAL;
    v_gross_amount DECIMAL;
    v_provision DECIMAL := 0;
    v_net_writeoff DECIMAL;
    v_writeoff_id UUID;
BEGIN
    -- Get outstanding amount
    SELECT outstanding INTO v_outstanding
    FROM kernel.calculate_aged_receivables(p_tenant_id, CURRENT_DATE)
    WHERE receivable_type = p_receivable_type AND receivable_id = p_receivable_id;
    
    IF v_outstanding IS NULL OR v_outstanding <= 0 THEN
        RAISE EXCEPTION 'No outstanding receivable found';
    END IF;
    
    v_gross_amount := LEAST(p_writeoff_amount, v_outstanding);
    
    -- Get existing provision for this receivable
    -- (Simplified - in reality, you'd track provision at individual receivable level)
    SELECT COALESCE(SUM(provision_amount), 0) * (v_gross_amount / NULLIF(SUM(gross_receivable), 0)) INTO v_provision
    FROM kernel.bad_debt_provisions
    WHERE tenant_id = p_tenant_id
      AND receivable_type = p_receivable_type;
    
    v_provision := LEAST(v_provision, v_gross_amount);
    v_net_writeoff := v_gross_amount - v_provision;
    
    INSERT INTO kernel.bad_debt_writeoffs (
        tenant_id, receivable_type, receivable_id,
        gross_amount, provision_applied, net_writeoff,
        writeoff_reason, approved_by, writeoff_date
    ) VALUES (
        p_tenant_id, p_receivable_type, p_receivable_id,
        v_gross_amount, v_provision, v_net_writeoff,
        p_writeoff_reason, p_approved_by, CURRENT_DATE
    )
    RETURNING writeoff_id INTO v_writeoff_id;
    
    RETURN v_writeoff_id;
END;
$$ LANGUAGE plpgsql;

-- Get Bad Debt Provision Summary
CREATE OR REPLACE FUNCTION kernel.get_bad_debt_summary(
    p_tenant_id UUID,
    p_as_of_date DATE
)
RETURNS TABLE (
    metric_name TEXT,
    metric_value DECIMAL
) AS $$
BEGIN
    -- Total Gross Receivables
    RETURN QUERY SELECT 
        'Total Gross Receivables'::TEXT,
        COALESCE(SUM(gross_receivable), 0)
    FROM kernel.bad_debt_provisions
    WHERE tenant_id = p_tenant_id AND provision_date = p_as_of_date;
    
    -- Total Provision Required
    RETURN QUERY SELECT 
        'Bad Debt Provision Required'::TEXT,
        COALESCE(SUM(provision_amount), 0)
    FROM kernel.bad_debt_provisions
    WHERE tenant_id = p_tenant_id AND provision_date = p_as_of_date;
    
    -- Net Receivables
    RETURN QUERY SELECT 
        'Net Receivables'::TEXT,
        COALESCE(SUM(gross_receivable), 0) - COALESCE(SUM(provision_amount), 0)
    FROM kernel.bad_debt_provisions
    WHERE tenant_id = p_tenant_id AND provision_date = p_as_of_date;
    
    -- YTD Write-offs
    RETURN QUERY SELECT 
        'YTD Write-offs'::TEXT,
        COALESCE(SUM(gross_amount), 0)
    FROM kernel.bad_debt_writeoffs
    WHERE tenant_id = p_tenant_id
      AND writeoff_date >= DATE_TRUNC('year', p_as_of_date)::DATE;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SEED DATA
-- =============================================================================

-- Standard aging buckets
INSERT INTO kernel.receivables_aging_buckets (tenant_id, bucket_name, min_days, max_days, default_loss_rate) VALUES
    (NULL, 'Current', 0, 30, 0.005),    -- 0.5%
    (NULL, '31-60 Days', 31, 60, 0.02), -- 2%
    (NULL, '61-90 Days', 61, 90, 0.10), -- 10%
    (NULL, '91-120 Days', 91, 120, 0.25), -- 25%
    (NULL, 'Over 120 Days', 121, NULL, 0.50) -- 50%
ON CONFLICT DO NOTHING;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Phase 5: Bad Debt Provision (IFRS 9) initialized' AS status;
