-- =============================================================================
-- FILE: 015_product_contract.sql
-- PURPOSE: Primitive 8 - Product Contract & Pricing
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: Versioned contracts, Dynamic pricing
-- DEPENDENCIES: 004_identity_tenancy.sql
-- =============================================================================

-- =============================================================================
-- PRODUCT CONTRACT TEMPLATES
-- =============================================================================

CREATE TYPE kernel.contract_status AS ENUM (
    'draft',
    'active',
    'deprecated',
    'retired'
);

CREATE TABLE kernel.product_contract_templates (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    contract_template_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    contract_code TEXT UNIQUE NOT NULL,
    
    -- Basic Info
    name TEXT NOT NULL,
    description TEXT,
    version TEXT NOT NULL DEFAULT '1.0.0',
    
    -- Product Type
    product_type VARCHAR(32) NOT NULL,  -- insurance, warranty, service, combined
    
    -- Contract Terms (immutable once published)
    terms_json JSONB NOT NULL DEFAULT '{}',
    terms_hash TEXT NOT NULL,
    
    -- Pricing Rules
    pricing_rules JSONB NOT NULL DEFAULT '{}',
    base_premium_formula TEXT,
    
    -- Validity
    effective_from DATE NOT NULL,
    effective_to DATE,
    
    status kernel.contract_status DEFAULT 'draft',
    
    -- Replacements
    replaces_template_id UUID,
    replaced_by_template_id UUID,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    published_by UUID,
    published_at TIMESTAMP WITH TIME ZONE,
    
    CONSTRAINT chk_contract_templates_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_contract_templates_code ON kernel.product_contract_templates(contract_code);
CREATE INDEX idx_contract_templates_status ON kernel.product_contract_templates(status);

-- =============================================================================
-- PRODUCT CONTRACT ANCHORS (Immutable instances)
-- =============================================================================

CREATE TABLE kernel.product_contract_anchors (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    contract_hash UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- Source template
    template_id UUID NOT NULL REFERENCES kernel.product_contract_templates(contract_template_id),
    template_version TEXT NOT NULL,
    
    -- Immutable terms
    terms_json JSONB NOT NULL,
    terms_hash TEXT NOT NULL,
    
    -- Anchoring
    anchored_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    anchored_by UUID,
    
    -- References (what this contract covers)
    device_model TEXT,
    coverage_type VARCHAR(32),
    
    -- Usage tracking
    policy_count INTEGER DEFAULT 0,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_contract_anchors_hash ON kernel.product_contract_anchors(contract_hash);
CREATE INDEX idx_contract_anchors_template ON kernel.product_contract_anchors(template_id);

-- =============================================================================
-- PRICING RULES
-- =============================================================================

CREATE TABLE kernel.pricing_rules (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    rule_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    rule_code TEXT UNIQUE NOT NULL,
    
    -- Rule details
    name TEXT NOT NULL,
    description TEXT,
    
    -- Applicability
    applies_to_template_id UUID REFERENCES kernel.product_contract_templates(contract_template_id),
    applies_to_device_models TEXT[],
    applies_to_regions TEXT[],
    
    -- Conditions
    condition_type VARCHAR(32) NOT NULL,  -- age, value, risk_score, etc.
    condition_operator VARCHAR(16) NOT NULL,  -- eq, gt, lt, between, in
    condition_value JSONB NOT NULL,
    
    -- Pricing impact
    adjustment_type VARCHAR(32) NOT NULL,  -- percentage, fixed_amount, multiplier
    adjustment_value DECIMAL(10, 4) NOT NULL,
    
    -- Priority
    priority INTEGER DEFAULT 100,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to DATE,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_pricing_rules_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_pricing_rules_template ON kernel.pricing_rules(applies_to_template_id);
CREATE INDEX idx_pricing_rules_active ON kernel.pricing_rules(is_active, valid_from, valid_to);

-- =============================================================================
-- DYNAMIC PRICING FACTORS
-- =============================================================================

CREATE TABLE kernel.dynamic_pricing_factors (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    factor_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    factor_code TEXT UNIQUE NOT NULL,
    
    name TEXT NOT NULL,
    description TEXT,
    
    -- Factor type
    factor_type VARCHAR(32) NOT NULL,  -- device_age, claim_history, location, time_of_day
    
    -- Data source
    data_source VARCHAR(64),  -- table.column or API endpoint
    data_transformation TEXT,  -- SQL expression or function
    
    -- Weight in pricing model
    weight DECIMAL(5, 4) NOT NULL DEFAULT 1.0,
    
    -- Value range
    min_value DECIMAL(10, 4),
    max_value DECIMAL(10, 4),
    default_value DECIMAL(10, 4) DEFAULT 0,
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =============================================================================
-- PRICE QUOTES
-- =============================================================================

CREATE TABLE kernel.price_quotes (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    quote_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    quote_reference TEXT UNIQUE NOT NULL,
    
    -- Request
    requester_id UUID REFERENCES kernel.participants(participant_id),
    device_id UUID REFERENCES kernel.devices(device_id),
    
    -- Product
    contract_template_id UUID REFERENCES kernel.product_contract_templates(contract_template_id),
    
    -- Pricing breakdown
    base_premium DECIMAL(12, 2) NOT NULL,
    adjustments JSONB DEFAULT '{}',
    final_premium DECIMAL(12, 2) NOT NULL,
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    -- Validity
    valid_until TIMESTAMP WITH TIME ZONE NOT NULL,
    
    -- Status
    status VARCHAR(32) DEFAULT 'pending',  -- pending, accepted, expired, rejected
    
    -- Acceptance
    accepted_at TIMESTAMP WITH TIME ZONE,
    accepted_by UUID,
    resulting_policy_id UUID,
    
    -- Factors used
    factors_applied JSONB DEFAULT '{}',
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_price_quotes_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_price_quotes_quote ON kernel.price_quotes(quote_id);
CREATE INDEX idx_price_quotes_requester ON kernel.price_quotes(requester_id);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- Create contract template
CREATE OR REPLACE FUNCTION kernel.create_contract_template(
    p_contract_code TEXT,
    p_name TEXT,
    p_product_type VARCHAR,
    p_terms_json JSONB,
    p_pricing_rules JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_template_id UUID;
    v_terms_hash TEXT;
BEGIN
    v_terms_hash := encode(digest(p_terms_json::TEXT, 'sha256'), 'hex');
    
    INSERT INTO kernel.product_contract_templates (
        contract_code, name, product_type, terms_json, terms_hash,
        pricing_rules, created_by
    ) VALUES (
        p_contract_code, p_name, p_product_type, p_terms_json, v_terms_hash,
        p_pricing_rules, security.get_participant_context()
    )
    RETURNING contract_template_id INTO v_template_id;
    
    RETURN v_template_id;
END;
$$ LANGUAGE plpgsql;

-- Publish contract template (create immutable anchor)
CREATE OR REPLACE FUNCTION kernel.publish_contract_template(p_template_id UUID)
RETURNS UUID AS $$
DECLARE
    v_anchor_id UUID;
    v_template RECORD;
BEGIN
    SELECT * INTO v_template FROM kernel.product_contract_templates WHERE contract_template_id = p_template_id;
    
    -- Create anchor
    INSERT INTO kernel.product_contract_anchors (
        template_id, template_version, terms_json, terms_hash, anchored_by
    ) VALUES (
        p_template_id, v_template.version, v_template.terms_json,
        v_template.terms_hash, security.get_participant_context()
    )
    RETURNING contract_hash INTO v_anchor_id;
    
    -- Update template status
    UPDATE kernel.product_contract_templates
    SET status = 'active', published_at = NOW(), published_by = security.get_participant_context()
    WHERE contract_template_id = p_template_id;
    
    RETURN v_anchor_id;
END;
$$ LANGUAGE plpgsql;

-- Calculate price quote
CREATE OR REPLACE FUNCTION kernel.calculate_price_quote(
    p_template_id UUID,
    p_device_id UUID,
    p_requester_id UUID
)
RETURNS UUID AS $$
DECLARE
    v_quote_id UUID;
    v_quote_ref TEXT;
    v_template RECORD;
    v_base_premium DECIMAL(12, 2);
    v_adjustments JSONB := '{}';
    v_final_premium DECIMAL(12, 2);
    v_factors JSONB := '{}';
    v_rule RECORD;
    v_device_age INTEGER;
    v_device_value DECIMAL(12, 2);
BEGIN
    SELECT * INTO v_template FROM kernel.product_contract_templates WHERE contract_template_id = p_template_id;
    
    v_quote_ref := 'QTE-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    
    -- Get base premium from formula (simplified - would use actual formula engine)
    v_base_premium := COALESCE((v_template.pricing_rules->>'base_premium')::DECIMAL, 100.00);
    
    -- Get device info for pricing
    SELECT 
        EXTRACT(YEAR FROM AGE(NOW(), COALESCE(purchase_date, NOW())))::INTEGER,
        COALESCE((attributes->>'value')::DECIMAL, 500)
    INTO v_device_age, v_device_value
    FROM kernel.devices WHERE device_id = p_device_id;
    
    v_final_premium := v_base_premium;
    
    -- Apply pricing rules
    FOR v_rule IN 
        SELECT * FROM kernel.pricing_rules
        WHERE applies_to_template_id = p_template_id AND is_active = TRUE
        ORDER BY priority
    LOOP
        IF v_rule.condition_type = 'device_age' AND v_device_age > (v_rule.condition_value->>'min')::INTEGER THEN
            IF v_rule.adjustment_type = 'percentage' THEN
                v_final_premium := v_final_premium * (1 + v_rule.adjustment_value);
                v_adjustments := v_adjustments || jsonb_build_object(v_rule.rule_code, v_rule.adjustment_value);
            END IF;
        END IF;
    END LOOP;
    
    -- Record factors
    v_factors := jsonb_build_object(
        'device_age', v_device_age,
        'device_value', v_device_value
    );
    
    INSERT INTO kernel.price_quotes (
        quote_reference, requester_id, device_id, contract_template_id,
        base_premium, adjustments, final_premium, valid_until, factors_applied
    ) VALUES (
        v_quote_ref, p_requester_id, p_device_id, p_template_id,
        v_base_premium, v_adjustments, v_final_premium, NOW() + INTERVAL '7 days', v_factors
    )
    RETURNING quote_id INTO v_quote_id;
    
    RETURN v_quote_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 8: Product Contract & Pricing initialized' AS status;
