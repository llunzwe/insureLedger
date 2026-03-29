-- =============================================================================
-- FILE: 012_sales_transaction.sql
-- PURPOSE: Primitive 12 - Sales Transaction & POS
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: PCI DSS, GDPR, ISO 8583
-- DEPENDENCIES: 005_device_product.sql, 006_agent_relationships.sql
-- =============================================================================

-- =============================================================================
-- SALES ORDERS
-- =============================================================================

CREATE TYPE kernel.sales_order_status AS ENUM (
    'cart',
    'pending_payment',
    'payment_confirmed',
    'processing',
    'shipped',
    'delivered',
    'cancelled',
    'refunded'
);

CREATE TYPE kernel.payment_status AS ENUM (
    'pending',
    'authorized',
    'captured',
    'failed',
    'refunded',
    'partially_refunded'
);

CREATE TABLE kernel.sales_orders (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    sales_order_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    order_number TEXT UNIQUE NOT NULL,
    
    -- Customer
    customer_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    customer_email TEXT,
    customer_phone TEXT,
    
    -- Order Details
    order_type VARCHAR(32) DEFAULT 'retail',  -- retail, wholesale, b2b
    
    -- Totals
    subtotal_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    tax_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    shipping_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    discount_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    total_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    currency_code VARCHAR(3) DEFAULT 'USD',
    
    -- Payment
    payment_status kernel.payment_status DEFAULT 'pending',
    payment_method VARCHAR(32),
    payment_gateway_reference TEXT,
    
    -- Fulfillment
    fulfillment_status VARCHAR(32) DEFAULT 'pending',
    shipping_address JSONB,
    billing_address JSONB,
    
    -- Status
    status kernel.sales_order_status DEFAULT 'cart',
    
    -- Timestamps
    ordered_at TIMESTAMP WITH TIME ZONE,
    paid_at TIMESTAMP WITH TIME ZONE,
    shipped_at TIMESTAMP WITH TIME ZONE,
    delivered_at TIMESTAMP WITH TIME ZONE,
    
    -- Device Link (if buying insurance/device)
    device_id UUID REFERENCES kernel.devices(device_id),
    insurance_policy_id UUID,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_modified_by UUID,
    last_modified_at TIMESTAMP WITH TIME ZONE,
    
    signature TEXT,
    proof_inclusion UUID,
    
    CONSTRAINT chk_sales_orders_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_sales_orders_order ON kernel.sales_orders(sales_order_id);
CREATE INDEX idx_sales_orders_customer ON kernel.sales_orders(customer_id);
CREATE INDEX idx_sales_orders_status ON kernel.sales_orders(status);

-- =============================================================================
-- ORDER LINE ITEMS
-- =============================================================================

CREATE TABLE kernel.order_line_items (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    line_item_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    sales_order_id UUID NOT NULL REFERENCES kernel.sales_orders(sales_order_id),
    
    -- Product
    product_id UUID NOT NULL REFERENCES kernel.product_catalog(product_id),
    product_code TEXT NOT NULL,
    product_name TEXT NOT NULL,
    
    -- Pricing
    unit_price DECIMAL(12, 2) NOT NULL,
    quantity INTEGER NOT NULL,
    line_total DECIMAL(12, 2) NOT NULL,
    
    -- Discounts
    discount_amount DECIMAL(12, 2) DEFAULT 0,
    discount_code TEXT,
    
    -- Insurance/Service specific
    coverage_start_date DATE,
    coverage_end_date DATE,
    device_serial TEXT,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_order_line_items_order ON kernel.order_line_items(sales_order_id);
CREATE INDEX idx_order_line_items_product ON kernel.order_line_items(product_id);

-- =============================================================================
-- PAYMENTS
-- =============================================================================

CREATE TABLE kernel.payments (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    previous_hash TEXT,
    current_hash TEXT NOT NULL DEFAULT 'pending',
    immutable_flag BOOLEAN DEFAULT TRUE,
    
    payment_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    
    -- References
    sales_order_id UUID REFERENCES kernel.sales_orders(sales_order_id),
    
    -- Payment Details
    amount DECIMAL(12, 2) NOT NULL,
    currency_code VARCHAR(3) NOT NULL DEFAULT 'USD',
    payment_method VARCHAR(32) NOT NULL,  -- card, bank_transfer, wallet, crypto
    
    -- Gateway info (PCI masked)
    gateway VARCHAR(32),
    gateway_transaction_id TEXT,
    masked_card_number TEXT,  -- Last 4 digits only
    card_brand VARCHAR(32),
    
    -- Status
    status kernel.payment_status DEFAULT 'pending',
    
    -- Authorization
    authorization_code TEXT,
    authorized_at TIMESTAMP WITH TIME ZONE,
    captured_at TIMESTAMP WITH TIME ZONE,
    
    -- Refund info
    is_refunded BOOLEAN DEFAULT FALSE,
    refunded_amount DECIMAL(12, 2) DEFAULT 0,
    
    -- Error handling
    error_code TEXT,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    signature TEXT,
    proof_inclusion UUID,
    
    CONSTRAINT chk_payments_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

CREATE INDEX idx_payments_payment ON kernel.payments(payment_id);
CREATE INDEX idx_payments_order ON kernel.payments(sales_order_id);
CREATE INDEX idx_payments_status ON kernel.payments(status);

-- =============================================================================
-- PAYMENT METHODS (Customer stored - tokenized)
-- =============================================================================

CREATE TABLE kernel.customer_payment_methods (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    payment_method_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    customer_id UUID NOT NULL REFERENCES kernel.participants(participant_id),
    
    -- Tokenized info (no actual card data per PCI DSS)
    payment_type VARCHAR(32) NOT NULL,
    gateway_token TEXT NOT NULL,
    masked_identifier TEXT,  -- Last 4 of card, or email for wallet
    
    -- Card specific
    card_brand VARCHAR(32),
    expiry_month INTEGER,
    expiry_year INTEGER,
    
    -- Billing
    billing_name TEXT,
    billing_address JSONB,
    
    is_default BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_customer_payment_methods_temporal CHECK (system_from <= system_to OR system_to IS NULL)
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION kernel.create_sales_order(
    p_customer_id UUID,
    p_currency_code VARCHAR(3) DEFAULT 'USD'
)
RETURNS UUID AS $$
DECLARE
    v_order_id UUID;
    v_order_number TEXT;
BEGIN
    v_order_number := 'ORD-' || to_char(NOW(), 'YYYYMMDD') || '-' || substr(md5(random()::TEXT), 1, 8);
    
    INSERT INTO kernel.sales_orders (
        order_number, customer_id, currency_code, created_by
    ) VALUES (
        v_order_number, p_customer_id, p_currency_code,
        security.get_participant_context()
    )
    RETURNING sales_order_id INTO v_order_id;
    
    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kernel.add_order_line_item(
    p_sales_order_id UUID,
    p_product_id UUID,
    p_quantity INTEGER,
    p_discount_code TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_line_item_id UUID;
    v_product RECORD;
    v_line_total DECIMAL(12, 2);
    v_discount DECIMAL(12, 2) := 0;
BEGIN
    SELECT * INTO v_product FROM kernel.product_catalog WHERE product_id = p_product_id;
    
    -- Calculate discount if code provided
    IF p_discount_code IS NOT NULL THEN
        SELECT discount_amount INTO v_discount
        FROM kernel.product_discounts
        WHERE product_id = p_product_id
          AND discount_code = p_discount_code
          AND valid_from <= NOW()
          AND (valid_to IS NULL OR valid_to >= NOW());
    END IF;
    
    v_line_total := (v_product.base_price * p_quantity) - COALESCE(v_discount, 0);
    
    INSERT INTO kernel.order_line_items (
        sales_order_id, product_id, product_code, product_name,
        unit_price, quantity, line_total, discount_amount, discount_code
    ) VALUES (
        p_sales_order_id, p_product_id, v_product.product_code, v_product.product_name,
        v_product.base_price, p_quantity, v_line_total, v_discount, p_discount_code
    )
    RETURNING line_item_id INTO v_line_item_id;
    
    -- Update order totals
    UPDATE kernel.sales_orders
    SET subtotal_amount = subtotal_amount + v_line_total,
        total_amount = subtotal_amount + v_line_total + tax_amount + shipping_amount - discount_amount
    WHERE sales_order_id = p_sales_order_id;
    
    RETURN v_line_item_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PRODUCT DISCOUNTS
-- =============================================================================

CREATE TABLE kernel.product_discounts (
    id UUID PRIMARY KEY DEFAULT kernel.generate_ulid(),
    
    discount_id UUID UNIQUE NOT NULL DEFAULT kernel.generate_ulid(),
    product_id UUID NOT NULL REFERENCES kernel.product_catalog(product_id),
    
    -- Discount details
    discount_code TEXT NOT NULL,
    discount_amount DECIMAL(12, 2) NOT NULL,
    discount_type VARCHAR(32) DEFAULT 'fixed',  -- fixed, percentage
    
    -- Validity
    valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    valid_to TIMESTAMP WITH TIME ZONE,
    
    -- Usage limits
    max_uses INTEGER,
    current_uses INTEGER DEFAULT 0,
    
    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    
    system_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    system_to TIMESTAMP WITH TIME ZONE,
    
    created_by UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(product_id, discount_code)
);

CREATE INDEX idx_product_discounts_product ON kernel.product_discounts(product_id, is_active);
CREATE INDEX idx_product_discounts_code ON kernel.product_discounts(discount_code) WHERE is_active = TRUE;

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Primitive 12: Sales Transaction & POS initialized' AS status;
