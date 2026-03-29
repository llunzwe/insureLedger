-- =============================================================================
-- FILE: 030_indexes_constraints.sql
-- PURPOSE: Performance indexes and additional constraints
-- AUTHOR: InsureLedger Core Team
-- DATE: 2024-03-28
-- STANDARDS: PostgreSQL optimization best practices
-- DEPENDENCIES: All primitives
-- =============================================================================

-- =============================================================================
-- B-TREE INDEXES FOR COMMON LOOKUPS
-- =============================================================================

-- Participants
CREATE INDEX IF NOT EXISTS idx_participants_type ON kernel.participants(participant_type);
CREATE INDEX IF NOT EXISTS idx_participants_status ON kernel.participants(status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_participants_lei ON kernel.participants(lei_code) WHERE lei_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_participants_bic ON kernel.participants(bic_code) WHERE bic_code IS NOT NULL;

-- Devices
CREATE INDEX IF NOT EXISTS idx_devices_type ON kernel.devices(device_type);
CREATE INDEX IF NOT EXISTS idx_devices_model ON kernel.devices(manufacturer, model);
CREATE INDEX IF NOT EXISTS idx_devices_imei ON kernel.devices(imei) WHERE imei IS NOT NULL;

-- Agent Relationships
CREATE INDEX IF NOT EXISTS idx_agent_relationships_type ON kernel.agent_relationships(relationship_type);
CREATE INDEX IF NOT EXISTS idx_agent_relationships_graph ON kernel.agent_relationships(from_agent, to_agent);

-- Value Movements
CREATE INDEX IF NOT EXISTS idx_value_movements_date ON kernel.value_movements(entry_date DESC);
CREATE INDEX IF NOT EXISTS idx_value_movements_uetr ON kernel.value_movements(uetr) WHERE uetr IS NOT NULL;

-- Movement Postings (TimescaleDB hypertable optimization)
CREATE INDEX IF NOT EXISTS idx_movement_postings_time ON kernel.movement_postings(posted_at DESC);
CREATE INDEX IF NOT EXISTS idx_movement_postings_container ON kernel.movement_postings(container_id, posted_at DESC);

-- Container Balances History (TimescaleDB hypertable optimization)
CREATE INDEX IF NOT EXISTS idx_container_balances_time ON kernel.container_balances_history(recorded_at DESC);

-- Claims
CREATE INDEX IF NOT EXISTS idx_claims_date ON kernel.claims(incident_date DESC);
CREATE INDEX IF NOT EXISTS idx_claims_type ON kernel.claims(incident_type);

-- Repair Orders
CREATE INDEX IF NOT EXISTS idx_repair_orders_dates ON kernel.repair_orders(received_at DESC, completed_at);

-- Sales Orders
CREATE INDEX IF NOT EXISTS idx_sales_orders_date ON kernel.sales_orders(ordered_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_orders_payment ON kernel.sales_orders(payment_status);

-- Documents
CREATE INDEX IF NOT EXISTS idx_documents_retention ON kernel.documents(retain_until_date) 
    WHERE retain_until_date < CURRENT_DATE + INTERVAL '30 days' AND legal_hold = FALSE;

-- =============================================================================
-- GIN INDEXES FOR JSONB AND ARRAYS
-- =============================================================================

-- Entity Snapshots
CREATE INDEX IF NOT EXISTS idx_entity_snapshots_state ON kernel.entity_snapshots USING GIN(current_state);

-- Event Log
CREATE INDEX IF NOT EXISTS idx_event_log_payload ON kernel.event_log USING GIN(payload);

-- Mutations
CREATE INDEX IF NOT EXISTS idx_mutations_new_data ON kernel.mutations USING GIN(new_data);
CREATE INDEX IF NOT EXISTS idx_mutations_old_data ON kernel.mutations USING GIN(old_data);

-- Compliance Reports
CREATE INDEX IF NOT EXISTS idx_compliance_reports_data ON kernel.compliance_reports USING GIN(report_data);

-- Device Attributes
CREATE INDEX IF NOT EXISTS idx_devices_attributes ON kernel.devices USING GIN(attributes);

-- Customer Addresses
CREATE INDEX IF NOT EXISTS idx_participants_addresses ON kernel.participants USING GIN(addresses);

-- =============================================================================
-- GIST INDEXES FOR RANGE QUERIES
-- =============================================================================

-- Valid time ranges (if using tstzrange)
-- CREATE INDEX IF NOT EXISTS idx_policies_valid_range ON kernel.insurance_policies 
--     USING GIST(tstzrange(valid_from, valid_to, '[)'));

-- =============================================================================
-- PARTIAL INDEXES FOR COMMON FILTER CONDITIONS
-- =============================================================================

-- Active policies only
CREATE INDEX IF NOT EXISTS idx_policies_active ON kernel.insurance_policies(policyholder_id, effective_end_date)
    WHERE status = 'active' AND system_to IS NULL;

-- Pending claims
CREATE INDEX IF NOT EXISTS idx_claims_pending ON kernel.claims(policy_id, filed_at)
    WHERE status IN ('filed', 'under_review');

-- Open repair orders
CREATE INDEX IF NOT EXISTS idx_repair_orders_open ON kernel.repair_orders(service_provider_id, received_at)
    WHERE status NOT IN ('completed', 'cancelled', 'delivered');

-- Active sessions
CREATE INDEX IF NOT EXISTS idx_sessions_active ON kernel.sessions(session_token, expires_at)
    WHERE is_active = TRUE AND expires_at > NOW();

-- Unprocessed mutations
CREATE INDEX IF NOT EXISTS idx_mutations_unprocessed ON kernel.mutations(source_table, committed_at)
    WHERE processed = FALSE;

-- Unresolved conflicts
CREATE INDEX IF NOT EXISTS idx_conflicts_unresolved ON kernel.conflict_log(detected_at)
    WHERE resolved_at IS NULL;

-- Active legal holds
CREATE INDEX IF NOT EXISTS idx_legal_holds_active ON kernel.legal_holds(effective_date)
    WHERE is_active = TRUE;

-- Firing alerts
CREATE INDEX IF NOT EXISTS idx_alerts_firing ON kernel.alerts(fired_at DESC)
    WHERE status = 'firing';

-- =============================================================================
-- COMPOSITE INDEXES FOR COMMON QUERY PATTERNS
-- =============================================================================

-- Claims by policy and date
CREATE INDEX IF NOT EXISTS idx_claims_policy_date ON kernel.claims(policy_id, filed_at DESC);

-- Movements by container and date
CREATE INDEX IF NOT EXISTS idx_movement_legs_container ON kernel.movement_legs(container_id, created_at DESC);

-- Payments by order and status
CREATE INDEX IF NOT EXISTS idx_payments_order_status ON kernel.payments(sales_order_id, status);

-- Audit log by entity
CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON kernel.audit_log(entity_type, entity_id, created_at DESC);

-- Balance history lookup
CREATE INDEX IF NOT EXISTS idx_balances_container_date ON kernel.sub_ledger_balances(master_account_id, snapshot_time DESC);

-- =============================================================================
-- UNIQUE CONSTRAINTS
-- =============================================================================

-- Ensure unique LEI codes
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_lei ON kernel.participants(lei_code) 
    WHERE lei_code IS NOT NULL AND system_to IS NULL;

-- Ensure unique BIC codes
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_bic ON kernel.participants(bic_code) 
    WHERE bic_code IS NOT NULL AND system_to IS NULL;

-- Ensure unique policy numbers
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_policy_number ON kernel.insurance_policies(policy_number) 
    WHERE system_to IS NULL;

-- Ensure unique claim numbers
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_claim_number ON kernel.claims(claim_number) 
    WHERE system_to IS NULL;

-- Ensure unique order numbers
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_order_number ON kernel.sales_orders(order_number) 
    WHERE system_to IS NULL;

-- Ensure unique repair order numbers
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_repair_number ON kernel.repair_orders(order_number) 
    WHERE system_to IS NULL;

-- Ensure unique UETR
CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_uetr ON kernel.value_movements(uetr) 
    WHERE uetr IS NOT NULL AND system_to IS NULL;

-- =============================================================================
-- CHECK CONSTRAINTS
-- =============================================================================

-- Ensure positive amounts
ALTER TABLE kernel.value_movements 
    ADD CONSTRAINT chk_positive_amounts CHECK (total_debits >= 0 AND total_credits >= 0);

ALTER TABLE kernel.movement_legs 
    ADD CONSTRAINT chk_positive_leg_amount CHECK (amount >= 0);

-- Ensure valid dates
ALTER TABLE kernel.insurance_policies 
    ADD CONSTRAINT chk_valid_dates CHECK (effective_start_date <= effective_end_date);

ALTER TABLE kernel.claims 
    ADD CONSTRAINT chk_valid_incident_date CHECK (incident_date <= NOW());

-- Ensure percentage between 0 and 100
ALTER TABLE kernel.agent_relationships 
    ADD CONSTRAINT chk_valid_percentage CHECK (percentage IS NULL OR (percentage >= 0 AND percentage <= 100));

-- Ensure valid IBAN format using ISO 13616 validation
ALTER TABLE kernel.sub_accounts 
    ADD CONSTRAINT chk_valid_iban CHECK (virtual_iban IS NULL OR kernel.validate_iban(virtual_iban));

-- =============================================================================
-- FOREIGN KEY INDEXES (Critical for JOIN performance)
-- =============================================================================

-- These indexes are essential for foreign key performance
CREATE INDEX IF NOT EXISTS idx_fk_participant_identifiers_participant ON kernel.participant_identifiers(participant_id);
CREATE INDEX IF NOT EXISTS idx_fk_devices_owner ON kernel.devices(current_owner_id);
CREATE INDEX IF NOT EXISTS idx_fk_devices_tenant ON kernel.devices(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fk_insurance_policies_device ON kernel.insurance_policies(device_id);
CREATE INDEX IF NOT EXISTS idx_fk_insurance_policies_insurer ON kernel.insurance_policies(insurer_id);
CREATE INDEX IF NOT EXISTS idx_fk_insurance_policies_holder ON kernel.insurance_policies(policyholder_id);
CREATE INDEX IF NOT EXISTS idx_fk_claims_policy ON kernel.claims(policy_id);
CREATE INDEX IF NOT EXISTS idx_fk_claims_device ON kernel.claims(device_id);
CREATE INDEX IF NOT EXISTS idx_fk_repair_orders_device ON kernel.repair_orders(device_id);
CREATE INDEX IF NOT EXISTS idx_fk_repair_orders_customer ON kernel.repair_orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_fk_sales_orders_customer ON kernel.sales_orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_fk_payments_order ON kernel.payments(sales_order_id);
CREATE INDEX IF NOT EXISTS idx_fk_movement_legs_movement ON kernel.movement_legs(movement_id);
CREATE INDEX IF NOT EXISTS idx_fk_movement_legs_container ON kernel.movement_legs(container_id);
CREATE INDEX IF NOT EXISTS idx_fk_movement_postings_leg ON kernel.movement_postings(leg_id);
CREATE INDEX IF NOT EXISTS idx_fk_sub_accounts_master ON kernel.sub_accounts(master_account_id);
CREATE INDEX IF NOT EXISTS idx_fk_sub_accounts_owner ON kernel.sub_accounts(owner_participant_id);
CREATE INDEX IF NOT EXISTS idx_fk_master_accounts_container ON kernel.master_accounts(container_id);
CREATE INDEX IF NOT EXISTS idx_fk_datoms_participant ON kernel.datoms(participant_id);
CREATE INDEX IF NOT EXISTS idx_fk_datoms_device ON kernel.datoms(device_id);

-- =============================================================================
-- FOREIGN KEY CONSTRAINTS (Deferred for batch operations)
-- =============================================================================

-- Note: Most FKs are defined in table creation or in 029_kernel_wiring.sql.
-- Add any additional FKs here that weren't covered.

-- =============================================================================
-- EXCLUSION CONSTRAINTS (for temporal integrity)
-- =============================================================================

-- Prevent overlapping valid periods for the same entity (example)
-- Note: This requires btree_gist extension
-- CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ALTER TABLE kernel.insurance_policies 
--     ADD CONSTRAINT excl_overlapping_policies 
--     EXCLUDE USING gist (device_id WITH =, tstzrange(valid_from, COALESCE(valid_to, 'infinity'::timestamptz), '[)') WITH &&)
--     WHERE (system_to IS NULL);

-- =============================================================================
-- STATISTICS FOR QUERY OPTIMIZER
-- =============================================================================

-- Create extended statistics for correlated columns
CREATE STATISTICS IF NOT EXISTS stats_claims_status_date ON status, filed_at FROM kernel.claims;
CREATE STATISTICS IF NOT EXISTS stats_policies_status_dates ON status, effective_start_date, effective_end_date FROM kernel.insurance_policies;
CREATE STATISTICS IF NOT EXISTS stats_movements_currency_date ON currency_code, entry_date FROM kernel.value_movements;

-- Analyze tables to update statistics
ANALYZE kernel.participants;
ANALYZE kernel.devices;
ANALYZE kernel.insurance_policies;
ANALYZE kernel.claims;
ANALYZE kernel.value_movements;
ANALYZE kernel.value_containers;

-- =============================================================================
-- PARTITIONING SETUP (for time-series tables)
-- =============================================================================

-- Create monthly partitions for event_log (if not using TimescaleDB)
-- CREATE TABLE IF NOT EXISTS kernel.event_log_2024_01 PARTITION OF kernel.event_log
--     FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- Create monthly partitions for mutations
-- CREATE TABLE IF NOT EXISTS kernel.mutations_2024_01 PARTITION OF kernel.mutations
--     FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

-- =============================================================================
-- TENANT ID INDEXES (for performance on multi-tenant queries)
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_participants_tenant ON kernel.participants(tenant_id) WHERE tenant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_devices_tenant ON kernel.devices(tenant_id);
CREATE INDEX IF NOT EXISTS idx_insurance_policies_tenant ON kernel.insurance_policies(tenant_id);
CREATE INDEX IF NOT EXISTS idx_claims_tenant ON kernel.claims(tenant_id);
CREATE INDEX IF NOT EXISTS idx_repair_orders_tenant ON kernel.repair_orders(tenant_id);
CREATE INDEX IF NOT EXISTS idx_sales_orders_tenant ON kernel.sales_orders(tenant_id);
CREATE INDEX IF NOT EXISTS idx_value_containers_tenant ON kernel.value_containers(tenant_id);
CREATE INDEX IF NOT EXISTS idx_entity_sequences_tenant ON kernel.entity_sequences(tenant_id);

-- =============================================================================
-- ISO VALIDATION CHECK CONSTRAINTS
-- =============================================================================

-- Ensure currency codes are valid (exist in currencies table)
-- Note: This is enforced via foreign key to kernel.currencies

-- Ensure country codes follow ISO 3166-1 alpha-2 format
-- This would require a countries table FK or CHECK constraint

-- Additional LEI validation on any table storing LEI
-- Already on participants; add if other tables store LEI

-- =============================================================================
-- AUDIT LOG PARTITIONING SETUP
-- =============================================================================

-- Create partition for current month if partitioning is enabled
-- Note: Requires PostgreSQL 12+ native partitioning or TimescaleDB

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

SELECT 'Indexes and Constraints: Performance optimization applied' AS status;
