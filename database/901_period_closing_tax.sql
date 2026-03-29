-- =============================================================================
-- FILE: 901_period_closing_tax.sql
-- PURPOSE: Phase 2 - Period-End Closing & Tax Accounting (VAT/GST)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: GAAP, Tax Compliance
-- DEPENDENCIES: 900_chart_of_accounts.sql, 012_sales_transaction.sql
-- =============================================================================

-- =============================================================================
-- FISCAL PERIODS
-- =============================================================================

CREATE TABLE kernel.fiscal_periods (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    period_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Period Definition
    fiscal_year INTEGER NOT NULL,
    period_number INTEGER NOT NULL,  -- 1-12 for months, 1-4 for quarters
    period_type VARCHAR(16) NOT NULL CHECK (period_type IN ('month', 'quarter', 'year')),
    period_name TEXT NOT NULL,  -- e.g., "January 2024", "Q1 2024"
    
    -- Dates
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    
    -- Status
    is_closed BOOLEAN DEFAULT FALSE,
    closed_at TIMESTAMP WITH TIME ZONE,
    closed_by UUID,
    closing_notes TEXT,
    
    -- Validation
    is_validated BOOLEAN DEFAULT FALSE,
    validated_at TIMESTAMP WITH TIME ZONE,
    validated_by UUID,
    validation_errors JSONB,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(tenant_id, fiscal_year, period_number, period_type)
);

CREATE INDEX idx_fiscal_periods_tenant ON kernel.fiscal_periods(tenant_id, fiscal_year, period_number);
CREATE INDEX idx_fiscal_periods_dates ON kernel.fiscal_periods(start_date, end_date);
CREATE INDEX idx_fiscal_periods_open ON kernel.fiscal_periods(tenant_id, is_closed) WHERE is_closed = FALSE;

-- =============================================================================
-- TAX RATES
-- =============================================================================

CREATE TABLE kernel.tax_rates (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    tax_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Tax Definition
    tax_code TEXT NOT NULL,  -- e.g., "VAT-20", "GST-10"
    tax_name TEXT NOT NULL,  -- e.g., "Standard VAT", "Reduced VAT"
    tax_type VARCHAR(32) NOT NULL CHECK (tax_type IN ('VAT', 'GST', 'SalesTax', 'ConsumptionTax')),
    
    -- Rate
    rate DECIMAL(5, 4) NOT NULL,  -- e.g., 0.20 for 20%
    
    -- Applicability
    country_code VARCHAR(2),  -- ISO 3166-1
    region_code TEXT,  -- State/Province
    product_category TEXT,  -- e.g., "insurance", "repair", "goods"
    
    -- Validity (bitemporal)
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to DATE,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_default BOOLEAN DEFAULT FALSE,
    
    -- GL Account mapping
    output_tax_account_code TEXT,  -- Tax liability account
    input_tax_account_code TEXT,   -- Tax recoverable account
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(tenant_id, tax_code, valid_from)
);

CREATE INDEX idx_tax_rates_tenant ON kernel.tax_rates(tenant_id, is_active);
CREATE INDEX idx_tax_rates_country ON kernel.tax_rates(country_code, tax_type, is_active);
CREATE INDEX idx_tax_rates_valid ON kernel.tax_rates(valid_from, valid_to);

-- =============================================================================
-- TAX TRANSACTIONS
-- =============================================================================

CREATE TABLE kernel.tax_transactions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    tax_transaction_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Source Document
    source_type VARCHAR(32) NOT NULL,  -- 'sales_order', 'repair_order', 'purchase', 'claim_payout'
    source_id UUID NOT NULL,
    
    -- Tax Details
    tax_id UUID NOT NULL REFERENCES kernel.tax_rates(tax_id),
    tax_code TEXT NOT NULL,
    tax_rate DECIMAL(5, 4) NOT NULL,
    
    -- Amounts
    taxable_amount DECIMAL(15, 2) NOT NULL,
    tax_amount DECIMAL(15, 2) NOT NULL,
    total_amount DECIMAL(15, 2) NOT NULL,
    
    -- Direction
    is_output_tax BOOLEAN DEFAULT TRUE,  -- TRUE = collected (sales), FALSE = paid (purchases)
    
    -- Currency
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    -- Status
    is_reported BOOLEAN DEFAULT FALSE,
    reported_period_id UUID,
    
    -- GL Movement link
    value_movement_id UUID,
    
    transaction_date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_tax_transactions_tenant ON kernel.tax_transactions(tenant_id, transaction_date);
CREATE INDEX idx_tax_transactions_source ON kernel.tax_transactions(source_type, source_id);
CREATE INDEX idx_tax_transactions_unreported ON kernel.tax_transactions(tenant_id, is_output_tax, is_reported) WHERE is_reported = FALSE;

-- =============================================================================
-- EXTEND DOMAIN TABLES WITH TAX COLUMNS
-- =============================================================================

-- Extend sales_orders
ALTER TABLE kernel.sales_orders 
    ADD COLUMN IF NOT EXISTS taxable_amount DECIMAL(12, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS tax_amount DECIMAL(12, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS tax_rate DECIMAL(5, 4) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS tax_id UUID REFERENCES kernel.tax_rates(tax_id);

-- Extend repair_orders  
ALTER TABLE kernel.repair_orders
    ADD COLUMN IF NOT EXISTS taxable_amount DECIMAL(12, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS tax_amount DECIMAL(12, 2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS tax_rate DECIMAL(5, 4) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS tax_id UUID REFERENCES kernel.tax_rates(tax_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create Fiscal Year
CREATE OR REPLACE FUNCTION kernel.create_fiscal_year(
    p_tenant_id UUID,
    p_year INTEGER,
    p_start_month INTEGER DEFAULT 1
)
RETURNS INTEGER AS $$
DECLARE
    v_month INTEGER;
    v_start_date DATE;
    v_end_date DATE;
BEGIN
    FOR v_month IN 1..12 LOOP
        v_start_date := make_date(p_year, v_month, 1);
        v_end_date := (v_start_date + INTERVAL '1 month' - INTERVAL '1 day')::DATE;
        
        INSERT INTO kernel.fiscal_periods (
            tenant_id, fiscal_year, period_number, period_type,
            period_name, start_date, end_date
        ) VALUES (
            p_tenant_id, p_year, v_month, 'month',
            to_char(v_start_date, 'Month YYYY'),
            v_start_date, v_end_date
        )
        ON CONFLICT (tenant_id, fiscal_year, period_number, period_type) DO NOTHING;
    END LOOP;
    
    -- Create quarters
    INSERT INTO kernel.fiscal_periods (tenant_id, fiscal_year, period_number, period_type, period_name, start_date, end_date)
    VALUES 
        (p_tenant_id, p_year, 1, 'quarter', 'Q1 ' || p_year, make_date(p_year, 1, 1), make_date(p_year, 3, 31)),
        (p_tenant_id, p_year, 2, 'quarter', 'Q2 ' || p_year, make_date(p_year, 4, 1), make_date(p_year, 6, 30)),
        (p_tenant_id, p_year, 3, 'quarter', 'Q3 ' || p_year, make_date(p_year, 7, 1), make_date(p_year, 9, 30)),
        (p_tenant_id, p_year, 4, 'quarter', 'Q4 ' || p_year, make_date(p_year, 10, 1), make_date(p_year, 12, 31))
    ON CONFLICT (tenant_id, fiscal_year, period_number, period_type) DO NOTHING;
    
    -- Create year
    INSERT INTO kernel.fiscal_periods (tenant_id, fiscal_year, period_number, period_type, period_name, start_date, end_date)
    VALUES (p_tenant_id, p_year, 1, 'year', 'FY ' || p_year, make_date(p_year, 1, 1), make_date(p_year, 12, 31))
    ON CONFLICT (tenant_id, fiscal_year, period_number, period_type) DO NOTHING;
    
    RETURN 17; -- 12 months + 4 quarters + 1 year
END;
$$ LANGUAGE plpgsql;

-- Close Period
CREATE OR REPLACE FUNCTION kernel.close_period(
    p_tenant_id UUID,
    p_period_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
    v_period RECORD;
    v_unposted_movements INTEGER;
    v_validation_errors JSONB := '[]'::JSONB;
BEGIN
    SELECT * INTO v_period FROM kernel.fiscal_periods WHERE period_id = p_period_id;
    
    -- Check if already closed
    IF v_period.is_closed THEN
        RAISE EXCEPTION 'Period is already closed';
    END IF;
    
    -- Check for unposted movements
    SELECT COUNT(*) INTO v_unposted_movements
    FROM kernel.value_movements vm
    JOIN kernel.movement_legs ml ON vm.movement_id = ml.movement_id
    JOIN kernel.movement_postings mp ON ml.leg_id = mp.leg_id
    WHERE vm.tenant_id = p_tenant_id
      AND mp.posted_at::DATE BETWEEN v_period.start_date AND v_period.end_date
      AND vm.status != 'posted';
    
    IF v_unposted_movements > 0 THEN
        v_validation_errors := v_validation_errors || jsonb_build_object('error', 'Unposted movements exist', 'count', v_unposted_movements);
    END IF;
    
    -- Check trial balance
    IF EXISTS (SELECT 1 FROM kernel.get_trial_balance(p_tenant_id, v_period.end_date) WHERE debit_balance != credit_balance) THEN
        v_validation_errors := v_validation_errors || jsonb_build_object('error', 'Trial balance is not balanced');
    END IF;
    
    -- If validation errors, don't close
    IF jsonb_array_length(v_validation_errors) > 0 THEN
        UPDATE kernel.fiscal_periods
        SET is_validated = FALSE,
            validation_errors = v_validation_errors
        WHERE period_id = p_period_id;
        RETURN FALSE;
    END IF;
    
    -- Calculate and store account balances
    INSERT INTO kernel.account_balances (
        account_id, tenant_id, fiscal_year, period_number, period_type,
        period_start_date, period_end_date, opening_balance, period_debits, period_credits
    )
    SELECT 
        coa.account_id,
        p_tenant_id,
        v_period.fiscal_year,
        v_period.period_number,
        v_period.period_type,
        v_period.start_date,
        v_period.end_date,
        COALESCE(prev.closing_balance, 0),
        COALESCE(SUM(CASE WHEN ml.direction = 'debit' THEN ml.amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN ml.direction = 'credit' THEN ml.amount ELSE 0 END), 0)
    FROM kernel.chart_of_accounts coa
    LEFT JOIN kernel.value_containers vc ON vc.coa_code = coa.account_code AND vc.tenant_id = p_tenant_id
    LEFT JOIN kernel.movement_legs ml ON ml.container_id = vc.container_id
    LEFT JOIN kernel.movement_postings mp ON mp.leg_id = ml.leg_id
    LEFT JOIN kernel.account_balances prev ON prev.account_id = coa.account_id 
        AND prev.fiscal_year = v_period.fiscal_year 
        AND prev.period_number = v_period.period_number - 1
    WHERE coa.tenant_id = p_tenant_id
      AND mp.posted_at::DATE BETWEEN v_period.start_date AND v_period.end_date
    GROUP BY coa.account_id, prev.closing_balance
    ON CONFLICT (account_id, fiscal_year, period_number, period_type) DO UPDATE SET
        opening_balance = EXCLUDED.opening_balance,
        period_debits = EXCLUDED.period_debits,
        period_credits = EXCLUDED.period_credits;
    
    -- Mark period as closed
    UPDATE kernel.fiscal_periods
    SET is_closed = TRUE,
        closed_at = NOW(),
        closed_by = security.get_participant_context(),
        is_validated = TRUE,
        validated_at = NOW(),
        validated_by = security.get_participant_context()
    WHERE period_id = p_period_id;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Calculate Tax on Sales Order
CREATE OR REPLACE FUNCTION kernel.calculate_order_tax(
    p_order_id UUID,
    p_order_type VARCHAR,  -- 'sales' or 'repair'
    p_country_code VARCHAR,
    p_product_category VARCHAR
)
RETURNS TABLE (tax_id UUID, tax_rate DECIMAL, tax_amount DECIMAL) AS $$
DECLARE
    v_subtotal DECIMAL;
    v_tax_rate RECORD;
BEGIN
    -- Get order subtotal
    IF p_order_type = 'sales' THEN
        SELECT subtotal_amount INTO v_subtotal FROM kernel.sales_orders WHERE sales_order_id = p_order_id;
    ELSE
        SELECT estimated_cost INTO v_subtotal FROM kernel.repair_orders WHERE repair_order_id = p_order_id;
    END IF;
    
    -- Find applicable tax rate
    SELECT tr.tax_id, tr.rate, tr.tax_code INTO v_tax_rate
    FROM kernel.tax_rates tr
    WHERE tr.country_code = p_country_code
      AND (tr.product_category = p_product_category OR tr.product_category IS NULL)
      AND tr.is_active = TRUE
      AND tr.valid_from <= CURRENT_DATE
      AND (tr.valid_to IS NULL OR tr.valid_to >= CURRENT_DATE)
    ORDER BY tr.is_default DESC, tr.valid_from DESC
    LIMIT 1;
    
    IF v_tax_rate IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, 0::DECIMAL, 0::DECIMAL;
        RETURN;
    END IF;
    
    RETURN QUERY SELECT v_tax_rate.tax_id, v_tax_rate.rate, ROUND(v_subtotal * v_tax_rate.rate, 2);
END;
$$ LANGUAGE plpgsql;

-- Generate Tax Report
CREATE OR REPLACE FUNCTION kernel.generate_tax_report(
    p_tenant_id UUID,
    p_start_date DATE,
    p_end_date DATE
)
RETURNS TABLE (
    tax_code TEXT,
    tax_name TEXT,
    output_tax DECIMAL,
    input_tax DECIMAL,
    net_tax DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        tt.tax_code,
        MAX(tr.tax_name) AS tax_name,
        COALESCE(SUM(CASE WHEN tt.is_output_tax THEN tt.tax_amount ELSE 0 END), 0) AS output_tax,
        COALESCE(SUM(CASE WHEN NOT tt.is_output_tax THEN tt.tax_amount ELSE 0 END), 0) AS input_tax,
        COALESCE(SUM(CASE WHEN tt.is_output_tax THEN tt.tax_amount ELSE -tt.tax_amount END), 0) AS net_tax
    FROM kernel.tax_transactions tt
    JOIN kernel.tax_rates tr ON tt.tax_id = tr.tax_id
    WHERE tt.tenant_id = p_tenant_id
      AND tt.transaction_date BETWEEN p_start_date AND p_end_date
    GROUP BY tt.tax_code
    ORDER BY tt.tax_code;
END;
$$ LANGUAGE plpgsql;

-- Post Tax Movement (creates value movement for tax)
CREATE OR REPLACE FUNCTION kernel.post_tax_movement(
    p_tax_transaction_id UUID
)
RETURNS UUID AS $$
DECLARE
    v_tax_txn RECORD;
    v_movement_id UUID;
    v_tax_account TEXT;
BEGIN
    SELECT * INTO v_tax_txn FROM kernel.tax_transactions WHERE tax_transaction_id = p_tax_transaction_id;
    
    -- Get tax account
    SELECT CASE WHEN v_tax_txn.is_output_tax THEN output_tax_account_code ELSE input_tax_account_code END
    INTO v_tax_account
    FROM kernel.tax_rates
    WHERE tax_id = v_tax_txn.tax_id;
    
    -- Create movement for tax
    -- This would link to the existing value_movements infrastructure
    -- For now, just mark as processed
    UPDATE kernel.tax_transactions
    SET value_movement_id = v_movement_id
    WHERE tax_transaction_id = p_tax_transaction_id;
    
    RETURN v_movement_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SEED TAX RATES
-- =============================================================================

-- UK VAT Rates
INSERT INTO kernel.tax_rates (tenant_id, tax_code, tax_name, tax_type, rate, country_code, product_category, output_tax_account_code, input_tax_account_code, is_default) VALUES
    (NULL, 'VAT-20', 'Standard VAT 20%', 'VAT', 0.20, 'GB', NULL, '2140', '2140', TRUE),
    (NULL, 'VAT-5', 'Reduced VAT 5%', 'VAT', 0.05, 'GB', 'repair', '2140', '2140', FALSE),
    (NULL, 'VAT-0', 'Zero-rated VAT', 'VAT', 0.00, 'GB', 'insurance', '2140', '2140', FALSE)
ON CONFLICT (tenant_id, tax_code, valid_from) DO NOTHING;

-- US Sales Tax (simplified)
INSERT INTO kernel.tax_rates (tenant_id, tax_code, tax_name, tax_type, rate, country_code, region_code, output_tax_account_code, input_tax_account_code) VALUES
    (NULL, 'SST-8', 'Sales Tax 8%', 'SalesTax', 0.08, 'US', 'CA', '2140', '2140'),
    (NULL, 'SST-7', 'Sales Tax 7%', 'SalesTax', 0.07, 'US', 'NY', '2140', '2140')
ON CONFLICT (tenant_id, tax_code, valid_from) DO NOTHING;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Phase 2: Period-End Closing & Tax Accounting initialized' AS status;
