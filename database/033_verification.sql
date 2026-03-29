-- =============================================================================
-- FILE: 033_verification.sql
-- PURPOSE: Post-deployment verification and health checks
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Deployment validation, smoke tests
-- DEPENDENCIES: All primitives
-- =============================================================================

-- =============================================================================
-- VERIFICATION METADATA
-- =============================================================================

CREATE TABLE IF NOT EXISTS kernel.verification_results (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    verification_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    verification_name TEXT NOT NULL,
    verification_category TEXT NOT NULL,
    
    -- Result
    status VARCHAR(16) NOT NULL,  -- PASSED, FAILED, WARNING, SKIPPED
    message TEXT,
    details JSONB,
    
    -- Timing
    executed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    execution_time_ms INTEGER,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- VERIFICATION FUNCTIONS
-- =============================================================================

-- Verify schema objects exist
CREATE OR REPLACE FUNCTION verify.schema_objects_exist()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_count INTEGER;
    v_expected INTEGER;
BEGIN
    -- Check schemas
    SELECT COUNT(*) INTO v_count FROM information_schema.schemata 
    WHERE schema_name IN ('kernel', 'security', 'audit', 'crypto', 'temporal');
    v_expected := 5;
    
    IF v_count = v_expected THEN
        RETURN QUERY SELECT 'Required schemas exist'::TEXT, 'PASSED'::TEXT, 
            format('Found %s/%s schemas', v_count, v_expected)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Required schemas exist'::TEXT, 'FAILED'::TEXT, 
            format('Expected %s schemas, found %s', v_expected, v_count)::TEXT;
    END IF;
    
    -- Check core tables
    SELECT COUNT(*) INTO v_count FROM information_schema.tables 
    WHERE table_schema = 'kernel' AND table_type = 'BASE TABLE';
    
    IF v_count >= 40 THEN
        RETURN QUERY SELECT 'Core tables exist'::TEXT, 'PASSED'::TEXT, 
            format('Found %s tables in kernel schema', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Core tables exist'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 40 tables, found %s', v_count)::TEXT;
    END IF;
    
    -- Check extensions
    SELECT COUNT(*) INTO v_count FROM pg_extension 
    WHERE extname IN ('uuid-ossp', 'pgcrypto', 'btree_gist');
    v_expected := 3;
    
    IF v_count >= v_expected THEN
        RETURN QUERY SELECT 'Required extensions loaded'::TEXT, 'PASSED'::TEXT, 
            format('Found %s/%s extensions', v_count, v_expected)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Required extensions loaded'::TEXT, 'FAILED'::TEXT, 
            format('Expected %s extensions, found %s', v_expected, v_count)::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Verify seed data loaded
CREATE OR REPLACE FUNCTION verify.seed_data_loaded()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Check tenants
    SELECT COUNT(*) INTO v_count FROM kernel.technician_tenants;
    IF v_count >= 2 THEN
        RETURN QUERY SELECT 'Tenants seeded'::TEXT, 'PASSED'::TEXT, 
            format('Found %s tenants', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Tenants seeded'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 2 tenants, found %s', v_count)::TEXT;
    END IF;
    
    -- Check participants
    SELECT COUNT(*) INTO v_count FROM kernel.participants;
    IF v_count >= 4 THEN
        RETURN QUERY SELECT 'Participants seeded'::TEXT, 'PASSED'::TEXT, 
            format('Found %s participants', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Participants seeded'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 4 participants, found %s', v_count)::TEXT;
    END IF;
    
    -- Check currencies
    SELECT COUNT(*) INTO v_count FROM kernel.currencies;
    IF v_count >= 9 THEN
        RETURN QUERY SELECT 'Currencies seeded'::TEXT, 'PASSED'::TEXT, 
            format('Found %s currencies', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Currencies seeded'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 9 currencies, found %s', v_count)::TEXT;
    END IF;
    
    -- Check roles
    SELECT COUNT(*) INTO v_count FROM kernel.roles;
    IF v_count >= 6 THEN
        RETURN QUERY SELECT 'Roles seeded'::TEXT, 'PASSED'::TEXT, 
            format('Found %s roles', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Roles seeded'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 6 roles, found %s', v_count)::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Verify RLS is enabled
CREATE OR REPLACE FUNCTION verify.rls_enabled()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM pg_tables 
    WHERE schemaname = 'kernel' AND rowsecurity = TRUE;
    
    IF v_count >= 5 THEN
        RETURN QUERY SELECT 'RLS enabled on tables'::TEXT, 'PASSED'::TEXT, 
            format('RLS enabled on %s tables', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'RLS enabled on tables'::TEXT, 'WARNING'::TEXT, 
            format('Expected RLS on at least 5 tables, found %s', v_count)::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Verify functions exist
CREATE OR REPLACE FUNCTION verify.core_functions_exist()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Check kernel functions
    SELECT COUNT(*) INTO v_count FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'kernel';
    
    IF v_count >= 20 THEN
        RETURN QUERY SELECT 'Kernel functions exist'::TEXT, 'PASSED'::TEXT, 
            format('Found %s functions in kernel schema', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Kernel functions exist'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 20 functions, found %s', v_count)::TEXT;
    END IF;
    
    -- Check security functions
    SELECT COUNT(*) INTO v_count FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'security';
    
    IF v_count >= 3 THEN
        RETURN QUERY SELECT 'Security functions exist'::TEXT, 'PASSED'::TEXT, 
            format('Found %s functions in security schema', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Security functions exist'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 3 functions, found %s', v_count)::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Verify triggers exist
CREATE OR REPLACE FUNCTION verify.triggers_exist()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM pg_trigger t
    JOIN pg_class c ON t.tgrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'kernel' AND NOT t.tgisinternal;
    
    IF v_count >= 10 THEN
        RETURN QUERY SELECT 'Kernel triggers exist'::TEXT, 'PASSED'::TEXT, 
            format('Found %s triggers', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Kernel triggers exist'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 10 triggers, found %s', v_count)::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Verify indexes exist
CREATE OR REPLACE FUNCTION verify.indexes_exist()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM pg_indexes 
    WHERE schemaname = 'kernel';
    
    IF v_count >= 50 THEN
        RETURN QUERY SELECT 'Kernel indexes exist'::TEXT, 'PASSED'::TEXT, 
            format('Found %s indexes', v_count)::TEXT;
    ELSE
        RETURN QUERY SELECT 'Kernel indexes exist'::TEXT, 'WARNING'::TEXT, 
            format('Expected at least 50 indexes, found %s', v_count)::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Run basic functionality test
CREATE OR REPLACE FUNCTION verify.basic_functionality()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_participant_id UUID;
    v_container_id UUID;
BEGIN
    -- Test ULID generation
    BEGIN
        SELECT kernel.generate_ulid() INTO v_participant_id;
        IF v_participant_id IS NOT NULL THEN
            RETURN QUERY SELECT 'ULID generation'::TEXT, 'PASSED'::TEXT, 
                format('Generated ULID: %s', v_participant_id)::TEXT;
        ELSE
            RETURN QUERY SELECT 'ULID generation'::TEXT, 'FAILED'::TEXT, 
                'ULID generation returned NULL'::TEXT;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 'ULID generation'::TEXT, 'FAILED'::TEXT, 
            SQLERRM::TEXT;
    END;
    
    -- Test hash function
    BEGIN
        PERFORM crypto.sha256_hash('test');
        RETURN QUERY SELECT 'SHA-256 hashing'::TEXT, 'PASSED'::TEXT, 
            'Hash function works'::TEXT;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 'SHA-256 hashing'::TEXT, 'FAILED'::TEXT, 
            SQLERRM::TEXT;
    END;
    
    -- Test currency validation
    BEGIN
        IF kernel.validate_currency_code('USD') THEN
            RETURN QUERY SELECT 'Currency validation'::TEXT, 'PASSED'::TEXT, 
                'USD is valid'::TEXT;
        ELSE
            RETURN QUERY SELECT 'Currency validation'::TEXT, 'FAILED'::TEXT, 
                'USD validation failed'::TEXT;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 'Currency validation'::TEXT, 'FAILED'::TEXT, 
            SQLERRM::TEXT;
    END;
END;
$$ LANGUAGE plpgsql;

-- Verify system integrity
CREATE OR REPLACE FUNCTION verify.system_integrity()
RETURNS TABLE (check_name TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_results RECORD;
BEGIN
    FOR v_results IN SELECT * FROM kernel.system_integrity_check()
    LOOP
        RETURN QUERY SELECT 
            v_results.check_name::TEXT, 
            v_results.status::TEXT, 
            v_results.details::TEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COMPREHENSIVE VERIFICATION
-- =============================================================================

CREATE OR REPLACE FUNCTION verify.run_all_checks()
RETURNS TABLE (
    category TEXT,
    check_name TEXT,
    status TEXT,
    message TEXT
) AS $$
BEGIN
    -- Schema verification
    RETURN QUERY SELECT 'Schema'::TEXT, * FROM verify.schema_objects_exist();
    
    -- Data verification
    RETURN QUERY SELECT 'Data'::TEXT, * FROM verify.seed_data_loaded();
    
    -- Security verification
    RETURN QUERY SELECT 'Security'::TEXT, * FROM verify.rls_enabled();
    
    -- Function verification
    RETURN QUERY SELECT 'Functions'::TEXT, * FROM verify.core_functions_exist();
    
    -- Trigger verification
    RETURN QUERY SELECT 'Triggers'::TEXT, * FROM verify.triggers_exist();
    
    -- Index verification
    RETURN QUERY SELECT 'Indexes'::TEXT, * FROM verify.indexes_exist();
    
    -- Functionality verification
    RETURN QUERY SELECT 'Functionality'::TEXT, * FROM verify.basic_functionality();
    
    -- Integrity verification
    RETURN QUERY SELECT 'Integrity'::TEXT, * FROM verify.system_integrity();
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- VERIFICATION SUMMARY VIEW
-- =============================================================================

CREATE OR REPLACE VIEW verify.deployment_summary AS
SELECT 
    'Schemas' as component,
    (SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name IN ('kernel', 'security', 'audit', 'crypto', 'temporal')) as count,
    5 as expected,
    CASE WHEN (SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name IN ('kernel', 'security', 'audit', 'crypto', 'temporal')) = 5 THEN 'OK' ELSE 'MISSING' END as status
UNION ALL
SELECT 
    'Tables',
    (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'kernel' AND table_type = 'BASE TABLE'),
    50,
    CASE WHEN (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'kernel' AND table_type = 'BASE TABLE') >= 40 THEN 'OK' ELSE 'LOW' END
UNION ALL
SELECT 
    'Functions',
    (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'kernel'),
    30,
    CASE WHEN (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'kernel') >= 20 THEN 'OK' ELSE 'LOW' END
UNION ALL
SELECT 
    'Indexes',
    (SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'kernel'),
    60,
    CASE WHEN (SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'kernel') >= 50 THEN 'OK' ELSE 'LOW' END
UNION ALL
SELECT 
    'Triggers',
    (SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'kernel' AND NOT t.tgisinternal),
    15,
    CASE WHEN (SELECT COUNT(*) FROM pg_trigger t JOIN pg_class c ON t.tgrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'kernel' AND NOT t.tgisinternal) >= 10 THEN 'OK' ELSE 'LOW' END
UNION ALL
SELECT 
    'RLS Tables',
    (SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'kernel' AND rowsecurity = true),
    8,
    CASE WHEN (SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'kernel' AND rowsecurity = true) >= 5 THEN 'OK' ELSE 'LOW' END;

-- =============================================================================
-- FINAL VERIFICATION
-- =============================================================================

-- Record verification run
INSERT INTO kernel.verification_results (verification_name, verification_category, status, message, details)
SELECT 
    'Post-deployment verification',
    'system',
    CASE 
        WHEN count(CASE WHEN status = 'OK' THEN 1 END) = count(*) THEN 'PASSED'
        WHEN count(CASE WHEN status = 'LOW' THEN 1 END) > 0 THEN 'WARNING'
        ELSE 'FAILED'
    END,
    format('Verified %s components', count(*)),
    jsonb_agg(jsonb_build_object('component', component, 'status', status, 'count', count, 'expected', expected))
FROM verify.deployment_summary;

-- Display results
SELECT 
    '========================================' AS separator;
SELECT 
    'INSURELEDGER DEPLOYMENT VERIFICATION' AS title;
SELECT 
    '========================================' AS separator;

SELECT * FROM verify.deployment_summary;

SELECT 
    '----------------------------------------' AS separator;
SELECT 
    'Overall Status: ' || 
    CASE 
        WHEN count(CASE WHEN status != 'OK' THEN 1 END) = 0 THEN 'PASSED ✓'
        WHEN count(CASE WHEN status = 'LOW' THEN 1 END) > 0 THEN 'WARNING ⚠'
        ELSE 'FAILED ✗'
    END AS overall_status
FROM verify.deployment_summary;

SELECT 'Primitive 33: Verification and deployment validation completed' AS status;
