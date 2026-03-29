-- =============================================================================
-- FILE: 011_repair_order.sql
-- PURPOSE: Primitive 11 - Repair Order & Diagnostic
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: ISO 9001, Right to Repair
-- DEPENDENCIES: 005_device_product.sql, 006_agent_relationships.sql
-- =============================================================================

-- =============================================================================
-- REPAIR ORDERS
-- =============================================================================

CREATE TYPE kernel.repair_order_status AS ENUM (
    'created',
    'diagnosing',
    'parts_ordering',
    'in_progress',
    'awaiting_customer_approval',
    'awaiting_insurance_approval',
    'completed',
    'cancelled',
    'delivered'
);

CREATE TYPE kernel.repair_type AS ENUM (
    'screen_replacement',
    'battery_replacement',
    'water_damage',
    'software_repair',
    'hardware_diagnostic',
    'data_recovery',
    'other'
);

CREATE TABLE kernel.repair_orders (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    repair_order_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    order_number TEXT UNIQUE NOT NULL,
    
    -- Device and Customer
    device_id UUID NOT NULL REFERENCES kernel.devices(device_id),
    customer_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Service Provider
    service_provider_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    assigned_technician_id UUID REFERENCES kernel.participants(participant_id),
    
    -- Repair Details
    repair_type kernel.repair_type NOT NULL,
    problem_description TEXT NOT NULL,
    symptoms TEXT[],
    
    -- Quote
    estimated_cost DECIMAL(10, 2),
    final_cost DECIMAL(10, 2),
    
    -- Timestamps
    received_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    diagnosed_at TIMESTAMP WITH TIME ZONE,
    customer_approved_at TIMESTAMP WITH TIME ZONE,
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    delivered_at TIMESTAMP WITH TIME ZONE,
    
    -- Status
    status kernel.repair_order_status DEFAULT 'created',
    status_history JSONB DEFAULT '[]',
    
    -- Insurance/Claim Link
    claim_id UUID,
    insurance_policy_id UUID,
    
    -- Parts Used
    parts_used JSONB DEFAULT '[]',
    labor_hours DECIMAL(5, 2),
    
    -- Quality
    warranty_days INTEGER DEFAULT 90,
    warranty_expires_at TIMESTAMP WITH TIME ZONE,
    quality_check_passed BOOLEAN,
    
    -- Communication
    customer_notified BOOLEAN DEFAULT FALSE,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    CONSTRAINT chk_repair_orders_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_repair_orders_repair ON kernel.repair_orders(repair_order_id);
CREATE INDEX idx_repair_orders_device ON kernel.repair_orders(device_id);
CREATE INDEX idx_repair_orders_status ON kernel.repair_orders(status);
CREATE INDEX idx_repair_orders_customer ON kernel.repair_orders(customer_id);

-- =============================================================================
-- DIAGNOSTIC REPORTS
-- =============================================================================

CREATE TABLE kernel.diagnostic_reports (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    diagnostic_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    repair_order_id UUID REFERENCES kernel.repair_orders(repair_order_id),
    device_id UUID NOT NULL REFERENCES kernel.devices(device_id),
    
    -- Technician
    technician_id UUID REFERENCES kernel.participants(participant_id),
    diagnostic_time TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Hardware Tests
    battery_health DECIMAL(5, 2),  -- Percentage
    screen_condition VARCHAR(32),
    physical_damage JSONB,
    water_damage_indicators BOOLEAN[],
    
    -- Software Tests
    os_version TEXT,
    boot_test_passed BOOLEAN,
    sensor_tests JSONB,
    connectivity_tests JSONB,
    
    -- Findings
    findings_summary TEXT,
    recommended_action VARCHAR(32),  -- repair, replace, no_action
    
    -- Data
    diagnostic_logs TEXT,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_diagnostic_reports_diagnostic ON kernel.diagnostic_reports(diagnostic_id);
CREATE INDEX idx_diagnostic_reports_device ON kernel.diagnostic_reports(device_id);
CREATE INDEX idx_diagnostic_reports_repair ON kernel.diagnostic_reports(repair_order_id);

-- =============================================================================
-- SPARE PARTS INVENTORY
-- =============================================================================

CREATE TABLE kernel.spare_parts (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    part_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    part_number TEXT NOT NULL,
    part_name TEXT NOT NULL,
    manufacturer TEXT,
    compatibility_models TEXT[],
    
    -- Pricing
    unit_cost DECIMAL(10, 2),
    retail_price DECIMAL(10, 2),
    
    -- Stock
    quantity_in_stock INTEGER DEFAULT 0,
    quantity_reserved INTEGER DEFAULT 0,
    reorder_point INTEGER DEFAULT 10,
    
    -- Supplier
    preferred_supplier_id UUID REFERENCES kernel.participants(participant_id),
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_spare_parts_part ON kernel.spare_parts(part_id);
CREATE INDEX idx_spare_parts_number ON kernel.spare_parts(part_number);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION kernel.create_repair_order(
    p_device_id UUID,
    p_customer_id UUID,
    p_service_provider_id UUID,
    p_repair_type kernel.repair_type,
    p_problem_description TEXT,
    p_claim_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_order_id UUID;
    v_order_number TEXT;
BEGIN
    v_order_number := 'REP-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    
    INSERT INTO kernel.repair_orders (
        order_number, device_id, customer_id, service_provider_id,
        repair_type, problem_description, claim_id, created_by
    ) VALUES (
        v_order_number, p_device_id, p_customer_id, p_service_provider_id,
        p_repair_type, p_problem_description, p_claim_id,
        security.get_participant_context()
    )
    RETURNING repair_order_id INTO v_order_id;
    
    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kernel.complete_repair_order(
    p_repair_order_id UUID,
    p_final_cost DECIMAL,
    p_parts_used JSONB DEFAULT NULL,
    p_labor_hours DECIMAL DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.repair_orders
    SET status = 'completed',
        final_cost = p_final_cost,
        completed_at = NOW(),
        parts_used = p_parts_used,
        labor_hours = p_labor_hours,
        warranty_expires_at = NOW() + INTERVAL '90 days',
        last_modified_by = security.get_participant_context(),
        last_modified_at = NOW()
    WHERE repair_order_id = p_repair_order_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 11: Repair Order & Diagnostic initialized' AS status;
