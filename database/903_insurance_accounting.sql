-- =============================================================================
-- FILE: 903_insurance_accounting.sql
-- PURPOSE: Phase 4 - IFRS 17 Insurance Contract Accounting (Simplified)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: IFRS 17 (Insurance Contracts)
-- DEPENDENCIES: 010_insurance_policy.sql, 900_chart_of_accounts.sql
-- =============================================================================

-- =============================================================================
-- EXTEND INSURANCE POLICIES WITH ACCOUNTING FIELDS
-- =============================================================================

ALTER TABLE kernel.insurance_policies 
    ADD COLUMN IF NOT EXISTS premium_earned_to_date DECIMAL(15, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS unearned_premium_reserve DECIMAL(15, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS claim_reserve DECIMAL(15, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS risk_adjustment DECIMAL(15, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS csm_amortized DECIMAL(15, 2) DEFAULT 0,  -- Contractual Service Margin
    ADD COLUMN IF NOT EXISTS acquisition_costs_deferred DECIMAL(15, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_accounting_run DATE;

-- =============================================================================
-- INSURANCE LIABILITY MOVEMENTS
-- =============================================================================

CREATE TABLE kernel.insurance_liability_movements (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    movement_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Source
    policy_id UUID NOT NULL REFERENCES kernel.insurance_policies(policy_id),
    claim_id UUID REFERENCES kernel.claims(claim_id),
    
    -- Movement Type
    movement_type VARCHAR(32) NOT NULL CHECK (movement_type IN (
        'premium_received',
        'premium_earning',
        'claim_incurred',
        'claim_paid',
        'reserve_change',
        'csm_amortization',
        'acquisition_cost_amortization'
    )),
    
    -- Amounts
    amount DECIMAL(15, 2) NOT NULL,
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    -- Accounting Impact
    debit_account_code TEXT,  -- COA account debited
    credit_account_code TEXT, -- COA account credited
    
    -- Period
    accounting_period DATE NOT NULL,  -- Month-end date
    fiscal_year INTEGER,
    period_number INTEGER,
    
    -- Link to value movement (if posted to GL)
    value_movement_id UUID REFERENCES kernel.value_movements(movement_id),
    
    -- Calculation basis
    calculation_method TEXT,  -- e.g., 'time_apportionment', 'sum_insured_proportion'
    calculation_details JSONB,  -- Store calculation inputs
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID
);

CREATE INDEX idx_insurance_liability_policy ON kernel.insurance_liability_movements(policy_id, accounting_period);
CREATE INDEX idx_insurance_liability_type ON kernel.insurance_liability_movements(movement_type, accounting_period);
CREATE INDEX idx_insurance_liability_period ON kernel.insurance_liability_movements(tenant_id, fiscal_year, period_number);

-- =============================================================================
-- PREMIUM EARNING SCHEDULE
-- =============================================================================

CREATE TABLE kernel.premium_earning_schedules (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    schedule_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    policy_id UUID NOT NULL REFERENCES kernel.insurance_policies(policy_id),
    
    -- Period
    earning_period DATE NOT NULL,  -- Month being earned
    fiscal_year INTEGER,
    period_number INTEGER,
    
    -- Amounts
    premium_amount DECIMAL(15, 2) NOT NULL,
    earned_amount DECIMAL(15, 2) NOT NULL,
    unearned_amount DECIMAL(15, 2) NOT NULL,
    
    -- Method
    earning_method VARCHAR(32) DEFAULT 'straight_line',  -- or 'sum_insured', 'exposure'
    
    -- Status
    is_posted BOOLEAN DEFAULT FALSE,
    posted_at TIMESTAMP WITH TIME ZONE,
    
    UNIQUE(policy_id, earning_period)
);

CREATE INDEX idx_premium_schedule_policy ON kernel.premium_earning_schedules(policy_id, earning_period);

-- =============================================================================
-- CLAIM RESERVE MOVEMENTS
-- =============================================================================

CREATE TABLE kernel.claim_reserve_movements (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    reserve_movement_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    claim_id UUID NOT NULL REFERENCES kernel.claims(claim_id),
    policy_id UUID NOT NULL REFERENCES kernel.insurance_policies(policy_id),
    
    -- Reserve Type
    reserve_type VARCHAR(32) NOT NULL DEFAULT 'case_reserve' CHECK (reserve_type IN ('case_reserve', 'ibnr', 'uep_reserve')),
    
    -- Amounts
    reserve_amount DECIMAL(15, 2) NOT NULL,  -- New reserve amount
    reserve_change DECIMAL(15, 2) NOT NULL,  -- Change from previous
    
    -- Basis
    estimation_basis TEXT,  -- e.g., 'adjuster_estimate', 'actuarial_model'
    confidence_level DECIMAL(5, 2),  -- e.g., 0.75 for 75% confidence
    
    -- Period
    valuation_date DATE NOT NULL,
    
    -- Link to liability movement
    liability_movement_id UUID REFERENCES kernel.insurance_liability_movements(movement_id),
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_claim_reserve_claim ON kernel.claim_reserve_movements(claim_id, valuation_date DESC);
CREATE INDEX idx_claim_reserve_policy ON kernel.claim_reserve_movements(policy_id, valuation_date DESC);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Calculate Premium Earning for Period
CREATE OR REPLACE FUNCTION kernel.calculate_premium_earning(
    p_policy_id UUID,
    p_as_of_date DATE
)
RETURNS TABLE (
    period_start DATE,
    period_end DATE,
    days_in_period INTEGER,
    days_earned INTEGER,
    earned_amount DECIMAL
) AS $$
DECLARE
    v_policy RECORD;
    v_total_days INTEGER;
    v_daily_premium DECIMAL;
BEGIN
    SELECT * INTO v_policy FROM kernel.insurance_policies WHERE policy_id = p_policy_id;
    
    IF v_policy IS NULL THEN
        RETURN;
    END IF;
    
    v_total_days := GREATEST(v_policy.effective_end_date - v_policy.effective_start_date, 1);
    v_daily_premium := v_policy.premium_amount / NULLIF(v_total_days, 0);
    
    RETURN QUERY
    WITH months AS (
        SELECT 
            generate_series(
                DATE_TRUNC('month', v_policy.effective_start_date)::DATE,
                DATE_TRUNC('month', LEAST(p_as_of_date, v_policy.effective_end_date))::DATE,
                INTERVAL '1 month'
            )::DATE AS month_start
    )
    SELECT 
        m.month_start AS period_start,
        (m.month_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS period_end,
        (m.month_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE - m.month_start + 1 AS days_in_period,
        GREATEST(LEAST((m.month_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE, p_as_of_date, v_policy.effective_end_date) - 
                 GREATEST(m.month_start, v_policy.effective_start_date) + 1, 0) AS days_earned,
        ROUND(v_daily_premium * GREATEST(LEAST((m.month_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE, p_as_of_date, v_policy.effective_end_date) - 
                 GREATEST(m.month_start, v_policy.effective_start_date) + 1, 0), 2) AS earned_amount
    FROM months m
    WHERE m.month_start <= p_as_of_date;
END;
$$ LANGUAGE plpgsql;

-- Post Premium Earning
CREATE OR REPLACE FUNCTION kernel.post_premium_earning(
    p_policy_id UUID,
    p_as_of_date DATE
)
RETURNS DECIMAL AS $$
DECLARE
    v_policy RECORD;
    v_earning RECORD;
    v_total_earned DECIMAL := 0;
    v_movement_id UUID;
    v_unearned_account TEXT := '2120';  -- Unearned Premium Reserve
    v_revenue_account TEXT := '4100';   -- Insurance Premium Revenue
BEGIN
    SELECT * INTO v_policy FROM kernel.insurance_policies WHERE policy_id = p_policy_id;
    
    IF v_policy IS NULL OR v_policy.status != 'active' THEN
        RETURN 0;
    END IF;
    
    -- Process each month's earning
    FOR v_earning IN SELECT * FROM kernel.calculate_premium_earning(p_policy_id, p_as_of_date)
    LOOP
        -- Check if already posted
        IF EXISTS (SELECT 1 FROM kernel.premium_earning_schedules 
                   WHERE policy_id = p_policy_id AND earning_period = v_earning.period_start AND is_posted = TRUE) THEN
            CONTINUE;
        END IF;
        
        -- Insert schedule
        INSERT INTO kernel.premium_earning_schedules (
            policy_id, earning_period, premium_amount, earned_amount, unearned_amount,
            fiscal_year, period_number
        ) VALUES (
            p_policy_id, v_earning.period_start, v_policy.premium_amount, 
            v_earning.earned_amount, v_policy.premium_amount - v_earning.earned_amount,
            EXTRACT(YEAR FROM v_earning.period_start), EXTRACT(MONTH FROM v_earning.period_start)
        )
        ON CONFLICT (policy_id, earning_period) DO UPDATE SET
            earned_amount = EXCLUDED.earned_amount,
            unearned_amount = EXCLUDED.unearned_amount;
        
        v_total_earned := v_total_earned + v_earning.earned_amount;
    END LOOP;
    
    -- Create liability movement
    INSERT INTO kernel.insurance_liability_movements (
        tenant_id, policy_id, movement_type, amount, accounting_period,
        debit_account_code, credit_account_code, fiscal_year, period_number
    ) VALUES (
        v_policy.tenant_id, p_policy_id, 'premium_earning', v_total_earned, p_as_of_date,
        v_unearned_account, v_revenue_account, EXTRACT(YEAR FROM p_as_of_date), EXTRACT(MONTH FROM p_as_of_date)
    )
    RETURNING movement_id INTO v_movement_id;
    
    -- Update policy totals
    UPDATE kernel.insurance_policies
    SET premium_earned_to_date = premium_earned_to_date + v_total_earned,
        unearned_premium_reserve = premium_amount - (premium_earned_to_date + v_total_earned),
        last_accounting_run = p_as_of_date
    WHERE policy_id = p_policy_id;
    
    RETURN v_total_earned;
END;
$$ LANGUAGE plpgsql;

-- Calculate Claim Reserve
CREATE OR REPLACE FUNCTION kernel.calculate_claim_reserve(
    p_claim_id UUID,
    p_valuation_date DATE
)
RETURNS DECIMAL AS $$
DECLARE
    v_claim RECORD;
    v_policy RECORD;
    v_reserve DECIMAL;
    v_previous_reserve DECIMAL;
    v_change DECIMAL;
BEGIN
    SELECT * INTO v_claim FROM kernel.claims WHERE claim_id = p_claim_id;
    SELECT * INTO v_policy FROM kernel.insurance_policies WHERE policy_id = v_claim.policy_id;
    
    IF v_claim IS NULL THEN
        RETURN 0;
    END IF;
    
    -- If claim is paid/closed, reserve is 0
    IF v_claim.status IN ('paid', 'closed', 'denied') THEN
        v_reserve := 0;
    -- If claim is approved, use approved amount
    ELSIF v_claim.status = 'approved' AND v_claim.approved_amount IS NOT NULL THEN
        v_reserve := v_claim.approved_amount - COALESCE(v_claim.actual_payout_amount, 0);
    -- If under review, use assessed amount or estimate
    ELSIF v_claim.assessed_amount IS NOT NULL THEN
        v_reserve := v_claim.assessed_amount;
    ELSE
        -- Default estimate: average claim amount for this policy type
        v_reserve := v_policy.coverage_limit * 0.1;  -- 10% of coverage as rough estimate
    END IF;
    
    v_reserve := GREATEST(v_reserve, 0);
    
    -- Get previous reserve
    SELECT reserve_amount INTO v_previous_reserve
    FROM kernel.claim_reserve_movements
    WHERE claim_id = p_claim_id
    ORDER BY valuation_date DESC
    LIMIT 1;
    
    v_change := v_reserve - COALESCE(v_previous_reserve, 0);
    
    -- Record reserve movement
    IF v_change != 0 OR v_previous_reserve IS NULL THEN
        INSERT INTO kernel.claim_reserve_movements (
            claim_id, policy_id, reserve_type, reserve_amount, reserve_change,
            valuation_date, estimation_basis
        ) VALUES (
            p_claim_id, v_claim.policy_id, 'case_reserve', v_reserve, v_change,
            p_valuation_date, COALESCE(v_claim.assessment_notes, 'Estimated')
        );
    END IF;
    
    RETURN v_reserve;
END;
$$ LANGUAGE plpgsql;

-- Run Insurance Accounting for Tenant
CREATE OR REPLACE FUNCTION kernel.run_insurance_accounting(
    p_tenant_id UUID,
    p_as_of_date DATE
)
RETURNS TABLE (
    policies_processed INTEGER,
    total_premium_earned DECIMAL,
    claims_processed INTEGER,
    total_reserves DECIMAL
) AS $$
DECLARE
    v_policies_processed INTEGER := 0;
    v_total_premium_earned DECIMAL := 0;
    v_claims_processed INTEGER := 0;
    v_total_reserves DECIMAL := 0;
    v_policy RECORD;
    v_claim RECORD;
    v_earned DECIMAL;
    v_reserve DECIMAL;
BEGIN
    -- Process premium earning for all active policies
    FOR v_policy IN 
        SELECT * FROM kernel.insurance_policies 
        WHERE tenant_id = p_tenant_id 
          AND status = 'active'
          AND effective_start_date <= p_as_of_date
          AND effective_end_date >= p_as_of_date
    LOOP
        v_earned := kernel.post_premium_earning(v_policy.policy_id, p_as_of_date);
        v_total_premium_earned := v_total_premium_earned + COALESCE(v_earned, 0);
        v_policies_processed := v_policies_processed + 1;
    END LOOP;
    
    -- Process claim reserves for all open claims
    FOR v_claim IN 
        SELECT * FROM kernel.claims 
        WHERE policy_id IN (SELECT policy_id FROM kernel.insurance_policies WHERE tenant_id = p_tenant_id)
          AND status IN ('filed', 'under_review', 'approved')
    LOOP
        v_reserve := kernel.calculate_claim_reserve(v_claim.claim_id, p_as_of_date);
        v_total_reserves := v_total_reserves + COALESCE(v_reserve, 0);
        v_claims_processed := v_claims_processed + 1;
    END LOOP;
    
    RETURN QUERY SELECT v_policies_processed, v_total_premium_earned, v_claims_processed, v_total_reserves;
END;
$$ LANGUAGE plpgsql;

-- Get Insurance Financial Summary
CREATE OR REPLACE FUNCTION kernel.get_insurance_financial_summary(
    p_tenant_id UUID,
    p_as_of_date DATE
)
RETURNS TABLE (
    metric_name TEXT,
    metric_value DECIMAL,
    currency_code VARCHAR
) AS $$
BEGIN
    -- Gross Written Premium
    RETURN QUERY SELECT 
        'Gross Written Premium'::TEXT,
        COALESCE(SUM(premium_amount), 0),
        'USD'::VARCHAR
    FROM kernel.insurance_policies
    WHERE tenant_id = p_tenant_id
      AND effective_start_date <= p_as_of_date;
    
    -- Gross Earned Premium
    RETURN QUERY SELECT 
        'Gross Earned Premium'::TEXT,
        COALESCE(SUM(premium_earned_to_date), 0),
        'USD'::VARCHAR
    FROM kernel.insurance_policies
    WHERE tenant_id = p_tenant_id;
    
    -- Unearned Premium Reserve
    RETURN QUERY SELECT 
        'Unearned Premium Reserve'::TEXT,
        COALESCE(SUM(unearned_premium_reserve), 0),
        'USD'::VARCHAR
    FROM kernel.insurance_policies
    WHERE tenant_id = p_tenant_id
      AND status = 'active';
    
    -- Claim Reserve
    RETURN QUERY SELECT 
        'Claim Reserve'::TEXT,
        COALESCE(SUM(claim_reserve), 0),
        'USD'::VARCHAR
    FROM kernel.insurance_policies
    WHERE tenant_id = p_tenant_id;
    
    -- Total Claims Incurred
    RETURN QUERY SELECT 
        'Total Claims Incurred'::TEXT,
        COALESCE(SUM(approved_amount), 0),
        'USD'::VARCHAR
    FROM kernel.claims
    WHERE policy_id IN (SELECT policy_id FROM kernel.insurance_policies WHERE tenant_id = p_tenant_id)
      AND status IN ('approved', 'paid');
    
    -- Loss Ratio
    RETURN QUERY SELECT 
        'Loss Ratio %'::TEXT,
        CASE 
            WHEN COALESCE(SUM(p.premium_earned_to_date), 0) = 0 THEN 0
            ELSE ROUND(COALESCE(SUM(c.approved_amount), 0) / NULLIF(SUM(p.premium_earned_to_date), 0) * 100, 2)
        END,
        'USD'::VARCHAR
    FROM kernel.insurance_policies p
    LEFT JOIN kernel.claims c ON p.policy_id = c.policy_id AND c.status IN ('approved', 'paid')
    WHERE p.tenant_id = p_tenant_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Phase 4: IFRS 17 Insurance Accounting initialized' AS status;
