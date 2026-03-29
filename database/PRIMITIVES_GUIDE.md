# InsureLedger Kernel - 24 Primitives Reference Guide

This document provides a comprehensive reference for all 24 primitives implemented in the InsureLedger Enterprise Kernel.

## Quick Reference Table

| # | Primitive | Purpose | Key Tables | Status |
|---|-----------|---------|------------|--------|
| 1 | Identity & Tenancy | Tenant/participant management | `tenants`, `participants`, `identifiers` | ✅ Complete |
| 2 | Device & Product Registry | Digital twins & catalogs | `devices`, `product_catalog` | ✅ Complete |
| 3 | Economic Agents & Relationships | Agent graphs & KYC | `agents`, `agent_relationships` | ✅ Complete |
| 4 | Value Container | Universal accounts | `value_containers` | ✅ Complete |
| 5 | Value Movement & Double-Entry | Accounting | `value_movements`, `movement_legs` | ✅ Complete |
| 6 | Immutable Event Store & Datomic | Event log with indexes | `datoms` + universal indexes | ✅ Complete |
| 7 | Transaction Entity | Transaction lifecycle | `transactions` + status workflow | ✅ Complete |
| 8 | Product Contract Anchor | Immutable terms | `product_contract_anchors` | ✅ Complete |
| 9 | Real-Time Posting & Auth | Instant authorization | `real_time_postings` | ✅ Complete |
| 10 | Insurance Policy & Claim | Domain-specific | `insurance_policies`, `claims` | ✅ Complete |
| 11 | Repair Order & Service | Repair workflows | `repair_orders` | ✅ Complete |
| 12 | E-Commerce Sales | Sales & fulfillment | `sales_transactions` | ✅ Complete |
| 13 | Settlement & Finality | Financial settlement | `settlement_instructions` | 📋 Basic |
| 14 | Reconciliation & Suspense | Bank reconciliation | `reconciliation_runs`, `suspense_items` | ✅ Complete |
| 15 | Control & Batch Processing | Batch & EOD | `control_batches`, `eod_runs` | ✅ Complete |
| 16 | Entitlements & Authorization | Granular permissions | `entitlements`, `authorizations` | ✅ Complete |
| 17 | Geography & Jurisdiction | Business days & holidays | `jurisdictions`, `addresses` | ✅ Complete |
| 18 | Document Management | Documents & retention | `documents` | ✅ Complete |
| 19 | Sub-Ledger & Segregation | Client money | `master_accounts`, `sub_accounts` | ✅ Complete |
| 20 | Capital & Liquidity | Regulatory reporting | `capital_positions`, `lcr_calculations` | ✅ Complete |
| 21 | Streaming & Mutation Log | Real-time events | `streaming_mutation_log` | ✅ Complete |
| 22 | Peer Caching | Content-addressable cache | `cache_segments`, `peer_registry` | ✅ Complete |
| 23 | Columnar Compression & Archival | S3/Parquet archival | `archival_policies`, `cold_storage_index` | ✅ Complete |
| 24 | Kernel Wiring & Health Checks | Operational readiness | `health_check_full()` | ✅ Complete |

---

## Primitive Details

### Primitive 1: Identity & Tenancy

**Purpose**: Manage tenants (repair technicians/shops) and all participants with tenant isolation via RLS.

**Key Tables**:
- `kernel.participants` - All actors (customers, insurers, OEMs, etc.)
- `kernel.technician_tenants` - Repair shop specializations
- `kernel.participant_identifiers` - Multiple IDs per participant
- `security.participant_keys` - Public keys for signatures

**Key Features**:
- Row-Level Security (RLS) on all tenant tables
- Correlation and idempotency keys
- GDPR-compliant data masking

**Usage**:
```sql
-- Register a participant
SELECT kernel.register_participant(
    'insurer', 'SafeGuard Insurance', ...
);

-- Set tenant context for RLS
SELECT security.set_tenant_context('tenant-uuid');
```

---

### Primitive 2: Device & Product Registry

**Purpose**: Maintain digital twins of devices and product catalogs.

**Key Tables**:
- `kernel.devices` - Physical device records
- `kernel.product_catalog` - Insurance plans, repair services, ecommerce items
- `kernel.device_diagnostics` - Pre/post repair diagnostics

**Key Features**:
- Device type constraints (5 allowed types)
- Digital twin with unique hash
- Product versioning with bitemporal support

---

### Primitive 3: Economic Agents & Relationships

**Purpose**: Extend participants with agent capabilities and graph relationships.

**Key Tables**:
- (Uses `kernel.participants` with agent roles)
- `kernel.agent_relationships` - Directed edges (ownership, control, etc.)
- `kernel.sanctions_screenings` - Sanctions checks
- `kernel.kyc_verifications` - KYC event log

**Key Features**:
- 10 relationship types (ownership, control, employment, etc.)
- Circular ownership detection
- Full bitemporal history

---

### Primitive 4: Value Container

**Purpose**: Universal accounts for storing value with double-entry semantics.

**Key Tables**:
- `kernel.value_containers` - Universal accounts (asset, liability, equity, income, expense)
- `kernel.container_constraints` - Per-container limits
- `kernel.velocity_limits` - Sliding window counters
- `kernel.container_balances_history` - Balance snapshots

**Key Features**:
- Virtual accounts via `is_virtual` flag
- Hierarchical accounts with LTREE paths
- RLS for tenant isolation

**Usage**:
```sql
-- Create a customer wallet
INSERT INTO kernel.value_containers (
    account_class, account_type, owner_participant_id,
    currency_code, account_name
) VALUES ('asset', 'wallet', 'customer-uuid', 'USD', 'Main Wallet');
```

---

### Primitive 5: Value Movement & Double-Entry

**Purpose**: Immutable double-entry movement records enforcing conservation of value.

**Key Tables**:
- `kernel.value_movements` - Movement headers
- `kernel.movement_legs` - Debit/credit legs
- `kernel.movement_postings` - Historical postings

**Key Features**:
- Conservation check: `total_debits = total_credits`
- Immutable after posting
- Multi-currency support

**Usage**:
```sql
-- Create a transfer
SELECT kernel.create_transfer(
    'from-container-uuid',
    'to-container-uuid',
    100.00,
    'USD',
    'Payment for repair'
);
```

---

### Primitive 6: Immutable Event Store & Datomic Model

**Purpose**: Core event log with cryptographic chain, Merkle trees, and Datomic-style EAVT.

**Key Tables**:
- `kernel.datoms` - Atomic facts (E-A-V-Tx-Op)
- `kernel.zk_verification_log` - Zero-knowledge proof verifications

**Universal Indexes**:
- EAVT: Entity-Attribute-Value-Time
- AVET: Attribute-Value-Entity-Time
- AEVT: Attribute-Entity-Value-Time
- VAET: Value-Attribute-Entity-Time

**Key Features**:
- Zero-knowledge proof hooks
- Post-quantum readiness (pluggable algorithms)
- Blockchain anchoring

**Usage**:
```sql
-- Assert a fact
SELECT kernel.assert_fact(
    'device-uuid',
    'device',
    'status',
    '{"value": "active"}'
);

-- Query entity state
SELECT kernel.entity_as_of('device-uuid', '2024-01-15'::TIMESTAMP);
```

---

### Primitive 7: Transaction Entity

**Purpose**: Group related events into atomic units with status workflow.

**Key Tables**:
- `kernel.transactions` - Transaction records
- `kernel.transaction_events` - Link to datoms
- `kernel.transaction_movements` - Link to value movements
- `kernel.transaction_audit_log` - Step-by-step execution log
- `kernel.transaction_status_history` - State machine transitions

**Key Features**:
- Status workflow: pending → preparing → executing → committed/aborted
- Compensation chains for sagas
- 4-eyes approval support

**Usage**:
```sql
-- Create and execute transaction
SELECT kernel.create_transaction('repair_order', 'initiator-uuid');
SELECT kernel.start_transaction_execution('tx-uuid');
SELECT kernel.commit_transaction('tx-uuid');
```

---

### Primitive 8: Product Contract Anchor

**Purpose**: Immutable cryptographic anchor for product definitions.

**Key Tables**:
- `kernel.product_catalog` - Base products
- `kernel.product_contract_anchors` - Immutable contract versions
- `kernel.contract_dependencies` - Upgrade graph

**Key Features**:
- UUID v5 deterministic hashing
- Version chain with parent references
- Launch signatures

**Usage**:
```sql
-- Deploy product contract
SELECT kernel.deploy_product_contract(
    'product-uuid',
    '{"coverage": "comprehensive", "deductible": 100}',
    'signer-uuid',
    'signature'
);
```

---

### Primitive 9: Real-Time Posting & Authorization

**Purpose**: Instant authorization with velocity checks and JIT funding.

**Key Tables**:
- `kernel.real_time_postings` - Auth requests
- `kernel.velocity_limit_counters` - Sliding windows
- `kernel.jit_funding_log` - JIT funding audit

**Key Features**:
- <10ms target decision time
- Velocity checks per transaction/minute/hour/day
- JIT funding from master accounts
- Ring-fencing support
- Commando override for emergencies

**Usage**:
```sql
-- Process authorization
SELECT * FROM kernel.process_real_time_auth(
    'container-uuid',
    150.00,
    'USD',
    'merchant-uuid',
    'contract-hash'
);
```

---

### Primitive 10: Insurance Policy & Claim

**Purpose**: Domain-specific tables for insurance.

**Key Tables**:
- `kernel.insurance_policies` - Policy records
- `kernel.claims` - Claim records
- `kernel.claim_documents` - Document links

**Key Features**:
- Product contract anchor locking
- Claim assessment workflow
- Repair order integration

---

### Primitive 11: Repair Order & Service

**Purpose**: Manage repair workflows.

**Key Tables**:
- `kernel.repair_orders` - Work orders
- `kernel.repair_diagnostics` - Diagnostic links
- `kernel.repair_parts` - Parts used

**Key Features**:
- RLS for technician isolation
- Status transitions tracked
- Warranty extensions

---

### Primitive 12: E-Commerce Sales & Fulfillment

**Purpose**: Sales transactions and order processing.

**Key Tables**:
- `kernel.sales_transactions` - Sales records
- (Order items tracked in JSONB)

---

### Primitive 13: Settlement & Finality

**Purpose**: Settle financial transactions with finality tracking.

**Key Tables**:
- `kernel.settlement_instructions` - Settlement records
- `kernel.settlement_batches` - Batch settlements
- `kernel.liquidity_positions` - Real-time liquidity

**Key Features**:
- Provisional vs final settlement
- DvP (Delivery vs Payment) support
- Blockchain finality log

---

### Primitive 14: Reconciliation & Suspense

**Purpose**: Match internal transactions with external statements.

**Key Tables**:
- `kernel.reconciliation_runs` - Reconciliation runs
- `kernel.reconciliation_items` - Individual matches
- `kernel.reconciliation_rules` - Auto-matching rules
- `kernel.suspense_items` - Unmatched items

**Key Features**:
- Auto-match with fuzzy matching
- Aging analysis
- Suspense resolution

**Usage**:
```sql
-- Create reconciliation run
SELECT kernel.create_reconciliation_run(
    '2024-01-15', 'bank_name', 10000.00, 15000.00
);

-- Auto-match items
SELECT * FROM kernel.match_reconciliation_items('run-uuid');
```

---

### Primitive 15: Control & Batch Processing

**Purpose**: Bulk operations with control totals and EOD processing.

**Key Tables**:
- `kernel.control_batches` - Batches with hash totals
- `kernel.control_entries` - Individual entries
- `kernel.eod_runs` - End-of-day runs
- `kernel.eod_stages` - Configurable stages

**Key Features**:
- Hash totals for integrity
- EOD stage orchestration
- Validation rules

---

### Primitive 16: Entitlements & Authorization

**Purpose**: Fine-grained access control with limits.

**Key Tables**:
- `kernel.entitlements` - Permissions with limits
- `kernel.authorizations` - Digital signatures
- `kernel.authorization_attempts` - Audit log

**Key Features**:
- Per-transaction and daily limits
- Scheme restrictions (Visa, SEPA, etc.)
- Corridor restrictions
- 4-eyes principle

---

### Primitive 17: Geography & Jurisdiction

**Purpose**: Geographic data and business day calculations.

**Key Tables**:
- `kernel.jurisdictions` - Hierarchical jurisdictions
- `kernel.holiday_calendars` - Holiday definitions
- `kernel.addresses` - Structured addresses with geocoding

**Key Functions**:
```sql
SELECT kernel.is_business_day('US', '2024-01-15');
SELECT kernel.next_business_day('US', '2024-01-15', 3);
SELECT kernel.count_business_days('US', '2024-01-01', '2024-01-31');
```

---

### Primitive 18: Document Management

**Purpose**: Document storage with retention policies.

**Key Tables**:
- `kernel.documents` - Document metadata
- `kernel.document_versions` - Version history
- `kernel.retention_policies` - Retention rules
- `kernel.document_retention_queue` - Scheduled actions

**Key Features**:
- Content hashing for integrity
- Legal holds
- Automatic deletion/archival

---

### Primitive 19: Sub-Ledger & Segregation

**Purpose**: Client money segregation.

**Key Tables**:
- `kernel.master_accounts` - Omnibus accounts
- `kernel.sub_accounts` - Client sub-accounts
- `kernel.sub_ledger_reconciliations` - Daily reconciliation
- `kernel.client_money_calculations` - CASS compliance

**Key Features**:
- Conservation: sum(sub-accounts) = master
- Daily reconciliation
- Regulatory reporting

---

### Primitive 20: Capital & Liquidity

**Purpose**: Regulatory capital reporting (optional).

**Key Tables**:
- `kernel.exposure_positions` - Credit/market/operational
- `kernel.capital_positions` - CET1, Tier 1, Total
- `kernel.lcr_calculations` - Liquidity Coverage Ratio
- `kernel.stress_test_results` - Stress testing

**Key Features**:
- Basel III compliant
- Stress scenario modeling
- COREP/FINREP reporting

---

### Primitive 21: Streaming & Mutation Log

**Purpose**: Real-time event streaming.

**Key Tables**:
- `kernel.streaming_mutation_log` - Append-only change log
- `kernel.streaming_subscribers` - Webhook/Kafka subscribers
- `kernel.streaming_dead_letter` - Failed deliveries

**Key Features**:
- pg_notify for real-time
- Webhook delivery
- Kafka integration hooks
- 4D bitemporal replay

---

### Primitive 22: Peer Caching

**Purpose**: Content-addressable cache.

**Key Tables**:
- `kernel.peer_registry` - Cache nodes
- `kernel.cache_segments` - Content-addressable storage
- `kernel.cache_invalidation_stream` - Invalidation events

**Key Features**:
- Hash-based content lookup
- Automatic invalidation
- Query peer selection

---

### Primitive 23: Columnar Compression & Archival

**Purpose**: Automated data lifecycle.

**Key Tables**:
- `kernel.archival_policies` - Lifecycle rules
- `kernel.archival_jobs` - Job tracking
- `kernel.cold_storage_index` - S3/GCS catalog

**Key Features**:
- TimescaleDB compression
- S3/Parquet export
- Signed URL retrieval

---

### Primitive 24: Kernel Wiring & Health Checks

**Purpose**: Operational readiness.

**Key Functions**:
```sql
-- Full health check
SELECT * FROM kernel.health_check_full();

-- System status
SELECT * FROM kernel.system_status;

-- Generate RLS policies
SELECT kernel.generate_rls_policies();

-- Setup replication
SELECT kernel.setup_replication_publication();
```

**Key Tables**:
- `kernel.scheduled_jobs` - pg_cron job definitions
- `kernel.health_check_results` - Health check history

---

## Integration Examples

### End-to-End Repair Flow

```sql
-- 1. Set tenant context
SELECT security.set_tenant_context('tech-shop-uuid');

-- 2. Create repair order (Primitive 11)
SELECT kernel.create_repair_order(...);

-- 3. Process payment authorization (Primitive 9)
SELECT * FROM kernel.process_real_time_auth(...);

-- 4. Create value movement (Primitive 5)
SELECT kernel.create_transfer(...);

-- 5. Assert fact to event store (Primitive 6)
SELECT kernel.assert_fact(...);

-- 6. Create transaction grouping (Primitive 7)
SELECT kernel.create_transaction('repair_order', ...);
```

### Insurance Claim Flow

```sql
-- 1. File claim (Primitive 10)
SELECT kernel.file_claim(...);

-- 2. Check entitlement (Primitive 16)
SELECT * FROM kernel.check_entitlement(...);

-- 3. Assess and approve
SELECT kernel.assess_claim(...);

-- 4. Create settlement (Primitive 13)
-- 5. Reconcile (Primitive 14)
```

---

## Performance Considerations

### Indexes

Each primitive includes optimized indexes:
- B-tree for equality and range queries
- GIN for JSONB and full-text search
- GiST for LTREE and geographic data
- BRIN for time-series data

### Partitioning

Recommended for high-volume tables:
```sql
-- TimescaleDB hypertables
SELECT create_hypertable('kernel.streaming_mutation_log', 'created_at');
SELECT create_hypertable('kernel.document_access_logs', 'accessed_at');
```

### Archival

Configure archival policies:
```sql
INSERT INTO kernel.archival_policies (
    target_table, hot_retention_days, archive_format
) VALUES ('audit_logs', 90, 'parquet');
```

---

## Monitoring

### Health Checks

```sql
-- Run comprehensive health check
SELECT * FROM kernel.health_check_full();

-- View system status
SELECT * FROM kernel.system_status;

-- View recent health results
SELECT * FROM kernel.health_check_results
ORDER BY check_run_at DESC
LIMIT 10;
```

### Metrics

```sql
-- Table statistics
SELECT * FROM kernel.table_statistics;

-- Index usage
SELECT * FROM kernel.index_statistics;

-- Slow queries
SELECT * FROM kernel.slow_query_statistics;
```

---

## Security

### RLS Policies

All tenant-scoped tables have RLS enabled:
```sql
-- View RLS policies
SELECT * FROM pg_policies WHERE schemaname = 'kernel';

-- Force RLS for table owner
ALTER TABLE kernel.repair_orders FORCE ROW LEVEL SECURITY;
```

### Audit Trail

```sql
-- View audit trail
SELECT * FROM audit.audit_logs
ORDER BY event_timestamp DESC
LIMIT 100;

-- Verify audit chain
SELECT * FROM test.verify_immutability();
```

---

## Compliance

### GDPR

- Data masking in `participants` table
- Document retention policies
- Right to deletion via `legal_hold` mechanism

### SOX

- Immutable audit trails
- Segregation of duties via entitlements
- Sub-ledger reconciliation

### Basel III

- Capital & liquidity calculations
- Stress testing framework
- Exposure tracking

---

## Migration from Basic Kernel

If upgrading from the basic InsureLedger kernel:

```sql
-- Run upgrade script
\i upgrade_to_enterprise.sql

-- Verify health
SELECT * FROM kernel.health_check_full();

-- Configure new features
INSERT INTO kernel.archival_policies (...) VALUES (...);
INSERT INTO kernel.retention_policies (...) VALUES (...);
```
