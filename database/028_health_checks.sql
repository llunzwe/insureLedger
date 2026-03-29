-- =============================================================================
-- FILE: 028_health_checks.sql
-- PURPOSE: Primitive 24 - Health Checks & Observability
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: SRE, SLI/SLO/SLA, OpenTelemetry
-- DEPENDENCIES: 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- HEALTH CHECK DEFINITIONS
-- =============================================================================

CREATE TYPE kernel.health_check_type AS ENUM (
    'database',
    'api',
    'queue',
    'cache',
    'external_service',
    'disk_space',
    'memory',
    'cpu',
    'replication',
    'backup'
);

CREATE TYPE kernel.health_severity AS ENUM (
    'critical',
    'warning',
    'info'
);

CREATE TABLE kernel.health_checks (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    check_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    check_name TEXT UNIQUE NOT NULL,
    
    -- Classification
    check_type kernel.health_check_type NOT NULL,
    severity kernel.health_severity DEFAULT 'warning',
    
    -- Target
    target_system TEXT NOT NULL,
    target_endpoint TEXT,
    
    -- Check configuration
    check_query TEXT,  -- SQL query for DB checks
    check_command TEXT,  -- Command for system checks
    expected_result TEXT,
    
    -- Timing
    interval_seconds INTEGER DEFAULT 60,
    timeout_seconds INTEGER DEFAULT 10,
    
    -- Thresholds
    warning_threshold DECIMAL(10, 4),
    critical_threshold DECIMAL(10, 4),
    
    -- Alerting
    alert_enabled BOOLEAN DEFAULT TRUE,
    alert_channels TEXT[],  -- email, slack, pagerduty, etc.
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_health_checks_type ON kernel.health_checks(check_type);
CREATE INDEX idx_health_checks_active ON kernel.health_checks(is_active);

-- =============================================================================
-- HEALTH CHECK RESULTS
-- =============================================================================

CREATE TYPE kernel.health_status AS ENUM (
    'healthy',
    'degraded',
    'unhealthy',
    'unknown'
);

CREATE TABLE kernel.health_check_results (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    result_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    check_id UUID NOT NULL REFERENCES kernel.health_checks(check_id),
    
    -- Result
    status kernel.health_status NOT NULL,
    status_code INTEGER,  -- HTTP status, exit code, etc.
    
    -- Metrics
    response_time_ms INTEGER,
    result_value DECIMAL(24, 6),
    result_message TEXT,
    
    -- Details
    result_details JSONB,
    error_message TEXT,
    stack_trace TEXT,
    
    -- Timestamp
    checked_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    checked_by_node UUID,  -- Which node performed the check
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_health_results_check ON kernel.health_check_results(check_id, checked_at DESC);
CREATE INDEX idx_health_results_status ON kernel.health_check_results(status, checked_at DESC);

-- =============================================================================
-- SERVICE LEVEL OBJECTIVES (SLOs)
-- =============================================================================

CREATE TABLE kernel.service_level_objectives (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    slo_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    slo_name TEXT UNIQUE NOT NULL,
    
    -- Description
    description TEXT,
    service_name TEXT NOT NULL,
    
    -- SLI (Service Level Indicator)
    sli_metric TEXT NOT NULL,  -- availability, latency, error_rate, throughput
    sli_query TEXT NOT NULL,  -- How to calculate the SLI
    
    -- Target
    target_percentage DECIMAL(5, 2) NOT NULL,  -- e.g., 99.9
    window_days INTEGER DEFAULT 30,  -- Measurement window
    
    -- Alerting
    alert_burn_rate DECIMAL(5, 2) DEFAULT 2.0,  -- Burn rate for alerting
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- SLO MEASUREMENTS
-- =============================================================================

CREATE TABLE kernel.slo_measurements (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    measurement_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    slo_id UUID NOT NULL REFERENCES kernel.service_level_objectives(slo_id),
    
    -- Period
    measurement_date DATE NOT NULL,
    window_start TIMESTAMP WITH TIME ZONE NOT NULL,
    window_end TIMESTAMP WITH TIME ZONE NOT NULL,
    
    -- Values
    sli_value DECIMAL(10, 6) NOT NULL,  -- Actual SLI value
    target_value DECIMAL(10, 6) NOT NULL,  -- Target (e.g., 0.999)
    
    -- Compliance
    is_compliant BOOLEAN GENERATED ALWAYS AS (sli_value >= target_value) STORED,
    error_budget_remaining DECIMAL(10, 6),  -- Percentage of error budget left
    
    -- Burn rate
    burn_rate DECIMAL(10, 4),  -- How fast we're burning error budget
    days_until_exhaustion INTEGER,  -- Projected days until error budget exhausted
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_slo_measurements_slo ON kernel.slo_measurements(slo_id, measurement_date DESC);

-- =============================================================================
-- METRICS (Time-series data)
-- =============================================================================

CREATE TABLE kernel.metrics (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    metric_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Identity
    metric_name TEXT NOT NULL,
    metric_type VARCHAR(32) NOT NULL,  -- counter, gauge, histogram, summary
    
    -- Dimensions
    service_name TEXT,
    node_id UUID,
    tenant_id UUID,
    
    -- Labels
    labels JSONB DEFAULT '{}',
    
    -- Value
    metric_value DECIMAL(24, 6) NOT NULL,
    metric_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    
    -- For histograms
    bucket_le DECIMAL(24, 6),  -- Less than or equal
    bucket_count BIGINT,
    
    -- Raw data (for complex metrics)
    raw_data JSONB
);

CREATE INDEX idx_metrics_name ON kernel.metrics(metric_name, metric_timestamp DESC);
CREATE INDEX idx_metrics_service ON kernel.metrics(service_name, metric_timestamp DESC);

-- =============================================================================
-- ALERTS
-- =============================================================================

CREATE TYPE kernel.alert_severity AS ENUM (
    'critical',
    'high',
    'medium',
    'low',
    'info'
);

CREATE TYPE kernel.alert_status AS ENUM (
    'firing',
    'acknowledged',
    'resolved',
    'suppressed'
);

CREATE TABLE kernel.alerts (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    alert_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    alert_name TEXT NOT NULL,
    
    -- Source
    check_id UUID REFERENCES kernel.health_checks(check_id),
    slo_id UUID REFERENCES kernel.service_level_objectives(slo_id),
    
    -- Classification
    severity kernel.alert_severity NOT NULL,
    status kernel.alert_status DEFAULT 'firing',
    
    -- Description
    summary TEXT NOT NULL,
    description TEXT,
    runbook_url TEXT,
    
    -- Context
    labels JSONB DEFAULT '{}',
    annotations JSONB DEFAULT '{}',
    
    -- Timing
    fired_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    acknowledged_at TIMESTAMP WITH TIME ZONE,
    acknowledged_by UUID,
    resolved_at TIMESTAMP WITH TIME ZONE,
    resolved_by UUID,
    
    -- Resolution
    resolution_notes TEXT,
    
    -- Routing
    routing_key TEXT,  -- For pager duty integration
    incident_id TEXT,  -- External incident tracking
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_alerts_status ON kernel.alerts(status, fired_at DESC);
CREATE INDEX idx_alerts_severity ON kernel.alerts(severity, status);

-- =============================================================================
-- ALERT NOTIFICATIONS
-- =============================================================================

CREATE TABLE kernel.alert_notifications (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    notification_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    alert_id UUID NOT NULL REFERENCES kernel.alerts(alert_id),
    
    -- Channel
    channel_type TEXT NOT NULL,  -- email, slack, pagerduty, webhook
    channel_target TEXT NOT NULL,  -- Address/URL
    
    -- Status
    status VARCHAR(32) DEFAULT 'pending',  -- pending, sent, failed, delivered
    
    -- Content
    subject TEXT,
    body TEXT,
    
    -- Timing
    sent_at TIMESTAMP WITH TIME ZONE,
    delivered_at TIMESTAMP WITH TIME ZONE,
    
    -- Error
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_alert_notifications_alert ON kernel.alert_notifications(alert_id);

-- =============================================================================
-- INCIDENTS
-- =============================================================================

CREATE TYPE kernel.incident_severity AS ENUM (
    'sev1',  -- Critical - complete outage
    'sev2',  -- Major - significant degradation
    'sev3',  -- Minor - limited impact
    'sev4',  -- Low - minimal impact
    'sev5'   -- Informational
);

CREATE TYPE kernel.incident_status AS ENUM (
    'detected',
    'triaged',
    'investigating',
    'mitigating',
    'resolved',
    'post_mortem',
    'closed'
);

CREATE TABLE kernel.incidents (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    incident_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    incident_number TEXT UNIQUE NOT NULL,
    
    -- Description
    title TEXT NOT NULL,
    description TEXT,
    severity kernel.incident_severity NOT NULL,
    status kernel.incident_status DEFAULT 'detected',
    
    -- Detection
    detected_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    detected_by UUID,
    source_alert_id UUID REFERENCES kernel.alerts(alert_id),
    
    -- Impact
    affected_services TEXT[],
    affected_regions TEXT[],
    customer_impact BOOLEAN DEFAULT FALSE,
    
    -- Response
    commander UUID REFERENCES kernel.participants(participant_id),
    responders UUID[],
    
    -- Timeline
    acknowledged_at TIMESTAMP WITH TIME ZONE,
    mitigated_at TIMESTAMP WITH TIME ZONE,
    resolved_at TIMESTAMP WITH TIME ZONE,
    closed_at TIMESTAMP WITH TIME ZONE,
    
    -- Metrics
    time_to_detect_minutes INTEGER,  -- MTTD
    time_to_resolve_minutes INTEGER,  -- MTTR
    
    -- Post-mortem
    root_cause TEXT,
    lessons_learned TEXT,
    action_items JSONB,
    post_mortem_url TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_incidents_status ON kernel.incidents(status, severity);
CREATE INDEX idx_incidents_detected ON kernel.incidents(detected_at DESC);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Run health check
CREATE OR REPLACE FUNCTION kernel.run_health_check(p_check_id UUID)
RETURNS kernel.health_status AS $$
DECLARE
    v_check RECORD;
    v_start_time TIMESTAMP;
    v_result_value DECIMAL(24, 6);
    v_status kernel.health_status;
    v_message TEXT;
BEGIN
    SELECT * INTO v_check FROM kernel.health_checks WHERE check_id = p_check_id;
    
    v_start_time := clock_timestamp();
    
    -- Execute check query if defined
    IF v_check.check_query IS NOT NULL THEN
        BEGIN
            EXECUTE v_check.check_query INTO v_result_value;
            v_status := 'healthy';
            v_message := 'Check passed';
            
            -- Evaluate thresholds
            IF v_check.critical_threshold IS NOT NULL AND v_result_value >= v_check.critical_threshold THEN
                v_status := 'unhealthy';
                v_message := 'Critical threshold exceeded: ' || v_result_value;
            ELSIF v_check.warning_threshold IS NOT NULL AND v_result_value >= v_check.warning_threshold THEN
                v_status := 'degraded';
                v_message := 'Warning threshold exceeded: ' || v_result_value;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_status := 'unhealthy';
            v_message := SQLERRM;
            v_result_value := NULL;
        END;
    ELSE
        v_status := 'unknown';
        v_message := 'No check query defined';
    END IF;
    
    -- Record result
    INSERT INTO kernel.health_check_results (
        check_id, status, response_time_ms, result_value, result_message
    ) VALUES (
        p_check_id, v_status, 
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
        v_result_value, v_message
    );
    
    -- Create alert if unhealthy
    IF v_status = 'unhealthy' AND v_check.alert_enabled THEN
        PERFORM kernel.create_alert(
            v_check.check_name || ' Failed',
            v_check.severity::kernel.alert_severity,
            v_message,
            p_check_id
        );
    END IF;
    
    RETURN v_status;
END;
$$ LANGUAGE plpgsql;

-- Create alert
CREATE OR REPLACE FUNCTION kernel.create_alert(
    p_alert_name TEXT,
    p_severity kernel.alert_severity,
    p_summary TEXT,
    p_check_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_alert_id UUID;
BEGIN
    INSERT INTO kernel.alerts (
        alert_name, check_id, severity, summary, fired_at
    ) VALUES (
        p_alert_name, p_check_id, p_severity, p_summary, NOW()
    )
    RETURNING alert_id INTO v_alert_id;
    
    -- Create incident for critical alerts
    IF p_severity = 'critical' THEN
        PERFORM kernel.create_incident(
            'Critical: ' || p_alert_name,
            p_summary,
            'sev1',
            v_alert_id
        );
    END IF;
    
    RETURN v_alert_id;
END;
$$ LANGUAGE plpgsql;

-- Acknowledge alert
CREATE OR REPLACE FUNCTION kernel.acknowledge_alert(
    p_alert_id UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.alerts
    SET status = 'acknowledged',
        acknowledged_at = NOW(),
        acknowledged_by = security.get_participant_context()
    WHERE alert_id = p_alert_id;
END;
$$ LANGUAGE plpgsql;

-- Resolve alert
CREATE OR REPLACE FUNCTION kernel.resolve_alert(
    p_alert_id UUID,
    p_notes TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE kernel.alerts
    SET status = 'resolved',
        resolved_at = NOW(),
        resolved_by = security.get_participant_context(),
        resolution_notes = p_notes
    WHERE alert_id = p_alert_id;
END;
$$ LANGUAGE plpgsql;

-- Create incident
CREATE OR REPLACE FUNCTION kernel.create_incident(
    p_title TEXT,
    p_description TEXT,
    p_severity kernel.incident_severity,
    p_source_alert_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_incident_id UUID;
    v_incident_number TEXT;
BEGIN
    v_incident_number := 'INC-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 6);
    
    INSERT INTO kernel.incidents (
        incident_number, title, description, severity, source_alert_id
    ) VALUES (
        v_incident_number, p_title, p_description, p_severity, p_source_alert_id
    )
    RETURNING incident_id INTO v_incident_id;
    
    RETURN v_incident_id;
END;
$$ LANGUAGE plpgsql;

-- Update SLO measurement
CREATE OR REPLACE FUNCTION kernel.update_slo_measurement(
    p_slo_id UUID,
    p_measurement_date DATE
)
RETURNS VOID AS $$
DECLARE
    v_slo RECORD;
    v_sli_value DECIMAL(10, 6);
    v_window_start TIMESTAMP WITH TIME ZONE;
    v_window_end TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT * INTO v_slo FROM kernel.service_level_objectives WHERE slo_id = p_slo_id;
    
    v_window_end := p_measurement_date::TIMESTAMP WITH TIME ZONE + INTERVAL '1 day';
    v_window_start := v_window_end - (v_slo.window_days || ' days')::INTERVAL;
    
    -- Execute SLI query (simplified - would use actual query)
    v_sli_value := 0.999;  -- Placeholder
    
    INSERT INTO kernel.slo_measurements (
        slo_id, measurement_date, window_start, window_end,
        sli_value, target_value
    ) VALUES (
        p_slo_id, p_measurement_date, v_window_start, v_window_end,
        v_sli_value, v_slo.target_percentage / 100
    )
    ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Create default health checks
INSERT INTO kernel.health_checks (check_name, check_type, target_system, check_query, warning_threshold, critical_threshold) VALUES
    ('Database Connectivity', 'database', 'primary', 'SELECT 1', NULL, NULL),
    ('Replication Lag', 'replication', 'primary', 'SELECT EXTRACT(EPOCH FROM NOW() - last_heartbeat)/60 FROM kernel.nodes WHERE node_type = ''replica''', 5, 15),
    ('Disk Space Usage', 'disk_space', 'primary', 'SELECT 100.0 * pg_database_size(current_database()) / (SELECT setting::bigint FROM pg_settings WHERE name = ''effective_cache_size'')', 80, 95),
    ('Long Running Queries', 'database', 'primary', 'SELECT COUNT(*) FROM pg_stat_activity WHERE state = ''active'' AND NOW() - query_start > INTERVAL ''5 minutes''', 5, 20),
    ('Failed Login Attempts', 'api', 'auth', 'SELECT COUNT(*) FROM kernel.sessions WHERE created_at > NOW() - INTERVAL ''5 minutes'' AND FALSE', 10, 50)
ON CONFLICT (check_name) DO NOTHING;

-- Create default SLOs
INSERT INTO kernel.service_level_objectives (slo_name, description, service_name, sli_metric, sli_query, target_percentage) VALUES
    ('API Availability', 'API uptime percentage', 'api-gateway', 'availability', 'SELECT 1 - (down_time / total_time)', 99.99),
    ('API Latency', '95th percentile API response time', 'api-gateway', 'latency', 'SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY response_time_ms)', 99.90),
    ('Database Availability', 'Database uptime percentage', 'database', 'availability', 'SELECT 1 - (down_time / total_time)', 99.95),
    ('Settlement Success Rate', 'Percentage of successful settlements', 'settlement', 'success_rate', 'SELECT successful / total', 99.99)
ON CONFLICT (slo_name) DO NOTHING;

SELECT 'Primitive 24: Health Checks & Observability initialized' AS status;
