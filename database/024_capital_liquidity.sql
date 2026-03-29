-- =============================================================================
-- FILE: 024_capital_liquidity.sql
-- PURPOSE: Primitive 20 - Capital & Liquidity (Basel III)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Basel III, CRD IV, LCR, NSFR
-- DEPENDENCIES: 007_value_containers.sql, 022_jurisdictions.sql
-- =============================================================================

-- =============================================================================
-- CAPITAL POSITIONS
-- =============================================================================

CREATE TYPE kernel.capital_tier AS ENUM (
    'tier_1_core',
    'tier_1_additional',
    'tier_2',
    'tier_3'
);

CREATE TYPE kernel.capital_component AS ENUM (
    'common_equity',
    'retained_earnings',
    'other_reserves',
    'minority_interest',
    'additional_tier_1',
    'tier_2_capital',
    'regulatory_adjustments'
);

CREATE TABLE kernel.capital_positions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    position_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Reporting entity
    entity_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    jurisdiction_id UUID REFERENCES kernel.jurisdictions(jurisdiction_id),
    
    -- Reporting date
    reporting_date DATE NOT NULL,
    
    -- Capital classification
    capital_tier kernel.capital_tier NOT NULL,
    capital_component kernel.capital_component NOT NULL,
    
    -- Amounts
    gross_amount DECIMAL(24, 6) NOT NULL,
    regulatory_adjustments DECIMAL(24, 6) DEFAULT 0,
    net_amount DECIMAL(24, 6) GENERATED ALWAYS AS (gross_amount - regulatory_adjustments) STORED,
    
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    -- Status
    is_audited BOOLEAN DEFAULT FALSE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(entity_id, reporting_date, capital_tier, capital_component)
);

CREATE INDEX idx_capital_positions_entity ON kernel.capital_positions(entity_id, reporting_date DESC);
CREATE INDEX idx_capital_positions_tier ON kernel.capital_positions(capital_tier);

-- =============================================================================
-- RISK-WEIGHTED ASSETS (RWA)
-- =============================================================================

CREATE TYPE kernel.risk_category AS ENUM (
    'credit_risk',
    'market_risk',
    'operational_risk',
    'counterparty_risk',
    'settlement_risk'
);

CREATE TYPE kernel.asset_class AS ENUM (
    'cash',
    'sovereign_debt',
    'corporate_debt',
    'retail_exposures',
    'mortgages',
    'operational',
    'other'
);

CREATE TABLE kernel.risk_weighted_assets (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    rwa_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Reporting entity
    entity_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    reporting_date DATE NOT NULL,
    
    -- Risk category
    risk_category kernel.risk_category NOT NULL,
    asset_class kernel.asset_class NOT NULL,
    
    -- Exposure
    exposure_amount DECIMAL(24, 6) NOT NULL,
    credit_conversion_factor DECIMAL(5, 4) DEFAULT 1.0,
    exposure_at_default DECIMAL(24, 6),
    
    -- Risk weight
    risk_weight DECIMAL(5, 4) NOT NULL,  -- 0.0000 to 12.5000 (1250%)
    
    -- RWA calculation
    risk_weighted_assets DECIMAL(24, 6) GENERATED ALWAYS AS 
        (exposure_at_default * risk_weight) STORED,
    
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(entity_id, reporting_date, risk_category, asset_class)
);

CREATE INDEX idx_rwa_entity ON kernel.risk_weighted_assets(entity_id, reporting_date DESC);

-- =============================================================================
-- CAPITAL RATIOS
-- =============================================================================

CREATE TABLE kernel.capital_ratios (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    ratio_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Reporting entity
    entity_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    jurisdiction_id UUID REFERENCES kernel.jurisdictions(jurisdiction_id),
    reporting_date DATE NOT NULL,
    
    -- Capital amounts
    tier_1_capital DECIMAL(24, 6) NOT NULL,
    tier_1_core_capital DECIMAL(24, 6) NOT NULL,
    total_capital DECIMAL(24, 6) NOT NULL,
    
    -- RWA
    total_rwa DECIMAL(24, 6) NOT NULL,
    
    -- Ratios (calculated)
    common_equity_tier_1_ratio DECIMAL(5, 4) GENERATED ALWAYS AS 
        (tier_1_core_capital / NULLIF(total_rwa, 0)) STORED,
    tier_1_ratio DECIMAL(5, 4) GENERATED ALWAYS AS 
        (tier_1_capital / NULLIF(total_rwa, 0)) STORED,
    total_capital_ratio DECIMAL(5, 4) GENERATED ALWAYS AS 
        (total_capital / NULLIF(total_rwa, 0)) STORED,
    
    -- Minimum requirements
    min_cet1_requirement DECIMAL(5, 4) DEFAULT 0.0450,  -- 4.5%
    min_tier1_requirement DECIMAL(5, 4) DEFAULT 0.0600,  -- 6%
    min_total_capital_requirement DECIMAL(5, 4) DEFAULT 0.0800,  -- 8%
    
    -- Buffers
    capital_conservation_buffer DECIMAL(5, 4) DEFAULT 0.0250,  -- 2.5%
    countercyclical_buffer DECIMAL(5, 4) DEFAULT 0.0000,
    g_sib_buffer DECIMAL(5, 4) DEFAULT 0.0000,
    
    -- Compliance status
    is_compliant BOOLEAN GENERATED ALWAYS AS (
        common_equity_tier_1_ratio >= min_cet1_requirement + capital_conservation_buffer AND
        tier_1_ratio >= min_tier1_requirement AND
        total_capital_ratio >= min_total_capital_requirement
    ) STORED,
    
    surplus_deficit DECIMAL(24, 6) GENERATED ALWAYS AS (
        total_capital - (total_rwa * min_total_capital_requirement)
    ) STORED,
    
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(entity_id, reporting_date)
);

CREATE INDEX idx_capital_ratios_entity ON kernel.capital_ratios(entity_id, reporting_date DESC);
CREATE INDEX idx_capital_ratios_compliance ON kernel.capital_ratios(is_compliant);

-- =============================================================================
-- LIQUIDITY COVERAGE RATIO (LCR)
-- =============================================================================

CREATE TYPE kernel.hqla_level AS ENUM (
    'level_1',
    'level_2a',
    'level_2b'
);

CREATE TABLE kernel.lcr_calculations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    lcr_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Reporting entity
    entity_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    reporting_date DATE NOT NULL,
    
    -- HQLA (High Quality Liquid Assets)
    level_1_hqla DECIMAL(24, 6) DEFAULT 0,
    level_2a_hqla DECIMAL(24, 6) DEFAULT 0,
    level_2b_hqla DECIMAL(24, 6) DEFAULT 0,
    total_hqla DECIMAL(24, 6) GENERATED ALWAYS AS 
        (level_1_hqla + level_2a_hqla * 0.85 + level_2b_hqla * 0.75) STORED,
    
    -- Cash outflows
    retail_deposit_outflows DECIMAL(24, 6) DEFAULT 0,
    wholesale_funding_outflows DECIMAL(24, 6) DEFAULT 0,
    secured_funding_outflows DECIMAL(24, 6) DEFAULT 0,
    derivative_outflows DECIMAL(24, 6) DEFAULT 0,
    other_outflows DECIMAL(24, 6) DEFAULT 0,
    total_cash_outflows DECIMAL(24, 6) DEFAULT 0,
    
    -- Cash inflows
    secured_lending_inflows DECIMAL(24, 6) DEFAULT 0,
    wholesale_inflows DECIMAL(24, 6) DEFAULT 0,
    other_inflows DECIMAL(24, 6) DEFAULT 0,
    total_cash_inflows DECIMAL(24, 6) DEFAULT 0,
    
    -- Net cash outflows (capped at 75% of gross)
    net_cash_outflows DECIMAL(24, 6) GENERATED ALWAYS AS (
        GREATEST(total_cash_outflows - LEAST(total_cash_inflows, total_cash_outflows * 0.75), 0)
    ) STORED,
    
    -- LCR ratio
    lcr_ratio DECIMAL(5, 4) GENERATED ALWAYS AS 
        (total_hqla / NULLIF(net_cash_outflows, 0)) STORED,
    
    -- Requirement (100% minimum)
    min_requirement DECIMAL(5, 4) DEFAULT 1.0000,
    is_compliant BOOLEAN GENERATED ALWAYS AS (lcr_ratio >= 1.0000) STORED,
    
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(entity_id, reporting_date)
);

CREATE INDEX idx_lcr_entity ON kernel.lcr_calculations(entity_id, reporting_date DESC);

-- =============================================================================
-- NET STABLE FUNDING RATIO (NSFR)
-- =============================================================================

CREATE TABLE kernel.nsfr_calculations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    nsfr_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Reporting entity
    entity_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    reporting_date DATE NOT NULL,
    
    -- Available stable funding (ASF)
    regulatory_capital_asf DECIMAL(24, 6) DEFAULT 0,
    stable_retail_deposits DECIMAL(24, 6) DEFAULT 0,
    less_stable_retail_deposits DECIMAL(24, 6) DEFAULT 0,
    wholesale_funding_asf DECIMAL(24, 6) DEFAULT 0,
    other_liabilities_asf DECIMAL(24, 6) DEFAULT 0,
    total_asf DECIMAL(24, 6) DEFAULT 0,
    
    -- Required stable funding (RSF)
    hqla_rsf DECIMAL(24, 6) DEFAULT 0,
    performing_loans_rsf DECIMAL(24, 6) DEFAULT 0,
    securities_rsf DECIMAL(24, 6) DEFAULT 0,
    other_assets_rsf DECIMAL(24, 6) DEFAULT 0,
    derivatives_rsf DECIMAL(24, 6) DEFAULT 0,
    total_rsf DECIMAL(24, 6) DEFAULT 0,
    
    -- NSFR ratio
    nsfr_ratio DECIMAL(5, 4) GENERATED ALWAYS AS 
        (total_asf / NULLIF(total_rsf, 0)) STORED,
    
    -- Requirement (100% minimum)
    min_requirement DECIMAL(5, 4) DEFAULT 1.0000,
    is_compliant BOOLEAN GENERATED ALWAYS AS (nsfr_ratio >= 1.0000) STORED,
    
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(entity_id, reporting_date)
);

CREATE INDEX idx_nsfr_entity ON kernel.nsfr_calculations(entity_id, reporting_date DESC);

-- =============================================================================
-- LEVERAGE RATIO
-- =============================================================================

CREATE TABLE kernel.leverage_ratio_calculations (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    leverage_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Reporting entity
    entity_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    reporting_date DATE NOT NULL,
    
    -- Capital
    tier_1_capital DECIMAL(24, 6) NOT NULL,
    
    -- Exposure
    on_balance_sheet_exposure DECIMAL(24, 6) NOT NULL,
    derivative_exposure DECIMAL(24, 6) DEFAULT 0,
    securities_financing_exposure DECIMAL(24, 6) DEFAULT 0,
    off_balance_sheet_exposure DECIMAL(24, 6) DEFAULT 0,
    total_exposure DECIMAL(24, 6) NOT NULL,
    
    -- Leverage ratio
    leverage_ratio DECIMAL(5, 4) GENERATED ALWAYS AS 
        (tier_1_capital / NULLIF(total_exposure, 0)) STORED,
    
    -- Requirement (3% minimum for Basel III)
    min_requirement DECIMAL(5, 4) DEFAULT 0.0300,
    is_compliant BOOLEAN GENERATED ALWAYS AS (leverage_ratio >= 0.0300) STORED,
    
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(entity_id, reporting_date)
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Calculate capital ratios
CREATE OR REPLACE FUNCTION kernel.calculate_capital_ratios(
    p_entity_id UUID,
    p_reporting_date DATE
)
RETURNS UUID AS $$
DECLARE
    v_ratio_id UUID;
    v_tier_1 DECIMAL(24, 6);
    v_cet1 DECIMAL(24, 6);
    v_total_capital DECIMAL(24, 6);
    v_total_rwa DECIMAL(24, 6);
BEGIN
    -- Calculate capital amounts
    SELECT 
        COALESCE(SUM(CASE WHEN capital_tier IN ('tier_1_core', 'tier_1_additional') THEN net_amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN capital_tier = 'tier_1_core' THEN net_amount ELSE 0 END), 0),
        COALESCE(SUM(net_amount), 0)
    INTO v_tier_1, v_cet1, v_total_capital
    FROM kernel.capital_positions
    WHERE entity_id = p_entity_id AND reporting_date = p_reporting_date;
    
    -- Calculate total RWA
    SELECT COALESCE(SUM(risk_weighted_assets), 0) INTO v_total_rwa
    FROM kernel.risk_weighted_assets
    WHERE entity_id = p_entity_id AND reporting_date = p_reporting_date;
    
    INSERT INTO kernel.capital_ratios (
        entity_id, reporting_date, tier_1_capital, tier_1_core_capital,
        total_capital, total_rwa
    ) VALUES (
        p_entity_id, p_reporting_date, v_tier_1, v_cet1, v_total_capital, v_total_rwa
    )
    ON CONFLICT (entity_id, reporting_date) DO UPDATE SET
        tier_1_capital = EXCLUDED.tier_1_capital,
        tier_1_core_capital = EXCLUDED.tier_1_core_capital,
        total_capital = EXCLUDED.total_capital,
        total_rwa = EXCLUDED.total_rwa;
    
    SELECT ratio_id INTO v_ratio_id FROM kernel.capital_ratios
    WHERE entity_id = p_entity_id AND reporting_date = p_reporting_date;
    
    RETURN v_ratio_id;
END;
$$ LANGUAGE plpgsql;

-- Check capital compliance
CREATE OR REPLACE FUNCTION kernel.check_capital_compliance(p_entity_id UUID)
RETURNS TABLE(
    ratio_type TEXT,
    current_value DECIMAL(5, 4),
    requirement DECIMAL(5, 4),
    is_compliant BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        'CET1 Ratio'::TEXT,
        cr.common_equity_tier_1_ratio,
        cr.min_cet1_requirement + cr.capital_conservation_buffer,
        cr.common_equity_tier_1_ratio >= cr.min_cet1_requirement + cr.capital_conservation_buffer
    FROM kernel.capital_ratios cr
    WHERE cr.entity_id = p_entity_id
    ORDER BY cr.reporting_date DESC
    LIMIT 1;
    
    RETURN QUERY
    SELECT 
        'Total Capital Ratio'::TEXT,
        cr.total_capital_ratio,
        cr.min_total_capital_requirement,
        cr.total_capital_ratio >= cr.min_total_capital_requirement
    FROM kernel.capital_ratios cr
    WHERE cr.entity_id = p_entity_id
    ORDER BY cr.reporting_date DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 20: Capital & Liquidity (Basel III) initialized' AS status;
