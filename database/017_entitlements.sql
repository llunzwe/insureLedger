-- =============================================================================
-- FILE: 017_entitlements.sql
-- PURPOSE: Primitive 16 - Entitlements & Access
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: RBAC, ABAC, Attribute-based access control
-- DEPENDENCIES: 004_identity_tenancy.sql, 006_agent_relationships.sql
-- =============================================================================

-- =============================================================================
-- ROLES
-- =============================================================================

CREATE TYPE kernel.role_scope AS ENUM (
    'system',
    'tenant',
    'organization',
    'department',
    'project'
);

CREATE TABLE kernel.roles (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    role_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    role_code TEXT UNIQUE NOT NULL,
    
    -- Basic Info
    name TEXT NOT NULL,
    description TEXT,
    
    -- Scope
    scope kernel.role_scope DEFAULT 'tenant',
    
    -- Hierarchy
    parent_role_id UUID REFERENCES kernel.roles(role_id),
    
    -- Permissions (as JSON array)
    permissions JSONB DEFAULT '[]',
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    is_system BOOLEAN DEFAULT FALSE,  -- Cannot be modified
    
    -- Metadata
    metadata JSONB DEFAULT '{}',
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_roles_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_roles_role ON kernel.roles(role_id);
CREATE INDEX idx_roles_code ON kernel.roles(role_code);
CREATE INDEX idx_roles_active ON kernel.roles(is_active);

-- =============================================================================
-- PERMISSIONS
-- =============================================================================

CREATE TABLE kernel.permissions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    permission_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    permission_code TEXT UNIQUE NOT NULL,
    
    -- Classification
    resource_type VARCHAR(64) NOT NULL,  -- policy, claim, device, etc.
    action VARCHAR(64) NOT NULL,         -- create, read, update, delete, approve
    
    -- Description
    name TEXT NOT NULL,
    description TEXT,
    
    -- Conditions (ABAC)
    conditions JSONB DEFAULT '{}',  -- e.g., {"tenant_id": "${user.tenant_id}"}
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_permissions_code ON kernel.permissions(permission_code);
CREATE INDEX idx_permissions_resource ON kernel.permissions(resource_type, action);

-- =============================================================================
-- ROLE PERMISSIONS
-- =============================================================================

CREATE TABLE kernel.role_permissions (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    role_id UUID NOT NULL REFERENCES kernel.roles(role_id),
    permission_id UUID NOT NULL REFERENCES kernel.permissions(permission_id),
    
    -- Scope constraints
    tenant_id UUID,
    resource_constraints JSONB DEFAULT '{}',
    
    -- Temporal
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(role_id, permission_id, tenant_id)
);

CREATE INDEX idx_role_permissions_role ON kernel.role_permissions(role_id);
CREATE INDEX idx_role_permissions_permission ON kernel.role_permissions(permission_id);

-- =============================================================================
-- USER ROLES
-- =============================================================================

CREATE TABLE kernel.user_roles (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    user_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    role_id UUID NOT NULL REFERENCES kernel.roles(role_id),
    
    -- Granting context
    granted_by UUID REFERENCES kernel.participants(participant_id),
    granted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Scope
    tenant_id UUID,
    organization_id UUID,
    
    -- Temporal
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(user_id, role_id, tenant_id)
);

CREATE INDEX idx_user_roles_user ON kernel.user_roles(user_id, is_active);
CREATE INDEX idx_user_roles_role ON kernel.user_roles(role_id);

-- =============================================================================
-- ATTRIBUTE-BASED ACCESS POLICIES
-- =============================================================================

CREATE TYPE kernel.policy_effect AS ENUM (
    'allow',
    'deny'
);

CREATE TABLE kernel.access_policies (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    policy_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    policy_name TEXT NOT NULL,
    
    -- Policy definition
    description TEXT,
    effect kernel.policy_effect NOT NULL,
    
    -- Subject conditions
    subject_attributes JSONB DEFAULT '{}',  -- e.g., {"role": "admin", "department": "claims"}
    
    -- Action conditions
    actions JSONB DEFAULT '["*"]',  -- Array of allowed actions
    
    -- Resource conditions
    resource_attributes JSONB DEFAULT '{}',  -- e.g., {"type": "claim", "status": "open"}
    
    -- Environment conditions
    environment_conditions JSONB DEFAULT '{}',  -- e.g., {"time_of_day": "business_hours"}
    
    -- Priority (higher = evaluated first)
    priority INTEGER DEFAULT 100,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Tenant scope
    tenant_id UUID,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_access_policies_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_access_policies_active ON kernel.access_policies(is_active, priority DESC);
CREATE INDEX idx_access_policies_tenant ON kernel.access_policies(tenant_id);

-- =============================================================================
-- ENTITLEMENT GRANTS
-- =============================================================================

CREATE TABLE kernel.entitlement_grants (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    grant_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Grantee
    grantee_type VARCHAR(32) NOT NULL,  -- user, role, group
    grantee_id UUID NOT NULL,
    
    -- Entitlement
    entitlement_type VARCHAR(32) NOT NULL,  -- permission, feature, quota
    entitlement_id UUID,
    entitlement_code TEXT,
    
    -- Scope
    scope_type VARCHAR(32),  -- global, tenant, resource
    scope_id UUID,
    
    -- Constraints
    constraints JSONB DEFAULT '{}',
    
    -- Temporal
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Grant context
    granted_by UUID,
    granted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    grant_reason TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_entitlement_grants_grantee ON kernel.entitlement_grants(grantee_type, grantee_id);
CREATE INDEX idx_entitlement_grants_entitlement ON kernel.entitlement_grants(entitlement_type, entitlement_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create role
CREATE OR REPLACE FUNCTION kernel.create_role(
    p_role_code TEXT,
    p_name TEXT,
    p_scope kernel.role_scope DEFAULT 'tenant',
    p_permissions JSONB DEFAULT '[]'
)
RETURNS UUID AS $$
DECLARE
    v_role_id UUID;
BEGIN
    INSERT INTO kernel.roles (
        role_code, name, scope, permissions, created_by
    ) VALUES (
        p_role_code, p_name, p_scope, p_permissions,
        security.get_participant_context()
    )
    RETURNING role_id INTO v_role_id;
    
    RETURN v_role_id;
END;
$$ LANGUAGE plpgsql;

-- Grant role to user
CREATE OR REPLACE FUNCTION kernel.grant_role(
    p_user_id UUID,
    p_role_id UUID,
    p_tenant_id UUID DEFAULT NULL,
    p_valid_to TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_grant_id UUID;
BEGIN
    INSERT INTO kernel.user_roles (
        user_id, role_id, tenant_id, valid_to, granted_by
    ) VALUES (
        p_user_id, p_role_id, p_tenant_id, p_valid_to,
        security.get_participant_context()
    )
    RETURNING id INTO v_grant_id;
    
    -- Also create relationship record
    INSERT INTO kernel.agent_relationships (
        from_agent, to_agent, relationship_type, valid_to
    ) VALUES (
        p_user_id, p_role_id, 'has_role', p_valid_to
    );
    
    RETURN v_grant_id;
END;
$$ LANGUAGE plpgsql;

-- Check if user has permission
CREATE OR REPLACE FUNCTION kernel.has_permission(
    p_user_id UUID,
    p_permission_code TEXT,
    p_resource_type VARCHAR DEFAULT NULL,
    p_resource_id UUID DEFAULT NULL
)
RETURNS BOOLEAN AS $$
BEGIN
    -- Check direct permissions
    RETURN EXISTS (
        SELECT 1
        FROM kernel.user_roles ur
        JOIN kernel.role_permissions rp ON ur.role_id = rp.role_id
        JOIN kernel.permissions p ON rp.permission_id = p.permission_id
        WHERE ur.user_id = p_user_id
          AND ur.is_active = TRUE
          AND (ur.valid_to IS NULL OR ur.valid_to > NOW())
          AND p.permission_code = p_permission_code
          AND p.is_active = TRUE
    );
END;
$$ LANGUAGE plpgsql;

-- Evaluate access policy
CREATE OR REPLACE FUNCTION kernel.evaluate_access_policy(
    p_policy_id UUID,
    p_subject_id UUID,
    p_action VARCHAR,
    p_resource_type VARCHAR,
    p_resource_id UUID DEFAULT NULL
)
RETURNS kernel.policy_effect AS $$
DECLARE
    v_policy RECORD;
    v_subject_attrs JSONB;
    v_resource_attrs JSONB;
    v_matches BOOLEAN := TRUE;
BEGIN
    SELECT * INTO v_policy FROM kernel.access_policies WHERE policy_id = p_policy_id;
    
    -- Get subject attributes
    SELECT jsonb_build_object(
        'roles', array_agg(r.role_code),
        'tenant_id', ur.tenant_id
    ) INTO v_subject_attrs
    FROM kernel.user_roles ur
    JOIN kernel.roles r ON ur.role_id = r.role_id
    WHERE ur.user_id = p_subject_id
      AND ur.is_active = TRUE;
    
    -- Get resource attributes (simplified)
    v_resource_attrs := jsonb_build_object('type', p_resource_type, 'id', p_resource_id);
    
    -- Check subject conditions
    IF v_policy.subject_attributes != '{}' THEN
        IF NOT v_subject_attrs @> v_policy.subject_attributes THEN
            v_matches := FALSE;
        END IF;
    END IF;
    
    -- Check action conditions
    IF NOT (v_policy.actions ? p_action OR v_policy.actions ? '*') THEN
        v_matches := FALSE;
    END IF;
    
    -- Check resource conditions
    IF v_policy.resource_attributes != '{}' THEN
        IF NOT v_resource_attrs @> v_policy.resource_attributes THEN
            v_matches := FALSE;
        END IF;
    END IF;
    
    IF v_matches THEN
        RETURN v_policy.effect;
    ELSE
        RETURN NULL;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Get effective permissions for user
CREATE OR REPLACE FUNCTION kernel.get_user_permissions(p_user_id UUID)
RETURNS TABLE(permission_code TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT p.permission_code
    FROM kernel.user_roles ur
    JOIN kernel.role_permissions rp ON ur.role_id = rp.role_id
    JOIN kernel.permissions p ON rp.permission_id = p.permission_id
    WHERE ur.user_id = p_user_id
      AND ur.is_active = TRUE
      AND (ur.valid_to IS NULL OR ur.valid_to > NOW())
      AND p.is_active = TRUE;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Insert default system roles
INSERT INTO kernel.roles (role_code, name, scope, is_system, permissions) VALUES
    ('super_admin', 'Super Administrator', 'system', TRUE, '["*:*"]'::JSONB),
    ('tenant_admin', 'Tenant Administrator', 'tenant', TRUE, '["tenant:*", "user:*", "role:*"]'::JSONB),
    ('claims_manager', 'Claims Manager', 'tenant', TRUE, '["claim:*", "policy:read"]'::JSONB),
    ('claims_agent', 'Claims Agent', 'tenant', TRUE, '["claim:read", "claim:create", "claim:update", "policy:read"]'::JSONB),
    ('technician', 'Repair Technician', 'tenant', TRUE, '["repair:*", "device:read"]'::JSONB),
    ('customer', 'Customer', 'tenant', TRUE, '["policy:read_own", "claim:read_own", "device:read_own"]'::JSONB),
    ('auditor', 'Auditor', 'system', TRUE, '["audit:*", "report:*"]'::JSONB)
ON CONFLICT (role_code) DO NOTHING;

-- Insert default permissions
INSERT INTO kernel.permissions (permission_code, resource_type, action, name) VALUES
    ('policy:create', 'policy', 'create', 'Create Insurance Policy'),
    ('policy:read', 'policy', 'read', 'Read Insurance Policy'),
    ('policy:update', 'policy', 'update', 'Update Insurance Policy'),
    ('policy:delete', 'policy', 'delete', 'Delete Insurance Policy'),
    ('policy:read_own', 'policy', 'read_own', 'Read Own Policies'),
    ('claim:create', 'claim', 'create', 'Create Claim'),
    ('claim:read', 'claim', 'read', 'Read Claim'),
    ('claim:update', 'claim', 'update', 'Update Claim'),
    ('claim:approve', 'claim', 'approve', 'Approve Claim'),
    ('claim:read_own', 'claim', 'read_own', 'Read Own Claims'),
    ('device:create', 'device', 'create', 'Register Device'),
    ('device:read', 'device', 'read', 'Read Device'),
    ('device:update', 'device', 'update', 'Update Device'),
    ('device:read_own', 'device', 'read_own', 'Read Own Devices'),
    ('repair:create', 'repair', 'create', 'Create Repair Order'),
    ('repair:read', 'repair', 'read', 'Read Repair Order'),
    ('repair:update', 'repair', 'update', 'Update Repair Order'),
    ('user:create', 'user', 'create', 'Create User'),
    ('user:read', 'user', 'read', 'Read User'),
    ('user:update', 'user', 'update', 'Update User'),
    ('user:delete', 'user', 'delete', 'Delete User'),
    ('report:read', 'report', 'read', 'Read Reports'),
    ('audit:read', 'audit', 'read', 'Read Audit Logs')
ON CONFLICT (permission_code) DO NOTHING;

SELECT 'Primitive 16: Entitlements & Access initialized' AS status;
