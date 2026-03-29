-- =============================================================================
-- FILE: 902_multi_currency.sql
-- PURPOSE: Phase 3 - Multi-Currency & Exchange Rates
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: IAS 21, Multi-currency accounting
-- DEPENDENCIES: 008_value_movements.sql
-- =============================================================================

-- =============================================================================
-- EXCHANGE RATES
-- =============================================================================

CREATE TABLE kernel.exchange_rates (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    rate_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Currency Pair
    from_currency VARCHAR(3) NOT NULL,  -- ISO 4217
    to_currency VARCHAR(3) NOT NULL,    -- Usually functional currency
    
    -- Rate
    rate DECIMAL(18, 8) NOT NULL,  -- from_currency * rate = to_currency
    inverse_rate DECIMAL(18, 8) GENERATED ALWAYS AS (1 / NULLIF(rate, 0)) STORED,
    
    -- Rate Type
    rate_type VARCHAR(16) NOT NULL DEFAULT 'spot' CHECK (rate_type IN ('spot', 'average', 'closing', 'budget', 'forward')),
    
    -- Validity (bitemporal)
    valid_from DATE NOT NULL,
    valid_to DATE,
    
    -- Source
    source VARCHAR(64),  -- e.g., 'ECB', 'Bloomberg', 'Manual'
    source_reference TEXT,
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID,
    
    UNIQUE(tenant_id, from_currency, to_currency, rate_type, valid_from)
);

COMMENT ON TABLE kernel.exchange_rates IS 'Historical exchange rates for multi-currency accounting';

CREATE INDEX idx_exchange_rates_pair ON kernel.exchange_rates(tenant_id, from_currency, to_currency, rate_type);
CREATE INDEX idx_exchange_rates_valid ON kernel.exchange_rates(valid_from, valid_to);
CREATE INDEX idx_exchange_rates_lookup ON kernel.exchange_rates(tenant_id, from_currency, to_currency, valid_from DESC);

-- =============================================================================
-- CURRENCY CONVERSION LOG
-- =============================================================================

CREATE TABLE kernel.currency_conversions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    conversion_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Source
    source_type VARCHAR(32) NOT NULL,  -- 'movement', 'order', 'manual'
    source_id UUID,
    
    -- Amounts
    original_amount DECIMAL(24, 6) NOT NULL,
    original_currency VARCHAR(3) NOT NULL,
    converted_amount DECIMAL(24, 6) NOT NULL,
    target_currency VARCHAR(3) NOT NULL,
    
    -- Rate Used
    exchange_rate DECIMAL(18, 8) NOT NULL,
    rate_id UUID REFERENCES kernel.exchange_rates(rate_id),
    
    -- Conversion Details
    conversion_date DATE NOT NULL,
    conversion_type VARCHAR(16) NOT NULL DEFAULT 'transaction' CHECK (conversion_type IN ('transaction', 'balance_sheet', 'income_statement', 'settlement')),
    
    -- Rounding difference (if any)
    rounding_difference DECIMAL(10, 6) DEFAULT 0,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_currency_conversions_source ON kernel.currency_conversions(source_type, source_id);
CREATE INDEX idx_currency_conversions_date ON kernel.currency_conversions(tenant_id, conversion_date);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Get Exchange Rate
CREATE OR REPLACE FUNCTION kernel.get_exchange_rate(
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_as_of_date DATE DEFAULT CURRENT_DATE,
    p_rate_type VARCHAR(16) DEFAULT 'spot'
)
RETURNS DECIMAL AS $$
DECLARE
    v_rate DECIMAL;
BEGIN
    -- Direct rate
    SELECT rate INTO v_rate
    FROM kernel.exchange_rates
    WHERE from_currency = p_from_currency
      AND to_currency = p_to_currency
      AND rate_type = p_rate_type
      AND valid_from <= p_as_of_date
      AND (valid_to IS NULL OR valid_to >= p_as_of_date)
    ORDER BY valid_from DESC
    LIMIT 1;
    
    IF v_rate IS NOT NULL THEN
        RETURN v_rate;
    END IF;
    
    -- Inverse rate
    SELECT 1/rate INTO v_rate
    FROM kernel.exchange_rates
    WHERE from_currency = p_to_currency
      AND to_currency = p_from_currency
      AND rate_type = p_rate_type
      AND valid_from <= p_as_of_date
      AND (valid_to IS NULL OR valid_to >= p_as_of_date)
    ORDER BY valid_from DESC
    LIMIT 1;
    
    IF v_rate IS NOT NULL THEN
        RETURN v_rate;
    END IF;
    
    -- Cross rate via USD
    DECLARE
        v_from_usd DECIMAL;
        v_to_usd DECIMAL;
    BEGIN
        SELECT rate INTO v_from_usd
        FROM kernel.exchange_rates
        WHERE from_currency = p_from_currency
          AND to_currency = 'USD'
          AND valid_from <= p_as_of_date
        ORDER BY valid_from DESC
        LIMIT 1;
        
        SELECT rate INTO v_to_usd
        FROM kernel.exchange_rates
        WHERE from_currency = p_to_currency
          AND to_currency = 'USD'
          AND valid_from <= p_as_of_date
        ORDER BY valid_from DESC
        LIMIT 1;
        
        IF v_from_usd IS NOT NULL AND v_to_usd IS NOT NULL AND v_to_usd != 0 THEN
            RETURN v_from_usd / v_to_usd;
        END IF;
    END;
    
    RAISE EXCEPTION 'Exchange rate not found for % to % as of %', p_from_currency, p_to_currency, p_as_of_date;
END;
$$ LANGUAGE plpgsql;

-- Convert Currency
CREATE OR REPLACE FUNCTION kernel.convert_currency(
    p_amount DECIMAL,
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_as_of_date DATE DEFAULT CURRENT_DATE,
    p_rate_type VARCHAR(16) DEFAULT 'spot'
)
RETURNS DECIMAL AS $$
DECLARE
    v_rate DECIMAL;
BEGIN
    IF p_from_currency = p_to_currency THEN
        RETURN p_amount;
    END IF;
    
    v_rate := kernel.get_exchange_rate(p_from_currency, p_to_currency, p_as_of_date, p_rate_type);
    
    RETURN ROUND(p_amount * v_rate, 2);
END;
$$ LANGUAGE plpgsql;

-- Get Average Rate for Period
CREATE OR REPLACE FUNCTION kernel.get_average_rate(
    p_from_currency VARCHAR(3),
    p_to_currency VARCHAR(3),
    p_start_date DATE,
    p_end_date DATE
)
RETURNS DECIMAL AS $$
DECLARE
    v_avg_rate DECIMAL;
BEGIN
    SELECT AVG(rate) INTO v_avg_rate
    FROM kernel.exchange_rates
    WHERE from_currency = p_from_currency
      AND to_currency = p_to_currency
      AND valid_from BETWEEN p_start_date AND p_end_date;
    
    IF v_avg_rate IS NULL THEN
        -- Fall back to spot rate at end date
        v_avg_rate := kernel.get_exchange_rate(p_from_currency, p_to_currency, p_end_date, 'spot');
    END IF;
    
    RETURN v_avg_rate;
END;
$$ LANGUAGE plpgsql;

-- Record Currency Conversion
CREATE OR REPLACE FUNCTION kernel.record_currency_conversion(
    p_tenant_id UUID,
    p_source_type VARCHAR,
    p_source_id UUID,
    p_original_amount DECIMAL,
    p_original_currency VARCHAR,
    p_target_currency VARCHAR,
    p_conversion_date DATE,
    p_conversion_type VARCHAR DEFAULT 'transaction'
)
RETURNS UUID AS $$
DECLARE
    v_rate DECIMAL;
    v_rate_id UUID;
    v_converted_amount DECIMAL;
    v_conversion_id UUID;
BEGIN
    -- Get rate
    SELECT rate_id, rate INTO v_rate_id, v_rate
    FROM kernel.exchange_rates
    WHERE tenant_id = p_tenant_id
      AND from_currency = p_original_currency
      AND to_currency = p_target_currency
      AND valid_from <= p_conversion_date
      AND (valid_to IS NULL OR valid_to >= p_conversion_date)
    ORDER BY valid_from DESC
    LIMIT 1;
    
    IF v_rate IS NULL THEN
        v_rate := kernel.get_exchange_rate(p_original_currency, p_target_currency, p_conversion_date);
        v_rate_id := NULL;
    END IF;
    
    v_converted_amount := ROUND(p_original_amount * v_rate, 2);
    
    INSERT INTO kernel.currency_conversions (
        tenant_id, source_type, source_id,
        original_amount, original_currency, converted_amount, target_currency,
        exchange_rate, rate_id, conversion_date, conversion_type
    ) VALUES (
        p_tenant_id, p_source_type, p_source_id,
        p_original_amount, p_original_currency, v_converted_amount, p_target_currency,
        v_rate, v_rate_id, p_conversion_date, p_conversion_type
    )
    RETURNING conversion_id INTO v_conversion_id;
    
    RETURN v_conversion_id;
END;
$$ LANGUAGE plpgsql;

-- Convert Trial Balance to Functional Currency
CREATE OR REPLACE FUNCTION kernel.convert_trial_balance(
    p_tenant_id UUID,
    p_as_of_date DATE,
    p_target_currency VARCHAR(3)
)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    original_balance DECIMAL,
    original_currency VARCHAR,
    functional_balance DECIMAL,
    exchange_rate DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        coa.account_code,
        coa.account_name,
        COALESCE(SUM(ml.amount), 0) AS original_balance,
        vm.currency_code AS original_currency,
        kernel.convert_currency(
            COALESCE(SUM(ml.amount), 0),
            vm.currency_code,
            p_target_currency,
            p_as_of_date,
            'closing'
        ) AS functional_balance,
        kernel.get_exchange_rate(vm.currency_code, p_target_currency, p_as_of_date, 'closing') AS exchange_rate
    FROM kernel.chart_of_accounts coa
    JOIN kernel.value_containers vc ON vc.coa_code = coa.account_code AND vc.tenant_id = p_tenant_id
    JOIN kernel.movement_legs ml ON ml.container_id = vc.container_id
    JOIN kernel.value_movements vm ON vm.movement_id = ml.movement_id
    JOIN kernel.movement_postings mp ON mp.leg_id = ml.leg_id
    WHERE coa.tenant_id = p_tenant_id
      AND mp.posted_at::DATE <= p_as_of_date
    GROUP BY coa.account_code, coa.account_name, vm.currency_code;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Auto-create functional amount on movement
CREATE OR REPLACE FUNCTION kernel.auto_convert_movement()
RETURNS TRIGGER AS $$
DECLARE
    v_functional_currency VARCHAR(3) := 'USD';  -- Should come from tenant config
    v_rate DECIMAL;
BEGIN
    IF NEW.currency_code != v_functional_currency AND NEW.amount_in_functional IS NULL THEN
        v_rate := kernel.get_exchange_rate(NEW.currency_code, v_functional_currency, NEW.entry_date::DATE);
        NEW.amount_in_functional := ROUND(NEW.total_debits * v_rate, 2);
        NEW.exchange_rate := v_rate;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to value_movements
DROP TRIGGER IF EXISTS trg_auto_convert_movement ON kernel.value_movements;
CREATE TRIGGER trg_auto_convert_movement
    BEFORE INSERT ON kernel.value_movements
    FOR EACH ROW EXECUTE FUNCTION kernel.auto_convert_movement();

-- =============================================================================
-- SEED EXCHANGE RATES
-- =============================================================================

-- Sample exchange rates (in reality, these would be loaded from an API)
INSERT INTO kernel.exchange_rates (tenant_id, from_currency, to_currency, rate, rate_type, valid_from, source) VALUES
    (NULL, 'EUR', 'USD', 1.0850, 'spot', '2024-01-01', 'ECB'),
    (NULL, 'EUR', 'USD', 1.0900, 'spot', '2024-02-01', 'ECB'),
    (NULL, 'EUR', 'USD', 1.0950, 'spot', '2024-03-01', 'ECB'),
    (NULL, 'GBP', 'USD', 1.2650, 'spot', '2024-01-01', 'ECB'),
    (NULL, 'GBP', 'USD', 1.2700, 'spot', '2024-02-01', 'ECB'),
    (NULL, 'GBP', 'USD', 1.2750, 'spot', '2024-03-01', 'ECB'),
    (NULL, 'JPY', 'USD', 0.0067, 'spot', '2024-01-01', 'ECB'),
    (NULL, 'JPY', 'USD', 0.0068, 'spot', '2024-02-01', 'ECB'),
    (NULL, 'JPY', 'USD', 0.0069, 'spot', '2024-03-01', 'ECB')
ON CONFLICT (tenant_id, from_currency, to_currency, rate_type, valid_from) DO NOTHING;

-- Average rates for January 2024
INSERT INTO kernel.exchange_rates (tenant_id, from_currency, to_currency, rate, rate_type, valid_from, valid_to, source) VALUES
    (NULL, 'EUR', 'USD', 1.0875, 'average', '2024-01-01', '2024-01-31', 'ECB'),
    (NULL, 'GBP', 'USD', 1.2675, 'average', '2024-01-01', '2024-01-31', 'ECB')
ON CONFLICT (tenant_id, from_currency, to_currency, rate_type, valid_from) DO NOTHING;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Phase 3: Multi-Currency Support initialized' AS status;
