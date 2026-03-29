-- =============================================================================
-- FILE: 031_audit_triggers.sql
-- PURPOSE: Comprehensive audit logging triggers
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Immutable audit trail, Change tracking
-- DEPENDENCIES: audit schema, all kernel tables
-- =============================================================================

-- =============================================================================
-- AUDIT LOG TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.audit_log (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    -- Event identification
    event_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    event_type VARCHAR(32) NOT NULL,  -- INSERT, UPDATE, DELETE, TRUNCATE
    event_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Table information
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    
    -- Record identification
    record_id UUID,
    primary_key_values JSONB,
    
    -- Change details
    old_data JSONB,
    new_data JSONB,
    changed_fields TEXT[],
    
    -- Context
    transaction_id BIGINT,
    application_name TEXT,
    client_ip INET,
    
    -- User information
    session_user_name TEXT,
    current_user_name TEXT,
    participant_id UUID,
    tenant_id UUID,
    
    -- Query information
    query_text TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for audit log queries
CREATE INDEX IF NOT EXISTS idx_audit_log_timestamp ON audit.audit_log(event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_table ON audit.audit_log(schema_name, table_name, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_record ON audit.audit_log(record_id, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_participant ON audit.audit_log(participant_id, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_tenant ON audit.audit_log(tenant_id, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit.audit_log(event_type, event_timestamp DESC);

-- Partition by month for scalability
-- CREATE TABLE audit.audit_log_2024_01 PARTITION OF audit.audit_log
--     FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- =============================================================================
-- AUDIT TRIGGER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.audit_trigger_func()
RETURNS TRIGGER AS $$
DECLARE
    v_old_data JSONB;
    v_new_data JSONB;
    v_changed_fields TEXT[];
    v_record_id UUID;
    v_primary_key_values JSONB;
BEGIN
    -- Get primary key (assuming 'id' column exists)
    IF TG_OP = 'DELETE' THEN
        v_record_id := OLD.id;
        v_primary_key_values := jsonb_build_object('id', OLD.id);
    ELSE
        v_record_id := NEW.id;
        v_primary_key_values := jsonb_build_object('id', NEW.id);
    END IF;
    
    -- Build data JSON
    IF TG_OP = 'INSERT' THEN
        v_old_data := NULL;
        v_new_data := to_jsonb(NEW);
        v_changed_fields := ARRAY(SELECT key FROM jsonb_each_text(v_new_data));
    ELSIF TG_OP = 'UPDATE' THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := to_jsonb(NEW);
        v_changed_fields := ARRAY(
            SELECT key 
            FROM jsonb_each_text(v_new_data)
            WHERE v_new_data->key IS DISTINCT FROM v_old_data->key
        );
        
        -- Skip if no actual changes
        IF array_length(v_changed_fields, 1) IS NULL THEN
            RETURN COALESCE(NEW, OLD);
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := NULL;
        v_changed_fields := ARRAY(SELECT key FROM jsonb_each_text(v_old_data));
    END IF;
    
    -- Insert audit record
    INSERT INTO audit.audit_log (
        event_type, schema_name, table_name, record_id, primary_key_values,
        old_data, new_data, changed_fields, transaction_id, application_name,
        session_user_name, current_user_name, participant_id, tenant_id, query_text
    ) VALUES (
        TG_OP,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        v_record_id,
        v_primary_key_values,
        v_old_data,
        v_new_data,
        v_changed_fields,
        txid_current(),
        current_setting('application_name', TRUE),
        session_user,
        current_user,
        security.get_participant_context(),
        security.get_tenant_context()::UUID,
        current_query()
    );
    
    RETURN COALESCE(NEW, OLD);
EXCEPTION WHEN OTHERS THEN
    -- Log error but don't block the operation
    RAISE WARNING 'Audit logging failed: %', SQLERRM;
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- APPLY AUDIT TRIGGERS
-- =============================================================================

-- Core entities
DROP TRIGGER IF EXISTS audit_participants ON kernel.participants;
CREATE TRIGGER audit_participants
    AFTER INSERT OR UPDATE OR DELETE ON kernel.participants
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_devices ON kernel.devices;
CREATE TRIGGER audit_devices
    AFTER INSERT OR UPDATE OR DELETE ON kernel.devices
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_agent_relationships ON kernel.agent_relationships;
CREATE TRIGGER audit_agent_relationships
    AFTER INSERT OR UPDATE OR DELETE ON kernel.agent_relationships
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Financial
DROP TRIGGER IF EXISTS audit_value_containers ON kernel.value_containers;
CREATE TRIGGER audit_value_containers
    AFTER INSERT OR UPDATE OR DELETE ON kernel.value_containers
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_value_movements ON kernel.value_movements;
CREATE TRIGGER audit_value_movements
    AFTER INSERT OR UPDATE OR DELETE ON kernel.value_movements
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_sub_accounts ON kernel.sub_accounts;
CREATE TRIGGER audit_sub_accounts
    AFTER INSERT OR UPDATE OR DELETE ON kernel.sub_accounts
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_master_accounts ON kernel.master_accounts;
CREATE TRIGGER audit_master_accounts
    AFTER INSERT OR UPDATE OR DELETE ON kernel.master_accounts
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Insurance
DROP TRIGGER IF EXISTS audit_insurance_policies ON kernel.insurance_policies;
CREATE TRIGGER audit_insurance_policies
    AFTER INSERT OR UPDATE OR DELETE ON kernel.insurance_policies
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_claims ON kernel.claims;
CREATE TRIGGER audit_claims
    AFTER INSERT OR UPDATE OR DELETE ON kernel.claims
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_repair_orders ON kernel.repair_orders;
CREATE TRIGGER audit_repair_orders
    AFTER INSERT OR UPDATE OR DELETE ON kernel.repair_orders
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Commerce
DROP TRIGGER IF EXISTS audit_sales_orders ON kernel.sales_orders;
CREATE TRIGGER audit_sales_orders
    AFTER INSERT OR UPDATE OR DELETE ON kernel.sales_orders
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_payments ON kernel.payments;
CREATE TRIGGER audit_payments
    AFTER INSERT OR UPDATE OR DELETE ON kernel.payments
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Documents
DROP TRIGGER IF EXISTS audit_documents ON kernel.documents;
CREATE TRIGGER audit_documents
    AFTER INSERT OR UPDATE OR DELETE ON kernel.documents
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Access Control
DROP TRIGGER IF EXISTS audit_user_roles ON kernel.user_roles;
CREATE TRIGGER audit_user_roles
    AFTER INSERT OR UPDATE OR DELETE ON kernel.user_roles
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_sessions ON kernel.sessions;
CREATE TRIGGER audit_sessions
    AFTER INSERT OR UPDATE OR DELETE ON kernel.sessions
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Configuration & Settings
DROP TRIGGER IF EXISTS audit_technician_tenants ON kernel.technician_tenants;
CREATE TRIGGER audit_technician_tenants
    AFTER INSERT OR UPDATE OR DELETE ON kernel.technician_tenants
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Settlement & Reconciliation
DROP TRIGGER IF EXISTS audit_settlement_instructions ON kernel.settlement_instructions;
CREATE TRIGGER audit_settlement_instructions
    AFTER INSERT OR UPDATE OR DELETE ON kernel.settlement_instructions
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_clearing_batches ON kernel.clearing_batches;
CREATE TRIGGER audit_clearing_batches
    AFTER INSERT OR UPDATE OR DELETE ON kernel.clearing_batches
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_reconciliation_runs ON kernel.reconciliation_runs;
CREATE TRIGGER audit_reconciliation_runs
    AFTER INSERT OR UPDATE OR DELETE ON kernel.reconciliation_runs
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- Product & Contracts
DROP TRIGGER IF EXISTS audit_product_catalog ON kernel.product_catalog;
CREATE TRIGGER audit_product_catalog
    AFTER INSERT OR UPDATE OR DELETE ON kernel.product_catalog
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

DROP TRIGGER IF EXISTS audit_product_contract_templates ON kernel.product_contract_templates;
CREATE TRIGGER audit_product_contract_templates
    AFTER INSERT OR UPDATE OR DELETE ON kernel.product_contract_templates
    FOR EACH ROW EXECUTE FUNCTION audit.audit_trigger_func();

-- =============================================================================
-- SECURITY AUDIT TRIGGERS
-- =============================================================================

-- Track authentication events
CREATE TABLE IF NOT EXISTS audit.security_events (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    event_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    event_type VARCHAR(64) NOT NULL,  -- login, logout, failed_login, password_change, mfa_challenge
    
    -- User
    participant_id UUID,
    username TEXT,
    
    -- Context
    session_id UUID,
    client_ip INET,
    user_agent TEXT,
    
    -- Result
    success BOOLEAN,
    failure_reason TEXT,
    
    -- Details
    details JSONB,
    
    event_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_security_events_user ON audit.security_events(participant_id, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_type ON audit.security_events(event_type, event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_ip ON audit.security_events(client_ip);

-- Function to log security events
CREATE OR REPLACE FUNCTION audit.log_security_event(
    p_event_type VARCHAR,
    p_participant_id UUID DEFAULT NULL,
    p_success BOOLEAN DEFAULT TRUE,
    p_details JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_event_id UUID;
BEGIN
    INSERT INTO audit.security_events (
        event_type, participant_id, success, details, client_ip, user_agent
    ) VALUES (
        p_event_type, p_participant_id, p_success, p_details,
        inet_client_addr(),
        current_setting('application_name', TRUE)
    )
    RETURNING event_id INTO v_event_id;
    
    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- DATA CHANGE SUMMARY VIEW
-- =============================================================================

CREATE OR REPLACE VIEW audit.daily_change_summary AS
SELECT 
    date_trunc('day', event_timestamp)::DATE AS change_date,
    schema_name,
    table_name,
    event_type,
    COUNT(*) AS event_count,
    COUNT(DISTINCT record_id) AS records_affected,
    COUNT(DISTINCT participant_id) AS users_involved
FROM audit.audit_log
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 2, 3, 4;

-- =============================================================================
-- AUDIT RETENTION FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.purge_old_audit_logs(p_retention_days INTEGER DEFAULT 365)
RETURNS INTEGER AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM audit.audit_log
    WHERE event_timestamp < NOW() - (p_retention_days || ' days')::INTERVAL;
    
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- AUDIT QUERY FUNCTIONS
-- =============================================================================

-- Get record history
CREATE OR REPLACE FUNCTION audit.get_record_history(
    p_schema_name TEXT,
    p_table_name TEXT,
    p_record_id UUID,
    p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
    event_timestamp TIMESTAMP WITH TIME ZONE,
    event_type VARCHAR(32),
    changed_fields TEXT[],
    old_data JSONB,
    new_data JSONB,
    participant_id UUID
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        al.event_timestamp,
        al.event_type,
        al.changed_fields,
        al.old_data,
        al.new_data,
        al.participant_id
    FROM audit.audit_log al
    WHERE al.schema_name = p_schema_name
      AND al.table_name = p_table_name
      AND al.record_id = p_record_id
    ORDER BY al.event_timestamp DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Get user activity
CREATE OR REPLACE FUNCTION audit.get_user_activity(
    p_participant_id UUID,
    p_start_date DATE DEFAULT CURRENT_DATE - INTERVAL '7 days',
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    event_date DATE,
    event_type VARCHAR(32),
    table_name TEXT,
    event_count INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        al.event_timestamp::DATE AS event_date,
        al.event_type,
        al.table_name,
        COUNT(*)::INTEGER AS event_count
    FROM audit.audit_log al
    WHERE al.participant_id = p_participant_id
      AND al.event_timestamp::DATE BETWEEN p_start_date AND p_end_date
    GROUP BY 1, 2, 3
    ORDER BY 1 DESC, 4 DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Audit Triggers: Comprehensive logging initialized' AS status;
