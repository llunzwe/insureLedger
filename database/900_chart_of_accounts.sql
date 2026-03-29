-- =============================================================================
-- FILE: 900_chart_of_accounts.sql
-- PURPOSE: Phase 1 - Chart of Accounts (COA) & Financial Reporting
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: GAAP/IFRS, Double-Entry Accounting
-- DEPENDENCIES: 007_value_containers.sql, 008_value_movements.sql
-- =============================================================================

-- =============================================================================
-- CHART OF ACCOUNTS - Hierarchical GL Structure
-- =============================================================================

CREATE TABLE kernel.chart_of_accounts (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    -- Account Identity
    account_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    account_code TEXT NOT NULL,  -- e.g., "1000", "2100", "4100"
    account_name TEXT NOT NULL,
    account_description TEXT,
    
    -- Account Type (per accounting equation)
    account_type VARCHAR(32) NOT NULL CHECK (account_type IN ('asset', 'liability', 'equity', 'income', 'expense')),
    normal_balance VARCHAR(6) NOT NULL CHECK (normal_balance IN ('debit', 'credit')),
    
    -- Hierarchy (LTREE for efficient tree queries)
    parent_account_code TEXT,
    account_path LTREE,
    account_level INTEGER DEFAULT 1,
    
    -- Financial Statement Mapping
    financial_statement VARCHAR(32) NOT NULL CHECK (financial_statement IN ('balance_sheet', 'income_statement', 'cash_flow')),
    statement_section TEXT,  -- e.g., "Current Assets", "Revenue", "Operating Expenses"
    statement_order INTEGER,  -- For ordering on statements
    
    -- Account Classification
    is_bank_account BOOLEAN DEFAULT FALSE,
    is_control_account BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Validity
    valid_from DATE DEFAULT CURRENT_DATE,
    valid_to DATE,
    
    -- Audit
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    signature TEXT,
    proof_inclusion UUID,
    
    UNIQUE(tenant_id, account_code)
);

COMMENT ON TABLE kernel.chart_of_accounts IS 'General Ledger Chart of Accounts with hierarchical structure';

-- Indexes for COA
CREATE INDEX idx_coa_account ON kernel.chart_of_accounts(account_id);
CREATE INDEX idx_coa_code ON kernel.chart_of_accounts(tenant_id, account_code);
CREATE INDEX idx_coa_type ON kernel.chart_of_accounts(tenant_id, account_type, account_code);
CREATE INDEX idx_coa_path ON kernel.chart_of_accounts USING GIST(account_path);
CREATE INDEX idx_coa_parent ON kernel.chart_of_accounts(parent_account_code);
CREATE INDEX idx_coa_statement ON kernel.chart_of_accounts(tenant_id, financial_statement, statement_order);

-- =============================================================================
-- ACCOUNT BALANCES - Period-end aggregated balances
-- =============================================================================

CREATE TABLE kernel.account_balances (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    -- Identity
    account_id UUID NOT NULL REFERENCES kernel.chart_of_accounts(account_id),
    tenant_id UUID,
    
    -- Period
    fiscal_year INTEGER NOT NULL,
    period_number INTEGER NOT NULL,  -- 1-12 for months, or quarter number
    period_type VARCHAR(16) NOT NULL CHECK (period_type IN ('month', 'quarter', 'year')),
    period_start_date DATE NOT NULL,
    period_end_date DATE NOT NULL,
    
    -- Balances
    opening_balance DECIMAL(24, 6) NOT NULL DEFAULT 0,
    period_debits DECIMAL(24, 6) NOT NULL DEFAULT 0,
    period_credits DECIMAL(24, 6) NOT NULL DEFAULT 0,
    closing_balance DECIMAL(24, 6) GENERATED ALWAYS AS (opening_balance + period_debits - period_credits) STORED,
    
    -- Currency
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    -- Status
    is_closed BOOLEAN DEFAULT FALSE,
    closed_at TIMESTAMP WITH TIME ZONE,
    closed_by UUID,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(account_id, fiscal_year, period_number, period_type)
);

CREATE INDEX idx_account_balances_period ON kernel.account_balances(tenant_id, fiscal_year, period_number);
CREATE INDEX idx_account_balances_account ON kernel.account_balances(account_id, period_end_date DESC);

-- =============================================================================
-- TRIAL BALANCE SNAPSHOTS
-- =============================================================================

CREATE TABLE kernel.trial_balances (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    trial_balance_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Period
    fiscal_year INTEGER NOT NULL,
    period_number INTEGER NOT NULL,
    period_type VARCHAR(16) NOT NULL,
    as_of_date DATE NOT NULL,
    
    -- Summary
    total_debits DECIMAL(24, 6) NOT NULL DEFAULT 0,
    total_credits DECIMAL(24, 6) NOT NULL DEFAULT 0,
    difference DECIMAL(24, 6) GENERATED ALWAYS AS (total_debits - total_credits) STORED,
    is_balanced BOOLEAN GENERATED ALWAYS AS (ABS(total_debits - total_credits) <= 0.01) STORED,
    
    -- Detail (JSON array of account balances)
    account_balances JSONB DEFAULT '[]',
    
    generated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    generated_by UUID,
    
    UNIQUE(tenant_id, fiscal_year, period_number, period_type)
);

CREATE INDEX idx_trial_balances_period ON kernel.trial_balances(tenant_id, fiscal_year, period_number);

-- =============================================================================
-- LINK VALUE CONTAINERS TO COA
-- =============================================================================

-- Add coa_code to value_containers
ALTER TABLE kernel.value_containers 
    ADD COLUMN IF NOT EXISTS coa_code TEXT,
    ADD COLUMN IF NOT EXISTS account_id UUID REFERENCES kernel.chart_of_accounts(account_id);

-- Create index
CREATE INDEX IF NOT EXISTS idx_value_containers_coa ON kernel.value_containers(coa_code);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create Chart of Accounts entry
CREATE OR REPLACE FUNCTION kernel.create_coa_account(
    p_tenant_id UUID,
    p_account_code TEXT,
    p_account_name TEXT,
    p_account_type VARCHAR,
    p_normal_balance VARCHAR,
    p_financial_statement VARCHAR,
    p_parent_code TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_account_id UUID;
    v_path LTREE;
BEGIN
    -- Calculate path
    IF p_parent_code IS NOT NULL THEN
        SELECT account_path INTO v_path FROM kernel.chart_of_accounts 
        WHERE tenant_id = p_tenant_id AND account_code = p_parent_code;
        v_path := v_path || p_account_code::LTREE;
    ELSE
        v_path := p_account_code::LTREE;
    END IF;
    
    INSERT INTO kernel.chart_of_accounts (
        tenant_id, account_code, account_name, account_type, normal_balance,
        financial_statement, parent_account_code, account_path, account_level,
        created_by
    ) VALUES (
        p_tenant_id, p_account_code, p_account_name, p_account_type, p_normal_balance,
        p_financial_statement, p_parent_code, v_path, 
        COALESCE(nlevel(v_path), 1),
        security.get_participant_context()
    )
    RETURNING account_id INTO v_account_id;
    
    RETURN v_account_id;
END;
$$ LANGUAGE plpgsql;

-- Get Trial Balance
CREATE OR REPLACE FUNCTION kernel.get_trial_balance(
    p_tenant_id UUID,
    p_as_of_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    account_type VARCHAR,
    debit_balance DECIMAL(24, 6),
    credit_balance DECIMAL(24, 6)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        coa.account_code,
        coa.account_name,
        coa.account_type,
        CASE WHEN COALESCE(SUM(ml.amount), 0) > 0 AND coa.normal_balance = 'debit' 
             THEN COALESCE(SUM(ml.amount), 0) 
             WHEN COALESCE(SUM(ml.amount), 0) < 0 AND coa.normal_balance = 'credit'
             THEN ABS(COALESCE(SUM(ml.amount), 0))
             ELSE 0 
        END AS debit_balance,
        CASE WHEN COALESCE(SUM(ml.amount), 0) > 0 AND coa.normal_balance = 'credit'
             THEN COALESCE(SUM(ml.amount), 0)
             WHEN COALESCE(SUM(ml.amount), 0) < 0 AND coa.normal_balance = 'debit'
             THEN ABS(COALESCE(SUM(ml.amount), 0))
             ELSE 0
        END AS credit_balance
    FROM kernel.chart_of_accounts coa
    LEFT JOIN kernel.value_containers vc ON vc.coa_code = coa.account_code AND vc.tenant_id = p_tenant_id
    LEFT JOIN kernel.movement_legs ml ON ml.container_id = vc.container_id
    LEFT JOIN kernel.movement_postings mp ON mp.leg_id = ml.leg_id
    WHERE coa.tenant_id = p_tenant_id
      AND coa.is_active = TRUE
      AND (mp.posted_at IS NULL OR mp.posted_at::DATE <= p_as_of_date)
    GROUP BY coa.account_code, coa.account_name, coa.account_type, coa.normal_balance
    HAVING ABS(COALESCE(SUM(ml.amount), 0)) > 0
    ORDER BY coa.account_code;
END;
$$ LANGUAGE plpgsql;

-- Get Balance Sheet
CREATE OR REPLACE FUNCTION kernel.get_balance_sheet(
    p_tenant_id UUID,
    p_as_of_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_code TEXT,
    account_name TEXT,
    balance DECIMAL(24, 6)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        coa.statement_section,
        coa.account_code,
        coa.account_name,
        COALESCE(SUM(ml.amount), 0) * 
            CASE WHEN coa.normal_balance = 'debit' THEN 1 ELSE -1 END AS balance
    FROM kernel.chart_of_accounts coa
    LEFT JOIN kernel.value_containers vc ON vc.coa_code = coa.account_code AND vc.tenant_id = p_tenant_id
    LEFT JOIN kernel.movement_legs ml ON ml.container_id = vc.container_id
    LEFT JOIN kernel.movement_postings mp ON mp.leg_id = ml.leg_id
    WHERE coa.tenant_id = p_tenant_id
      AND coa.financial_statement = 'balance_sheet'
      AND coa.is_active = TRUE
      AND (mp.posted_at IS NULL OR mp.posted_at::DATE <= p_as_of_date)
    GROUP BY coa.statement_section, coa.account_code, coa.account_name, coa.normal_balance, coa.statement_order
    ORDER BY coa.statement_order, coa.account_code;
END;
$$ LANGUAGE plpgsql;

-- Get Income Statement (P&L)
CREATE OR REPLACE FUNCTION kernel.get_income_statement(
    p_tenant_id UUID,
    p_start_date DATE,
    p_end_date DATE
)
RETURNS TABLE (
    section TEXT,
    account_code TEXT,
    account_name TEXT,
    amount DECIMAL(24, 6)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        coa.statement_section,
        coa.account_code,
        coa.account_name,
        COALESCE(SUM(ml.amount), 0) * 
            CASE WHEN coa.normal_balance = 'credit' THEN 1 ELSE -1 END AS amount
    FROM kernel.chart_of_accounts coa
    LEFT JOIN kernel.value_containers vc ON vc.coa_code = coa.account_code AND vc.tenant_id = p_tenant_id
    LEFT JOIN kernel.movement_legs ml ON ml.container_id = vc.container_id
    LEFT JOIN kernel.movement_postings mp ON mp.leg_id = ml.leg_id
    WHERE coa.tenant_id = p_tenant_id
      AND coa.financial_statement = 'income_statement'
      AND coa.is_active = TRUE
      AND mp.posted_at::DATE BETWEEN p_start_date AND p_end_date
    GROUP BY coa.statement_section, coa.account_code, coa.account_name, coa.normal_balance, coa.statement_order
    ORDER BY coa.statement_order, coa.account_code;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SEED STANDARD COA
-- =============================================================================

-- Asset Accounts (1000-1999)
INSERT INTO kernel.chart_of_accounts (tenant_id, account_code, account_name, account_type, normal_balance, financial_statement, statement_section, statement_order) VALUES
    (NULL, '1000', 'Assets', 'asset', 'debit', 'balance_sheet', 'Assets', 100),
    (NULL, '1100', 'Current Assets', 'asset', 'debit', 'balance_sheet', 'Current Assets', 110),
    (NULL, '1110', 'Cash and Bank', 'asset', 'debit', 'balance_sheet', 'Current Assets', 111),
    (NULL, '1120', 'Accounts Receivable', 'asset', 'debit', 'balance_sheet', 'Current Assets', 112),
    (NULL, '1121', 'Trade Receivables - Insurance', 'asset', 'debit', 'balance_sheet', 'Current Assets', 113),
    (NULL, '1122', 'Trade Receivables - Repair', 'asset', 'debit', 'balance_sheet', 'Current Assets', 114),
    (NULL, '1130', 'Prepaid Insurance', 'asset', 'debit', 'balance_sheet', 'Current Assets', 115),
    (NULL, '1140', 'Inventory - Spare Parts', 'asset', 'debit', 'balance_sheet', 'Current Assets', 116),
    (NULL, '1150', 'Provision for Doubtful Debts', 'asset', 'credit', 'balance_sheet', 'Current Assets', 117),
    (NULL, '1200', 'Fixed Assets', 'asset', 'debit', 'balance_sheet', 'Non-Current Assets', 120),
    (NULL, '1210', 'Equipment', 'asset', 'debit', 'balance_sheet', 'Non-Current Assets', 121),
    (NULL, '1220', 'Accumulated Depreciation', 'asset', 'credit', 'balance_sheet', 'Non-Current Assets', 122)
ON CONFLICT (tenant_id, account_code) DO NOTHING;

-- Liability Accounts (2000-2999)
INSERT INTO kernel.chart_of_accounts (tenant_id, account_code, account_name, account_type, normal_balance, financial_statement, statement_section, statement_order) VALUES
    (NULL, '2000', 'Liabilities', 'liability', 'credit', 'balance_sheet', 'Liabilities', 200),
    (NULL, '2100', 'Current Liabilities', 'liability', 'credit', 'balance_sheet', 'Current Liabilities', 210),
    (NULL, '2110', 'Accounts Payable', 'liability', 'credit', 'balance_sheet', 'Current Liabilities', 211),
    (NULL, '2120', 'Unearned Premium Reserve', 'liability', 'credit', 'balance_sheet', 'Current Liabilities', 212),
    (NULL, '2130', 'Claim Reserve', 'liability', 'credit', 'balance_sheet', 'Current Liabilities', 213),
    (NULL, '2140', 'VAT Payable', 'liability', 'credit', 'balance_sheet', 'Current Liabilities', 214),
    (NULL, '2150', 'Tax Payable', 'liability', 'credit', 'balance_sheet', 'Current Liabilities', 215),
    (NULL, '2200', 'Long-term Liabilities', 'liability', 'credit', 'balance_sheet', 'Non-Current Liabilities', 220)
ON CONFLICT (tenant_id, account_code) DO NOTHING;

-- Equity Accounts (3000-3999)
INSERT INTO kernel.chart_of_accounts (tenant_id, account_code, account_name, account_type, normal_balance, financial_statement, statement_section, statement_order) VALUES
    (NULL, '3000', 'Equity', 'equity', 'credit', 'balance_sheet', 'Equity', 300),
    (NULL, '3100', 'Share Capital', 'equity', 'credit', 'balance_sheet', 'Equity', 310),
    (NULL, '3200', 'Retained Earnings', 'equity', 'credit', 'balance_sheet', 'Equity', 320),
    (NULL, '3300', 'Current Year Earnings', 'equity', 'credit', 'balance_sheet', 'Equity', 330)
ON CONFLICT (tenant_id, account_code) DO NOTHING;

-- Income Accounts (4000-4999)
INSERT INTO kernel.chart_of_accounts (tenant_id, account_code, account_name, account_type, normal_balance, financial_statement, statement_section, statement_order) VALUES
    (NULL, '4000', 'Revenue', 'income', 'credit', 'income_statement', 'Revenue', 400),
    (NULL, '4100', 'Insurance Premium Revenue', 'income', 'credit', 'income_statement', 'Revenue', 410),
    (NULL, '4200', 'Repair Service Revenue', 'income', 'credit', 'income_statement', 'Revenue', 420),
    (NULL, '4300', 'Product Sales Revenue', 'income', 'credit', 'income_statement', 'Revenue', 430),
    (NULL, '4400', 'Interest Income', 'income', 'credit', 'income_statement', 'Other Income', 440)
ON CONFLICT (tenant_id, account_code) DO NOTHING;

-- Expense Accounts (5000-5999)
INSERT INTO kernel.chart_of_accounts (tenant_id, account_code, account_name, account_type, normal_balance, financial_statement, statement_section, statement_order) VALUES
    (NULL, '5000', 'Expenses', 'expense', 'debit', 'income_statement', 'Operating Expenses', 500),
    (NULL, '5100', 'Claim Expense', 'expense', 'debit', 'income_statement', 'Cost of Sales', 510),
    (NULL, '5200', 'Cost of Goods Sold', 'expense', 'debit', 'income_statement', 'Cost of Sales', 520),
    (NULL, '5300', 'Repair Parts Cost', 'expense', 'debit', 'income_statement', 'Cost of Sales', 530),
    (NULL, '5400', 'Bad Debt Expense', 'expense', 'debit', 'income_statement', 'Operating Expenses', 540),
    (NULL, '5500', 'Salaries and Benefits', 'expense', 'debit', 'income_statement', 'Operating Expenses', 550),
    (NULL, '5600', 'Rent Expense', 'expense', 'debit', 'income_statement', 'Operating Expenses', 560),
    (NULL, '5700', 'Marketing Expense', 'expense', 'debit', 'income_statement', 'Operating Expenses', 570),
    (NULL, '5800', 'Depreciation Expense', 'expense', 'debit', 'income_statement', 'Operating Expenses', 580),
    (NULL, '5900', 'Other Operating Expenses', 'expense', 'debit', 'income_statement', 'Operating Expenses', 590)
ON CONFLICT (tenant_id, account_code) DO NOTHING;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Phase 1: Chart of Accounts & Financial Reporting initialized' AS status;
