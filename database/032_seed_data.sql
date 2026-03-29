-- =============================================================================
-- FILE: 032_seed_data.sql
-- PURPOSE: Seed data for development and testing
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: GDPR anonymized test data
-- DEPENDENCIES: All primitives
-- =============================================================================

-- =============================================================================
-- SYSTEM CONFIGURATION
-- =============================================================================

-- Insert schema version
INSERT INTO kernel.schema_version (version, description, installed_by)
VALUES (1, 'Initial InsureLedger schema', 'system')
ON CONFLICT (version) DO NOTHING;

-- =============================================================================
-- TENANT DATA
-- =============================================================================

-- Main tenant
INSERT INTO kernel.technician_tenants (tenant_id, tenant_name, tenant_code, status)
VALUES (
    '00000000-0000-0000-0000-000000000001'::UUID,
    'InsureLedger Main',
    'ILMAIN',
    'active'
)
ON CONFLICT (tenant_code) DO NOTHING;

-- Demo tenant
INSERT INTO kernel.technician_tenants (tenant_id, tenant_name, tenant_code, status)
VALUES (
    '00000000-0000-0000-0000-000000000002'::UUID,
    'Demo Tenant',
    'DEMO',
    'active'
)
ON CONFLICT (tenant_code) DO NOTHING;

-- =============================================================================
-- PARTICIPANT DATA (Test users)
-- =============================================================================

-- System admin
INSERT INTO kernel.participants (
    participant_id, tenant_id, participant_type, status,
    display_name, legal_name, email_address
) VALUES (
    '00000000-0000-0000-0000-000000000010'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID,
    'employee',
    'active',
    'System Administrator',
    'InsureLedger Admin',
    'admin@insureledger.test'
)
ON CONFLICT (participant_id) DO NOTHING;

-- Demo insurer
INSERT INTO kernel.participants (
    participant_id, tenant_id, participant_type, status,
    display_name, legal_name, email_address, lei_code
) VALUES (
    '00000000-0000-0000-0000-000000000020'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID,
    'corporate',
    'active',
    'Demo Insurance Corp',
    'Demo Insurance Corporation Ltd',
    'insurer@demo.test',
    '5493001KJTIIGC8Y1R12'
)
ON CONFLICT (participant_id) DO NOTHING;

-- Demo customer
INSERT INTO kernel.participants (
    participant_id, tenant_id, participant_type, status,
    display_name, legal_name, email_address
) VALUES (
    '00000000-0000-0000-0000-000000000030'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID,
    'individual',
    'active',
    'John Demo',
    'John Demo Customer',
    'john@demo.test'
)
ON CONFLICT (participant_id) DO NOTHING;

-- Demo technician
INSERT INTO kernel.participants (
    participant_id, tenant_id, participant_type, status,
    display_name, legal_name, email_address
) VALUES (
    '00000000-0000-0000-0000-000000000040'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID,
    'technician',
    'active',
    'Tech Repair Pro',
    'Tech Repair Professional Services',
    'tech@repair.test'
)
ON CONFLICT (participant_id) DO NOTHING;

-- =============================================================================
-- DEVICE DATA
-- =============================================================================

-- Demo iPhone
INSERT INTO kernel.devices (
    device_id, tenant_id, current_owner_id, device_type,
    manufacturer, model, serial_number, imei,
    purchase_date, warranty_expiry, attributes
) VALUES (
    '00000000-0000-0000-0000-000000000100'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID,
    '00000000-0000-0000-0000-000000000030'::UUID,
    'smartphone',
    'Apple',
    'iPhone 15 Pro',
    'ABC123456789',
    '351234567890123',
    '2024-01-15'::DATE,
    '2026-01-15'::DATE,
    '{"color": "Space Black", "storage": "256GB", "value": 1199.00}'::JSONB
)
ON CONFLICT (device_id) DO NOTHING;

-- Demo Samsung
INSERT INTO kernel.devices (
    device_id, tenant_id, current_owner_id, device_type,
    manufacturer, model, serial_number, imei,
    purchase_date, warranty_expiry, attributes
) VALUES (
    '00000000-0000-0000-0000-000000000101'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID,
    '00000000-0000-0000-0000-000000000030'::UUID,
    'smartphone',
    'Samsung',
    'Galaxy S24 Ultra',
    'DEF987654321',
    '359876543210987',
    '2024-02-01'::DATE,
    '2026-02-01'::DATE,
    '{"color": "Titanium Gray", "storage": "512GB", "value": 1299.00}'::JSONB
)
ON CONFLICT (device_id) DO NOTHING;

-- =============================================================================
-- PRODUCT CATALOG
-- =============================================================================

-- Screen protection plan
INSERT INTO kernel.product_catalog (
    product_id, product_code, product_name, category,
    base_price, currency_code, description
) VALUES (
    '00000000-0000-0000-0000-000000000200'::UUID,
    'SCREEN-PRO-01',
    'Screen Protection Pro',
    'insurance',
    9.99,
    'USD',
    'Comprehensive screen damage protection with same-day repair service'
)
ON CONFLICT (product_code) DO NOTHING;

-- Full device protection
INSERT INTO kernel.product_catalog (
    product_id, product_code, product_name, category,
    base_price, currency_code, description
) VALUES (
    '00000000-0000-0000-0000-000000000201'::UUID,
    'DEVICE-PRO-01',
    'Complete Device Protection',
    'insurance',
    19.99,
    'USD',
    'Full coverage for accidental damage, theft, and loss'
)
ON CONFLICT (product_code) DO NOTHING;

-- Screen repair service
INSERT INTO kernel.product_catalog (
    product_id, product_code, product_name, category,
    base_price, currency_code, description
) VALUES (
    '00000000-0000-0000-0000-000000000202'::UUID,
    'REPAIR-SCREEN-01',
    'Screen Replacement',
    'repair_service',
    149.99,
    'USD',
    'Professional screen replacement with quality parts'
)
ON CONFLICT (product_code) DO NOTHING;

-- =============================================================================
-- CONTRACT TEMPLATES
-- =============================================================================

-- Basic device protection contract
INSERT INTO kernel.product_contract_templates (
    contract_template_id, contract_code, name, product_type,
    terms_json, terms_hash, effective_from, status
) VALUES (
    '00000000-0000-0000-0000-000000000300'::UUID,
    'DEV-PROT-001',
    'Standard Device Protection',
    'insurance',
    '{
        "coverage": {
            "accidental_damage": true,
            "liquid_damage": true,
            "theft": false,
            "loss": false
        },
        "deductible": 99.00,
        "claim_limit": 2,
        "waiting_period_days": 14
    }'::JSONB,
    encode(digest('{
        "coverage": {
            "accidental_damage": true,
            "liquid_damage": true,
            "theft": false,
            "loss": false
        },
        "deductible": 99.00,
        "claim_limit": 2,
        "waiting_period_days": 14
    }'::TEXT, 'sha256'), 'hex'),
    '2024-01-01'::DATE,
    'active'
)
ON CONFLICT (contract_code) DO NOTHING;

-- =============================================================================
-- VALUE CONTAINERS (Accounts)
-- =============================================================================

-- Customer wallet
INSERT INTO kernel.value_containers (
    container_id, tenant_id, owner_participant_id,
    container_code, container_name, container_type,
    currency_code, path
) VALUES (
    '00000000-0000-0000-0000-000000000400'::UUID,
    '00000000-0000-0000-0000-000000000002'::UUID,
    '00000000-0000-0000-0000-000000000030'::UUID,
    'WALLET-001',
    'John Demo Wallet',
    'asset',
    'USD',
    'customers.demo.john.wallet'
)
ON CONFLICT (container_id) DO NOTHING;

-- Insurer premium account
INSERT INTO kernel.value_containers (
    container_id, tenant_id, owner_participant_id,
    container_code, container_name, container_type,
    currency_code, path
) VALUES (
    '00000000-0000-0000-0000-000000000401'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000020'::UUID,
    'PREMIUM-001',
    'Demo Insurance Premium Account',
    'income',
    'USD',
    'insurers.demo.premiums'
)
ON CONFLICT (container_id) DO NOTHING;

-- Insurer claims reserve
INSERT INTO kernel.value_containers (
    container_id, tenant_id, owner_participant_id,
    container_code, container_name, container_type,
    currency_code, path
) VALUES (
    '00000000-0000-0000-0000-000000000402'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000020'::UUID,
    'CLAIMS-RESERVE-001',
    'Demo Insurance Claims Reserve',
    'liability',
    'USD',
    'insurers.demo.reserves.claims'
)
ON CONFLICT (container_id) DO NOTHING;

-- =============================================================================
-- MASTER ACCOUNTS (CASS)
-- =============================================================================

-- Client money master account
INSERT INTO kernel.master_accounts (
    master_account_id, tenant_id, container_id,
    account_type, segregation_type, regulatory_framework,
    master_physical_balance, total_subledger_balance, reconciliation_tolerance
) VALUES (
    '00000000-0000-0000-0000-000000000500'::UUID,
    '00000000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000401'::UUID,
    'fbo_master',
    'client_money',
    'CASS',
    0, 0, 0.01
)
ON CONFLICT (master_account_id) DO NOTHING;

-- =============================================================================
-- CURRENCIES
-- =============================================================================

INSERT INTO kernel.currencies (currency_code, currency_name, numeric_code, minor_units)
VALUES 
    ('USD', 'US Dollar', 840, 2),
    ('EUR', 'Euro', 978, 2),
    ('GBP', 'British Pound', 826, 2),
    ('JPY', 'Japanese Yen', 392, 0),
    ('CHF', 'Swiss Franc', 756, 2),
    ('SGD', 'Singapore Dollar', 702, 2),
    ('AUD', 'Australian Dollar', 36, 2),
    ('CAD', 'Canadian Dollar', 124, 2),
    ('HKD', 'Hong Kong Dollar', 344, 2)
ON CONFLICT (currency_code) DO NOTHING;

-- =============================================================================
-- COUNTRIES
-- =============================================================================

INSERT INTO kernel.countries (country_code, country_name, region)
VALUES 
    ('US', 'United States', 'North America'),
    ('GB', 'United Kingdom', 'Europe'),
    ('DE', 'Germany', 'Europe'),
    ('FR', 'France', 'Europe'),
    ('JP', 'Japan', 'Asia'),
    ('SG', 'Singapore', 'Asia'),
    ('CH', 'Switzerland', 'Europe'),
    ('AU', 'Australia', 'Oceania'),
    ('CA', 'Canada', 'North America'),
    ('HK', 'Hong Kong', 'Asia'),
    ('NL', 'Netherlands', 'Europe'),
    ('LU', 'Luxembourg', 'Europe')
ON CONFLICT (country_code) DO NOTHING;

-- =============================================================================
-- NODES
-- =============================================================================

INSERT INTO kernel.nodes (node_id, node_name, node_type, host_address, data_center, status)
VALUES 
    ('00000000-0000-0000-0000-000000000600'::UUID, 'primary-db', 'primary', '127.0.0.1'::INET, 'us-east-1', 'active'),
    ('00000000-0000-0000-0000-000000000601'::UUID, 'replica-db-1', 'replica', '127.0.0.1'::INET, 'us-east-1', 'active'),
    ('00000000-0000-0000-0000-000000000602'::UUID, 'replica-db-2', 'replica', '127.0.0.1'::INET, 'eu-west-1', 'active')
ON CONFLICT (node_name) DO NOTHING;

-- =============================================================================
-- PRODUCT DISCOUNTS
-- =============================================================================

INSERT INTO kernel.product_discounts (discount_id, product_id, discount_code, discount_amount, discount_type, valid_from, valid_to, max_uses)
VALUES 
    ('00000000-0000-0000-0000-000000000700'::UUID, 
     '00000000-0000-0000-0000-000000000200'::UUID,  -- SCREEN-PRO-01
     'WELCOME10', 5.00, 'fixed', '2024-01-01'::TIMESTAMP WITH TIME ZONE, '2024-12-31'::TIMESTAMP WITH TIME ZONE, 1000),
    ('00000000-0000-0000-0000-000000000701'::UUID,
     '00000000-0000-0000-0000-000000000201'::UUID,  -- DEVICE-PRO-01
     'PROTECT20', 4.00, 'fixed', '2024-01-01'::TIMESTAMP WITH TIME ZONE, '2024-12-31'::TIMESTAMP WITH TIME ZONE, 500)
ON CONFLICT (product_id, discount_code) DO NOTHING;

-- =============================================================================
-- SEED DATA COMPLETION
-- =============================================================================

SELECT 'Seed Data: Development and test data loaded' AS status;
