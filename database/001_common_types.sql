-- =============================================================================
-- FILE: 001_common_types.sql
-- PURPOSE: Common composite types, ISO standard validations, lookup tables
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 4217 (Currency), ISO 3166 (Country), ISO 8601 (Time),
--            ISO 17442 (LEI), ISO 9362 (BIC), ISO 13616 (IBAN)
-- DEPENDENCIES: 000_schema_setup.sql
-- =============================================================================

-- =============================================================================
-- ISO 4217 CURRENCY CODES
-- =============================================================================

CREATE TABLE kernel.currencies (
    currency_code CHAR(3) PRIMARY KEY,
    currency_name TEXT NOT NULL,
    currency_number INTEGER,  -- ISO 4217 numeric code
    minor_unit_digits INTEGER DEFAULT 2,
    is_active BOOLEAN DEFAULT TRUE
);

COMMENT ON TABLE kernel.currencies IS 'ISO 4217 currency codes lookup table';

-- Insert common currencies
INSERT INTO kernel.currencies (currency_code, currency_name, currency_number, minor_unit_digits) VALUES
    ('USD', 'US Dollar', 840, 2),
    ('EUR', 'Euro', 978, 2),
    ('GBP', 'British Pound', 826, 2),
    ('JPY', 'Japanese Yen', 392, 0),
    ('CHF', 'Swiss Franc', 756, 2),
    ('SGD', 'Singapore Dollar', 702, 2),
    ('AUD', 'Australian Dollar', 36, 2),
    ('CAD', 'Canadian Dollar', 124, 2),
    ('CNY', 'Chinese Yuan', 156, 2),
    ('HKD', 'Hong Kong Dollar', 344, 2)
ON CONFLICT (currency_code) DO NOTHING;

-- =============================================================================
-- ISO 3166 COUNTRY CODES
-- =============================================================================

CREATE TABLE kernel.countries (
    country_code CHAR(2) PRIMARY KEY,  -- ISO 3166-1 alpha-2
    country_code_3 CHAR(3),            -- ISO 3166-1 alpha-3
    country_number INTEGER,             -- ISO 3166-1 numeric
    country_name TEXT NOT NULL,
    official_name TEXT,
    region TEXT,
    sub_region TEXT,
    is_active BOOLEAN DEFAULT TRUE
);

COMMENT ON TABLE kernel.countries IS 'ISO 3166-1 country codes lookup table';

-- Insert common countries
INSERT INTO kernel.countries (country_code, country_code_3, country_number, country_name, official_name, region, sub_region) VALUES
    ('US', 'USA', 840, 'United States', 'United States of America', 'Americas', 'Northern America'),
    ('GB', 'GBR', 826, 'United Kingdom', 'United Kingdom of Great Britain and Northern Ireland', 'Europe', 'Northern Europe'),
    ('DE', 'DEU', 276, 'Germany', 'Federal Republic of Germany', 'Europe', 'Western Europe'),
    ('FR', 'FRA', 250, 'France', 'French Republic', 'Europe', 'Western Europe'),
    ('SG', 'SGP', 702, 'Singapore', 'Republic of Singapore', 'Asia', 'South-eastern Asia'),
    ('JP', 'JPN', 392, 'Japan', 'Japan', 'Asia', 'Eastern Asia'),
    ('AU', 'AUS', 36, 'Australia', 'Commonwealth of Australia', 'Oceania', 'Australia and New Zealand'),
    ('CA', 'CAN', 124, 'Canada', 'Canada', 'Americas', 'Northern America'),
    ('CH', 'CHE', 756, 'Switzerland', 'Swiss Confederation', 'Europe', 'Western Europe'),
    ('NL', 'NLD', 528, 'Netherlands', 'Kingdom of the Netherlands', 'Europe', 'Western Europe')
ON CONFLICT (country_code) DO NOTHING;

-- =============================================================================
-- ISO 17442 LEI (LEGAL ENTITY IDENTIFIER)
-- =============================================================================

-- Function to validate LEI format
CREATE OR REPLACE FUNCTION kernel.validate_lei(p_lei TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_modulo INTEGER;
    v_sum INTEGER := 0;
    v_char TEXT;
    v_value INTEGER;
    v_lei_upper TEXT;
BEGIN
    -- Check length
    IF LENGTH(p_lei) != 20 THEN
        RETURN FALSE;
    END IF;
    
    v_lei_upper := UPPER(p_lei);
    
    -- Check format: 18 uppercase alphanumeric + 2 check digits
    IF NOT v_lei_upper ~ '^[A-Z0-9]{18}[0-9]{2}$' THEN
        RETURN FALSE;
    END IF;
    
    -- ISO 17442 MOD 97-10 check digit validation
    -- Convert letters to numbers (A=10, B=11, ..., Z=35)
    FOR i IN 1..18 LOOP
        v_char := SUBSTRING(v_lei_upper, i, 1);
        IF v_char ~ '[A-Z]' THEN
            v_value := ASCII(v_char) - ASCII('A') + 10;
        ELSE
            v_value := v_char::INTEGER;
        END IF;
        v_sum := (v_sum * 10 + v_value) % 97;
    END LOOP;
    
    -- Add check digits
    v_sum := (v_sum * 100 + SUBSTRING(v_lei_upper, 19, 2)::INTEGER) % 97;
    
    RETURN v_sum = 1;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION kernel.validate_lei(TEXT) IS 'Validate ISO 17442 Legal Entity Identifier (LEI) format and check digits';

-- =============================================================================
-- ISO 9362 BIC (SWIFT/BANK IDENTIFIER CODE)
-- =============================================================================

-- Function to validate BIC format
CREATE OR REPLACE FUNCTION kernel.validate_bic(p_bic TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- BIC can be 8 or 11 characters
    -- Format: 4 letters (institution) + 2 letters (country) + 2 letters/numbers (location) + optional 3 letters/numbers (branch)
    RETURN UPPER(p_bic) ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION kernel.validate_bic(TEXT) IS 'Validate ISO 9362 BIC/SWIFT code format';

-- =============================================================================
-- ISO 13616 IBAN (INTERNATIONAL BANK ACCOUNT NUMBER)
-- =============================================================================

-- Function to validate IBAN
CREATE OR REPLACE FUNCTION kernel.validate_iban(p_iban TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_iban TEXT;
    v_rearranged TEXT;
    v_result NUMERIC := 0;  -- Use NUMERIC to prevent overflow
    v_char TEXT;
    v_value INTEGER;
    v_chunk TEXT;
BEGIN
    -- Remove spaces and convert to uppercase
    v_iban := REPLACE(UPPER(p_iban), ' ', '');
    
    -- Check minimum length ( varies by country, 15-34 chars)
    IF LENGTH(v_iban) < 15 OR LENGTH(v_iban) > 34 THEN
        RETURN FALSE;
    END IF;
    
    -- Check country code is letters
    IF NOT SUBSTRING(v_iban, 1, 2) ~ '^[A-Z]{2}$' THEN
        RETURN FALSE;
    END IF;
    
    -- Check check digits are numeric
    IF NOT SUBSTRING(v_iban, 3, 2) ~ '^[0-9]{2}$' THEN
        RETURN FALSE;
    END IF;
    
    -- Move first 4 characters to end
    v_rearranged := SUBSTRING(v_iban, 5) || SUBSTRING(v_iban, 1, 4);
    
    -- Replace letters with numbers (A=10, B=11, ...)
    -- Process in chunks to avoid overflow with NUMERIC
    FOR i IN 1..LENGTH(v_rearranged) LOOP
        v_char := SUBSTRING(v_rearranged, i, 1);
        IF v_char ~ '[A-Z]' THEN
            v_value := ASCII(v_char) - ASCII('A') + 10;
        ELSIF v_char ~ '[0-9]' THEN
            v_value := v_char::INTEGER;
        ELSE
            RETURN FALSE;  -- Invalid character
        END IF;
        
        -- MOD 97 calculation with overflow protection
        v_result := (v_result * 10 + v_value) % 97;
    END LOOP;
    
    RETURN v_result = 1;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION kernel.validate_iban(TEXT) IS 'Validate ISO 13616 IBAN format and check digits';

-- =============================================================================
-- ISO 6166 ISIN (INTERNATIONAL SECURITIES IDENTIFICATION NUMBER)
-- =============================================================================

CREATE OR REPLACE FUNCTION kernel.validate_isin(p_isin TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- ISIN is 12 characters: 2 letters (country) + 9 alphanumeric + 1 check digit
    RETURN UPPER(p_isin) ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- ISO 10962 CFI (CLASSIFICATION OF FINANCIAL INSTRUMENTS)
-- =============================================================================

CREATE OR REPLACE FUNCTION kernel.validate_cfi(p_cfi TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- CFI is 6 uppercase letters
    RETURN UPPER(p_cfi) ~ '^[A-Z]{6}$';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- ISO 20022 MESSAGE TYPE VALIDATION
-- =============================================================================

CREATE TYPE kernel.iso20022_message_type AS ENUM (
    'pacs.008',  -- FIToFICustomerCreditTransfer
    'pacs.009',  -- FinancialInstitutionCreditTransfer
    'pain.001',  -- CustomerCreditTransferInitiation
    'pain.002',  -- CustomerPaymentStatusReport
    'camt.052',  -- BankToCustomerAccountReport
    'camt.053',  -- BankToCustomerStatement
    'camt.054',  -- BankToCustomerDebitCreditNotification
    'remt.001',  -- CustomerCreditTransferInitiation
    'acmt.001',  -- AccountOpeningRequest
    'xsys.001'   -- SystemEventNotification
);

COMMENT ON TYPE kernel.iso20022_message_type IS 'ISO 20022 message types for financial messaging';

-- =============================================================================
-- UUID GENERATION (ULID-like)
-- =============================================================================

-- Generate timestamp-based UUID for better sorting
CREATE OR REPLACE FUNCTION kernel.generate_ulid()
RETURNS UUID AS $$
BEGIN
    -- Use uuid-ossp v4 as fallback
    -- For production, consider pg_ulid extension
    RETURN uuid_generate_v4();
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION kernel.generate_ulid() IS 'Generate unique identifier (ULID-compatible UUID v4)';

-- =============================================================================
-- INITIALIZATION COMPLETE
-- =============================================================================

SELECT 'Common types and ISO standards initialized' AS status;
