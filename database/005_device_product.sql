-- =============================================================================
-- FILE: 005_device_product.sql
-- PURPOSE: Primitive 2 - Device & Product Registry (devices, catalog, diagnostics)
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 8601, GDPR (device ownership privacy)
-- DEPENDENCIES: 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- DEVICES - Physical device digital twins
-- =============================================================================

CREATE TABLE kernel.devices (
    -- Identity & Immutability
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    -- Device Identity
    device_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    device_type kernel.device_type NOT NULL,
    
    -- Manufacturer & Model
    manufacturer TEXT NOT NULL,
    model_name TEXT NOT NULL,
    model_number TEXT,
    sku TEXT,
    
    -- Hardware Identifiers (unique per device)
    serial_number TEXT NOT NULL,
    imei TEXT,  -- For cellular devices (15 digits)
    mac_addresses JSONB,  -- {wifi: "xx:xx:xx:xx:xx:xx", bluetooth: "..."}
    motherboard_id TEXT,
    chipset_id TEXT,
    secure_element_id TEXT,
    
    -- Software & Firmware
    current_os_version TEXT,
    firmware_version TEXT,
    bootloader_version TEXT,
    
    -- Lifecycle
    manufacture_date DATE,
    first_activation_at TIMESTAMP WITH TIME ZONE,
    
    -- Warranty
    original_warranty_start DATE,
    original_warranty_end DATE,
    extended_warranty_policy_id UUID,
    
    -- Ownership (links to participants)
    current_owner_id UUID REFERENCES kernel.participants(participant_id),
    previous_owner_id UUID REFERENCES kernel.participants(participant_id),
    acquisition_date DATE,
    sales_transaction_id UUID,
    
    -- Status
    operational_status VARCHAR(32) DEFAULT 'active',  -- active, stolen, damaged, decommissioned
    lock_status VARCHAR(32) DEFAULT 'unlocked',  -- unlocked, locked, recovery_mode
    
    -- Location (last known)
    last_known_location JSONB,  -- {lat, lon, accuracy, timestamp, source}
    
    -- Digital Twin
    digital_twin_hash TEXT,  -- Cryptographic fingerprint of device identity
    blockchain_anchor_id UUID,
    
    -- Bitemporal Tracking
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit Trail
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    -- Multi-tenancy (NULL for devices - owned by customers)
    tenant_id UUID,
    
    -- Verification
    signature TEXT,
    proof_inclusion UUID,
    
    -- Constraints
    CONSTRAINT chk_devices_temporal_system 
        CHECK (system_from <= system_to OR system_to IS NULL),
    CONSTRAINT chk_devices_temporal_valid 
        CHECK (valid_from <= valid_to OR valid_to IS NULL),
    CONSTRAINT chk_devices_imei_format 
        CHECK (imei IS NULL OR imei ~ '^[0-9]{14,16}$')
);

COMMENT ON TABLE kernel.devices IS 'Physical device digital twins with full provenance tracking';

CREATE INDEX idx_devices_device_id ON kernel.devices(device_id);
CREATE INDEX idx_devices_type ON kernel.devices(device_type);
CREATE INDEX idx_devices_manufacturer ON kernel.devices(manufacturer);
CREATE INDEX idx_devices_serial ON kernel.devices(serial_number);
CREATE INDEX idx_devices_imei ON kernel.devices(imei) WHERE imei IS NOT NULL;
CREATE INDEX idx_devices_owner ON kernel.devices(current_owner_id);
CREATE INDEX idx_devices_system_current ON kernel.devices(system_from, system_to) WHERE system_to IS NULL;
CREATE INDEX idx_devices_operational_status ON kernel.devices(operational_status);

-- =============================================================================
-- PRODUCT CATALOG - Insurance plans, repair services, ecommerce items
-- =============================================================================

CREATE TYPE kernel.product_type AS ENUM (
    'insurance_policy',
    'repair_service',
    'ecommerce_item',
    'warranty_extension',
    'protection_plan'
);

CREATE TABLE kernel.product_catalog (
    -- Identity & Immutability
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    -- Product Identity
    product_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Classification
    product_type kernel.product_type NOT NULL,
    product_category VARCHAR(32),  -- comprehensive, screen_only, accidental, etc.
    
    -- Naming
    product_code VARCHAR(32) UNIQUE NOT NULL,
    product_name TEXT NOT NULL,
    product_description TEXT,
    
    -- Pricing
    base_price DECIMAL(15, 2),
    base_currency CHAR(3) DEFAULT 'USD',
    pricing_model VARCHAR(32),  -- fixed, dynamic, tiered
    
    -- Product-specific attributes (flexible schema)
    coverage_details JSONB,  -- For insurance
    repair_services JSONB,   -- For repair
    physical_attributes JSONB,  -- For ecommerce (weight, dimensions)
    
    -- Status
    status VARCHAR(16) DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'deprecated', 'retired')),
    
    -- Bitemporal
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    -- Verification
    signature TEXT,
    
    CONSTRAINT chk_product_catalog_temporal 
        CHECK (system_from <= system_to OR system_to IS NULL)
);

COMMENT ON TABLE kernel.product_catalog IS 'Product definitions for insurance, repair, and ecommerce';

CREATE INDEX idx_product_catalog_product ON kernel.product_catalog(product_id);
CREATE INDEX idx_product_catalog_code ON kernel.product_catalog(product_code);
CREATE INDEX idx_product_catalog_type ON kernel.product_catalog(product_type, product_category);
CREATE INDEX idx_product_catalog_status ON kernel.product_catalog(status) WHERE status = 'active';

-- =============================================================================
-- DEVICE DIAGNOSTICS - Historical diagnostic records
-- =============================================================================

CREATE TABLE kernel.device_diagnostics (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    diagnostic_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    tenant_id UUID,
    
    -- Context
    device_id UUID NOT NULL REFERENCES kernel.devices(device_id),
    repair_order_id UUID,  -- Optional link to repair
    
    diagnostic_type VARCHAR(32) DEFAULT 'pre_repair',  -- pre_repair, post_repair, routine
    diagnostic_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    technician_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Test Suite
    test_suite_version TEXT,
    test_results JSONB NOT NULL,  -- [{test_name, status, value, threshold, passed}]
    
    -- Detected Issues
    detected_faults JSONB,  -- [{fault_code, severity, component, description}]
    device_health_score INTEGER CHECK (device_health_score BETWEEN 0 AND 100),
    
    -- Hardware Details
    battery_health_percent INTEGER CHECK (battery_health_percent BETWEEN 0 AND 100),
    storage_health_percent INTEGER CHECK (storage_health_percent BETWEEN 0 AND 100),
    thermal_status VARCHAR(32),
    
    -- Verification
    technician_signature TEXT,
    device_self_test_signature TEXT,  -- From device secure element
    
    -- Anchoring
    diagnostic_data_hash TEXT,
    blockchain_anchor_id UUID,
    
    -- Bitemporal
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Audit
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_device_diagnostics_temporal 
        CHECK (system_from <= system_to OR system_to IS NULL)
);

COMMENT ON TABLE kernel.device_diagnostics IS 'Device health diagnostics with test results and fault detection';

CREATE INDEX idx_device_diagnostics_id ON kernel.device_diagnostics(diagnostic_id);
CREATE INDEX idx_device_diagnostics_device ON kernel.device_diagnostics(device_id);
CREATE INDEX idx_device_diagnostics_repair ON kernel.device_diagnostics(repair_order_id) WHERE repair_order_id IS NOT NULL;
CREATE INDEX idx_device_diagnostics_type ON kernel.device_diagnostics(diagnostic_type);

-- =============================================================================
-- RLS POLICIES
-- =============================================================================

ALTER TABLE kernel.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.product_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.device_diagnostics ENABLE ROW LEVEL SECURITY;

-- Device access policies
CREATE POLICY devices_owner_access ON kernel.devices
    USING (
        current_owner_id = security.get_participant_context()
        OR previous_owner_id = security.get_participant_context()
    );

CREATE POLICY devices_insurer_access ON kernel.devices
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM kernel.insurance_policies ip
            WHERE ip.device_id = devices.device_id
              AND ip.insurer_id = security.get_participant_context()
        )
    );

-- Product catalog - public read for active products
CREATE POLICY product_catalog_public ON kernel.product_catalog
    FOR SELECT
    USING (status = 'active');

-- Diagnostics - restricted access
CREATE POLICY device_diagnostics_owner ON kernel.device_diagnostics
    USING (
        EXISTS (
            SELECT 1 FROM kernel.devices d
            WHERE d.device_id = device_diagnostics.device_id
              AND d.current_owner_id = security.get_participant_context()
        )
    );

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Register a new device
CREATE OR REPLACE FUNCTION kernel.register_device(
    p_device_type kernel.device_type,
    p_manufacturer TEXT,
    p_model_name TEXT,
    p_model_number TEXT DEFAULT NULL,
    p_serial_number TEXT DEFAULT NULL,
    p_imei TEXT DEFAULT NULL,
    p_manufacture_date DATE DEFAULT NULL,
    p_current_owner_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_device_id UUID;
BEGIN
    INSERT INTO kernel.devices (
        device_type, manufacturer, model_name, model_number,
        serial_number, imei, manufacture_date, current_owner_id,
        created_by
    ) VALUES (
        p_device_type, p_manufacturer, p_model_name, p_model_number,
        COALESCE(p_serial_number, crypto.generate_nonce()),
        p_imei, p_manufacture_date, p_current_owner_id,
        security.get_participant_context()
    )
    RETURNING device_id INTO v_device_id;
    
    -- Initialize entity stream
    PERFORM kernel.init_entity_stream('device', v_device_id);
    
    RETURN v_device_id;
END;
$$ LANGUAGE plpgsql;

-- Transfer device ownership
CREATE OR REPLACE FUNCTION kernel.transfer_device_ownership(
    p_device_id UUID,
    p_new_owner_id UUID,
    p_sales_transaction_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_old_owner_id UUID;
    v_new_record_id UUID;
BEGIN
    SELECT current_owner_id INTO v_old_owner_id
    FROM kernel.devices
    WHERE device_id = p_device_id
      AND system_to IS NULL;
    
    IF v_old_owner_id IS NULL THEN
        RAISE EXCEPTION 'Device not found or not active: %', p_device_id;
    END IF;
    
    -- Expire current record
    UPDATE kernel.devices
    SET system_to = NOW(),
        valid_to = NOW()
    WHERE device_id = p_device_id
      AND system_to IS NULL;
    
    -- Insert new version
    INSERT INTO kernel.devices (
        device_id, device_type, manufacturer, model_name, model_number,
        serial_number, imei, manufacture_date, original_warranty_start, original_warranty_end,
        current_owner_id, previous_owner_id, acquisition_date, sales_transaction_id,
        operational_status, valid_from, created_by
    )
    SELECT 
        device_id, device_type, manufacturer, model_name, model_number,
        serial_number, imei, manufacture_date, original_warranty_start, original_warranty_end,
        p_new_owner_id, v_old_owner_id, CURRENT_DATE, p_sales_transaction_id,
        operational_status, NOW(), security.get_participant_context()
    FROM kernel.devices
    WHERE device_id = p_device_id
    ORDER BY system_from DESC
    LIMIT 1
    RETURNING id INTO v_new_record_id;
    
    RETURN v_new_record_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 2: Device & Product Registry initialized' AS status;
