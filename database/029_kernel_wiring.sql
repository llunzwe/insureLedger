-- =============================================================================
-- FILE: 029_kernel_wiring.sql
-- PURPOSE: Kernel Wiring - RLS policies, foreign key links, cross-module integration
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Row Level Security, Tenant Isolation
-- DEPENDENCIES: All previous primitives
-- =============================================================================

-- =============================================================================
-- ROW LEVEL SECURITY POLICIES
-- =============================================================================

-- Enable RLS on all tenant-scoped tables
ALTER TABLE kernel.participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.technician_tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.insurance_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.repair_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.sales_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.value_containers ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.sub_accounts ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- RLS POLICY: Tenant Isolation
-- =============================================================================

-- Participants: Users can only see participants in their tenant
CREATE POLICY tenant_participant_isolation ON kernel.participants
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR security.get_tenant_context() IS NULL
        OR EXISTS (
            SELECT 1 FROM kernel.roles r
            JOIN kernel.user_roles ur ON r.role_id = ur.role_id
            WHERE ur.user_id = security.get_participant_context()
              AND r.role_code = 'super_admin'
        )
    );

-- Technician Tenants: Strict tenant isolation
CREATE POLICY tenant_technician_isolation ON kernel.technician_tenants
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR security.get_tenant_context() IS NULL
    );

-- Devices: Owner or tenant access
CREATE POLICY tenant_device_isolation ON kernel.devices
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR current_owner_id = security.get_participant_context()
        OR security.get_tenant_context() IS NULL
    );

-- Insurance Policies: Insurer, policyholder, or tenant access
CREATE POLICY tenant_policy_isolation ON kernel.insurance_policies
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR insurer_id = security.get_participant_context()
        OR policyholder_id = security.get_participant_context()
        OR security.get_tenant_context() IS NULL
    );

-- Claims: Claimant, insurer, or tenant access
CREATE POLICY tenant_claim_isolation ON kernel.claims
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR EXISTS (
            SELECT 1 FROM kernel.insurance_policies p
            WHERE p.policy_id = kernel.claims.policy_id
              AND (p.insurer_id = security.get_participant_context()
                   OR p.policyholder_id = security.get_participant_context())
        )
        OR security.get_tenant_context() IS NULL
    );

-- Repair Orders: Service provider, customer, or tenant access
CREATE POLICY tenant_repair_isolation ON kernel.repair_orders
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR service_provider_id = security.get_participant_context()
        OR customer_id = security.get_participant_context()
        OR security.get_tenant_context() IS NULL
    );

-- Sales Orders: Customer or tenant access
CREATE POLICY tenant_sales_isolation ON kernel.sales_orders
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR customer_id = security.get_participant_context()
        OR security.get_tenant_context() IS NULL
    );

-- Value Containers: Owner or tenant access
CREATE POLICY tenant_container_isolation ON kernel.value_containers
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR owner_participant_id = security.get_participant_context()
        OR security.get_tenant_context() IS NULL
    );

-- Sub Accounts: Owner or master account access
CREATE POLICY tenant_subaccount_isolation ON kernel.sub_accounts
    FOR ALL
    USING (
        tenant_id = security.get_tenant_context()::UUID
        OR owner_participant_id = security.get_participant_context()
        OR EXISTS (
            SELECT 1 FROM kernel.master_accounts ma
            WHERE ma.master_account_id = kernel.sub_accounts.master_account_id
              AND ma.tenant_id = security.get_tenant_context()::UUID
        )
        OR security.get_tenant_context() IS NULL
    );

-- =============================================================================
-- CROSS-MODULE INTEGRATION FUNCTIONS
-- =============================================================================

-- Link claim to repair order
CREATE OR REPLACE FUNCTION kernel.link_claim_to_repair(
    p_claim_id UUID,
    p_repair_order_id UUID
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.claims
    SET repair_order_id = p_repair_order_id
    WHERE claim_id = p_claim_id;
    
    UPDATE kernel.repair_orders
    SET claim_id = p_claim_id
    WHERE repair_order_id = p_repair_order_id;
END;
$$ LANGUAGE plpgsql;

-- Link policy to device
CREATE OR REPLACE FUNCTION kernel.link_policy_to_device(
    p_policy_id UUID,
    p_device_id UUID
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.insurance_policies
    SET device_id = p_device_id
    WHERE policy_id = p_policy_id;
END;
$$ LANGUAGE plpgsql;

-- Create claim from sales order (for device protection plans)
CREATE OR REPLACE FUNCTION kernel.create_claim_from_sales(
    p_sales_order_id UUID,
    p_incident_date TIMESTAMP WITH TIME ZONE,
    p_incident_type kernel.incident_type,
    p_description TEXT
)
RETURNS UUID AS $$
DECLARE
    v_policy_id UUID;
    v_claim_id UUID;
BEGIN
    SELECT insurance_policy_id INTO v_policy_id
    FROM kernel.sales_orders
    WHERE sales_order_id = p_sales_order_id;
    
    IF v_policy_id IS NULL THEN
        RAISE EXCEPTION 'No insurance policy associated with this sales order';
    END IF;
    
    SELECT kernel.file_claim(v_policy_id, p_incident_date, p_incident_type, p_description)
    INTO v_claim_id;
    
    RETURN v_claim_id;
END;
$$ LANGUAGE plpgsql;

-- Get customer dashboard summary
CREATE OR REPLACE FUNCTION kernel.get_customer_summary(p_participant_id UUID)
RETURNS TABLE (
    device_count INTEGER,
    active_policies INTEGER,
    open_claims INTEGER,
    pending_repairs INTEGER,
    total_premium_paid DECIMAL(15, 2),
    total_claims_paid DECIMAL(15, 2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        (SELECT COUNT(*) FROM kernel.devices WHERE current_owner_id = p_participant_id AND system_to IS NULL)::INTEGER,
        (SELECT COUNT(*) FROM kernel.insurance_policies WHERE policyholder_id = p_participant_id AND status = 'active' AND system_to IS NULL)::INTEGER,
        (SELECT COUNT(*) FROM kernel.claims c 
         JOIN kernel.insurance_policies p ON c.policy_id = p.policy_id 
         WHERE p.policyholder_id = p_participant_id AND c.status IN ('filed', 'under_review') AND c.system_to IS NULL)::INTEGER,
        (SELECT COUNT(*) FROM kernel.repair_orders WHERE customer_id = p_participant_id AND status NOT IN ('completed', 'cancelled', 'delivered') AND system_to IS NULL)::INTEGER,
        (SELECT COALESCE(SUM(total_paid_to_date), 0) FROM kernel.insurance_policies WHERE policyholder_id = p_participant_id),
        (SELECT COALESCE(SUM(actual_payout_amount), 0) FROM kernel.claims c 
         JOIN kernel.insurance_policies p ON c.policy_id = p.policy_id 
         WHERE p.policyholder_id = p_participant_id)
    ;
END;
$$ LANGUAGE plpgsql;

-- Get insurer dashboard summary
CREATE OR REPLACE FUNCTION kernel.get_insurer_summary(p_insurer_id UUID)
RETURNS TABLE (
    total_policies INTEGER,
    active_policies INTEGER,
    pending_claims INTEGER,
    total_premium_revenue DECIMAL(15, 2),
    total_claims_paid DECIMAL(15, 2),
    loss_ratio DECIMAL(5, 2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        (SELECT COUNT(*) FROM kernel.insurance_policies WHERE insurer_id = p_insurer_id)::INTEGER,
        (SELECT COUNT(*) FROM kernel.insurance_policies WHERE insurer_id = p_insurer_id AND status = 'active' AND system_to IS NULL)::INTEGER,
        (SELECT COUNT(*) FROM kernel.claims c 
         JOIN kernel.insurance_policies p ON c.policy_id = p.policy_id 
         WHERE p.insurer_id = p_insurer_id AND c.status IN ('filed', 'under_review'))::INTEGER,
        (SELECT COALESCE(SUM(total_paid_to_date), 0) FROM kernel.insurance_policies WHERE insurer_id = p_insurer_id),
        (SELECT COALESCE(SUM(actual_payout_amount), 0) FROM kernel.claims c 
         JOIN kernel.insurance_policies p ON c.policy_id = p.policy_id 
         WHERE p.insurer_id = p_insurer_id),
        (SELECT CASE 
            WHEN COALESCE(SUM(pol.total_paid_to_date), 0) = 0 THEN 0
            ELSE COALESCE(SUM(c.actual_payout_amount), 0) / NULLIF(SUM(pol.total_paid_to_date), 0)
        END
        FROM kernel.insurance_policies pol
        LEFT JOIN kernel.claims c ON pol.policy_id = c.policy_id
        WHERE pol.insurer_id = p_insurer_id)::DECIMAL(5, 2)
    ;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TENANT CONTEXT MANAGEMENT
-- =============================================================================

-- Set tenant context for session
CREATE OR REPLACE FUNCTION security.set_tenant_session(p_tenant_id UUID)
RETURNS VOID AS $$
BEGIN
    PERFORM set_config('app.current_tenant_id', p_tenant_id::TEXT, FALSE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get tenant context (helper for RLS)
CREATE OR REPLACE FUNCTION security.get_tenant_context()
RETURNS TEXT AS $$
BEGIN
    RETURN current_setting('app.current_tenant_id', TRUE);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Set participant context for session
CREATE OR REPLACE FUNCTION security.set_participant_session(p_participant_id UUID)
RETURNS VOID AS $$
BEGIN
    PERFORM set_config('app.current_participant_id', p_participant_id::TEXT, FALSE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get participant context (helper for audit)
CREATE OR REPLACE FUNCTION security.get_participant_context()
RETURNS UUID AS $$
DECLARE
    v_participant_id TEXT;
BEGIN
    v_participant_id := current_setting('app.current_participant_id', TRUE);
    IF v_participant_id IS NULL OR v_participant_id = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_participant_id::UUID;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- IMMUTABILITY ENFORCEMENT
-- =============================================================================

-- Prevent updates to immutable tables
CREATE OR REPLACE FUNCTION kernel.enforce_immutability()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Table % is immutable. Updates are not allowed.', TG_TABLE_NAME;
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Table % is immutable. Deletes are not allowed.', TG_TABLE_NAME;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Apply immutability to datoms
CREATE TRIGGER trg_datoms_immutable
    BEFORE UPDATE OR DELETE ON kernel.datoms
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

-- Apply immutability to other core immutable tables
CREATE TRIGGER trg_participants_immutable
    BEFORE UPDATE OR DELETE ON kernel.participants
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_devices_immutable
    BEFORE UPDATE OR DELETE ON kernel.devices
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_value_movements_immutable
    BEFORE UPDATE OR DELETE ON kernel.value_movements
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_movement_legs_immutable
    BEFORE UPDATE OR DELETE ON kernel.movement_legs
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_insurance_policies_immutable
    BEFORE UPDATE OR DELETE ON kernel.insurance_policies
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_claims_immutable
    BEFORE UPDATE OR DELETE ON kernel.claims
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_sales_orders_immutable
    BEFORE UPDATE OR DELETE ON kernel.sales_orders
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_payments_immutable
    BEFORE UPDATE OR DELETE ON kernel.payments
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

CREATE TRIGGER trg_documents_immutable
    BEFORE UPDATE OR DELETE ON kernel.documents
    FOR EACH STATEMENT EXECUTE FUNCTION kernel.enforce_immutability();

-- Note: For bitemporal tables, immutability means append-only.
-- Updates are implemented as new inserts with system_to set on old record.
-- These triggers prevent direct modifications, enforcing append-only semantics.

-- =============================================================================
-- HASH CHAIN VERIFICATION
-- =============================================================================

-- Verify hash chain for a table
CREATE OR REPLACE FUNCTION kernel.verify_table_hash_chain(p_table_name TEXT)
RETURNS TABLE (
    record_id UUID,
    expected_hash TEXT,
    actual_hash TEXT,
    is_valid BOOLEAN
) AS $$
BEGIN
    RETURN QUERY EXECUTE format(
        'SELECT 
            id::UUID as record_id,
            current_hash as expected_hash,
            encode(digest(
                COALESCE(previous_hash, '''') || id::TEXT || COALESCE(current_hash, ''''),
                ''sha256''
            ), ''hex'') as actual_hash,
            current_hash = encode(digest(
                COALESCE(previous_hash, '''') || id::TEXT || COALESCE(current_hash, ''''),
                ''sha256''
            ), ''hex'') as is_valid
        FROM kernel.%I
        WHERE immutable_flag = TRUE',
        p_table_name
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INTEGRITY CHECK FUNCTION
-- =============================================================================

-- Full system integrity check
CREATE OR REPLACE FUNCTION kernel.system_integrity_check()
RETURNS TABLE (
    check_name TEXT,
    status TEXT,
    details JSONB
) AS $$
BEGIN
    -- Check 1: Value conservation
    RETURN QUERY
    SELECT 
        'Value Conservation'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
        jsonb_build_object('violations', COUNT(*))
    FROM kernel.value_movements
    WHERE total_debits != total_credits;
    
    -- Check 2: Hash chain integrity
    RETURN QUERY
    SELECT 
        'Hash Chain Integrity (datoms)'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
        jsonb_build_object('broken_chains', COUNT(*))
    FROM kernel.datoms
    WHERE previous_datom_hash IS NOT NULL
      AND previous_datom_hash NOT IN (
          SELECT current_hash FROM kernel.datoms d2 
          WHERE d2.sequence_number = kernel.datoms.sequence_number - 1
      );
    
    -- Check 3: Bitemporal consistency
    RETURN QUERY
    SELECT 
        'Bitemporal Consistency'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
        jsonb_build_object('violations', COUNT(*))
    FROM kernel.insurance_policies
    WHERE system_from > system_to;
    
    -- Check 4: Orphaned records check
    RETURN QUERY
    SELECT 
        'Foreign Key Integrity'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
        jsonb_build_object('orphan_claims', COUNT(*))
    FROM kernel.claims c
    LEFT JOIN kernel.insurance_policies p ON c.policy_id = p.policy_id
    WHERE p.policy_id IS NULL;
    
    -- Check 5: Sub-ledger reconciliation
    RETURN QUERY
    SELECT 
        'Sub-ledger Balance'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
        jsonb_build_object('unbalanced_masters', COUNT(*))
    FROM kernel.master_accounts
    WHERE ABS(reconciliation_gap) > reconciliation_tolerance;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- DEFERRED FOREIGN KEY CONSTRAINTS
-- =============================================================================

-- Add FKs that reference tables created later in the sequence
-- These are added here to avoid circular dependencies during initial creation

-- 004 -> 022: participants.registered_address_id -> addresses.address_id
ALTER TABLE kernel.participants
    ADD CONSTRAINT fk_participants_registered_address
    FOREIGN KEY (registered_address_id) REFERENCES kernel.addresses(address_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 005 -> 010: devices.extended_warranty_policy_id -> insurance_policies.policy_id
ALTER TABLE kernel.devices
    ADD CONSTRAINT fk_devices_warranty_policy
    FOREIGN KEY (extended_warranty_policy_id) REFERENCES kernel.insurance_policies(policy_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 005 -> 011: device_diagnostics.repair_order_id -> repair_orders.repair_order_id
ALTER TABLE kernel.device_diagnostics
    ADD CONSTRAINT fk_device_diagnostics_repair
    FOREIGN KEY (repair_order_id) REFERENCES kernel.repair_orders(repair_order_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 008 -> 007: movement_legs.container_id -> value_containers.container_id
ALTER TABLE kernel.movement_legs
    ADD CONSTRAINT fk_movement_legs_container
    FOREIGN KEY (container_id) REFERENCES kernel.value_containers(container_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 009 -> 007: master_accounts.container_id -> value_containers.container_id
ALTER TABLE kernel.master_accounts
    ADD CONSTRAINT fk_master_accounts_container
    FOREIGN KEY (container_id) REFERENCES kernel.value_containers(container_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 010 -> 015: insurance_policies.product_contract_hash -> product_contract_anchors.contract_hash
ALTER TABLE kernel.insurance_policies
    ADD CONSTRAINT fk_insurance_policies_contract
    FOREIGN KEY (product_contract_hash) REFERENCES kernel.product_contract_anchors(contract_hash)
    DEFERRABLE INITIALLY DEFERRED;

-- 010 -> 011: claims.repair_order_id -> repair_orders.repair_order_id
ALTER TABLE kernel.claims
    ADD CONSTRAINT fk_claims_repair_order
    FOREIGN KEY (repair_order_id) REFERENCES kernel.repair_orders(repair_order_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 012 -> 010: sales_orders.insurance_policy_id -> insurance_policies.policy_id
ALTER TABLE kernel.sales_orders
    ADD CONSTRAINT fk_sales_orders_policy
    FOREIGN KEY (insurance_policy_id) REFERENCES kernel.insurance_policies(policy_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 022 -> 022: jurisdictions.parent_jurisdiction_id -> jurisdictions.jurisdiction_id
ALTER TABLE kernel.jurisdictions
    ADD CONSTRAINT fk_jurisdictions_parent
    FOREIGN KEY (parent_jurisdiction_id) REFERENCES kernel.jurisdictions(jurisdiction_id)
    DEFERRABLE INITIALLY DEFERRED;

-- 002 -> 004: security.participant_keys.participant_id -> kernel.participants.participant_id
ALTER TABLE security.participant_keys
    ADD CONSTRAINT fk_participant_keys_participant
    FOREIGN KEY (participant_id) REFERENCES kernel.participants(participant_id)
    DEFERRABLE INITIALLY DEFERRED;

-- =============================================================================
-- ADDITIONAL RLS TABLES
-- =============================================================================

-- Enable RLS on additional tenant-scoped tables
ALTER TABLE kernel.master_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.sub_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.value_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.movement_legs ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.settlement_instructions ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE kernel.documents ENABLE ROW LEVEL SECURITY;

-- Create policies for additional tables
CREATE POLICY tenant_master_account_isolation ON kernel.master_accounts
    FOR ALL USING (
        tenant_id = security.get_tenant_context()::UUID
        OR security.get_tenant_context() IS NULL
    );

CREATE POLICY tenant_value_movement_isolation ON kernel.value_movements
    FOR ALL USING (
        tenant_id = security.get_tenant_context()::UUID
        OR security.get_tenant_context() IS NULL
    );

CREATE POLICY tenant_payment_isolation ON kernel.payments
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM kernel.sales_orders so
            WHERE so.sales_order_id = kernel.payments.sales_order_id
            AND (so.customer_id = security.get_participant_context()
                 OR so.tenant_id = security.get_tenant_context()::UUID)
        )
        OR security.get_tenant_context() IS NULL
    );

-- =============================================================================
-- SYSTEM STATUS VIEW
-- =============================================================================

CREATE OR REPLACE VIEW kernel.system_status AS
SELECT 
    'InsureLedger Enterprise Kernel' AS system_name,
    '2.0.0' AS version,
    (SELECT COUNT(*) FROM kernel.schema_version) AS schema_versions,
    (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'kernel') AS table_count,
    (SELECT COUNT(*) FROM kernel.participants WHERE is_active = TRUE) AS active_participants,
    (SELECT COUNT(*) FROM kernel.technician_tenants WHERE status = 'active') AS active_tenants,
    (SELECT COUNT(*) FROM kernel.devices WHERE system_to IS NULL) AS registered_devices,
    (SELECT COUNT(*) FROM kernel.insurance_policies WHERE status = 'active' AND system_to IS NULL) AS active_policies,
    (SELECT COUNT(*) FROM kernel.claims WHERE status IN ('filed', 'under_review')) AS pending_claims,
    (SELECT COUNT(*) FROM kernel.value_containers WHERE status = 'open') AS open_containers,
    NOW() AS report_generated_at;

-- =============================================================================
-- SESSION CLEANUP TRIGGER
-- =============================================================================

-- Function to clean expired sessions
CREATE OR REPLACE FUNCTION kernel.cleanup_expired_sessions()
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.sessions
    SET is_active = FALSE, is_valid = FALSE
    WHERE expires_at < NOW()
      AND is_active = TRUE;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Kernel Wiring: RLS policies and cross-module integration initialized' AS status;
