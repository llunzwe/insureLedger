# InsureLedger Enterprise Kernel

## Overview

The **InsureLedger Enterprise Kernel** is a comprehensive, production-ready immutable ledger engine for the smartphone repair, e-commerce, and insurance ecosystem. It implements all 24 primitives from the FINOS-inspired design specification.

## What's New in Enterprise Edition

### Core Capabilities Added

| Feature | Description |
|---------|-------------|
| **Double-Entry Accounting** | Full accounting system with conservation of value |
| **Universal Datomic Indexes** | EAVT, AVET, AEVT, VAET for efficient queries |
| **Transaction Lifecycle** | Complete saga pattern with compensation |
| **Product Contract Anchors** | Immutable terms at point of sale |
| **Real-Time Authorization** | <10ms decisions with velocity checks |
| **Bank Reconciliation** | Auto-matching with suspense management |
| **EOD Processing** | Configurable batch processing stages |
| **Business Day Logic** | Holiday calendars across jurisdictions |
| **Document Management** | Retention policies and legal holds |
| **Client Money Segregation** | Master/sub-ledger structure |
| **Capital & Liquidity** | Basel III regulatory reporting |
| **Event Streaming** | Real-time webhooks and Kafka integration |
| **Peer Caching** | Content-addressable query acceleration |
| **Cold Storage** | Automated S3/Parquet archival |
| **Granular Entitlements** | Limits, schemes, corridors, 4-eyes |
| **Health Monitoring** | Comprehensive operational checks |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PRESENTATION LAYER                                  │
│                    (API Gateway, Webhooks, Kafka)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                         STREAMING LAYER (Primitive 21)                      │
│                  Mutation Log → Subscribers → Webhooks/Kafka               │
├─────────────────────────────────────────────────────────────────────────────┤
│                         CACHING LAYER (Primitive 22)                        │
│                  Content-Addressable Cache → Query Acceleration             │
├─────────────────────────────────────────────────────────────────────────────┤
│                         APPLICATION LAYER                                   │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐           │
│  │  Insurance  │ │   Repair    │ │  E-Commerce │ │   Claims    │           │
│  │ (Primitive) │ │ (Primitive) │ │ (Primitive) │ │ (Primitive) │           │
│  │     10      │ │     11      │ │     12      │ │     10      │           │
│  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘ └──────┬──────┘           │
├───────┼─────────────┼─────────────┼─────────────────────┤                   │
│       │             │             │                     │                   │
│  ┌────▼────┐   ┌────▼────┐   ┌────▼────┐         ┌────▼────┐              │
│  │Product  │   │ Real-Time│   │Settlement│         │Reconcile │              │
│  │Contract │   │  Auth    │   │ (13)     │         │  (14)    │              │
│  │  (8)    │   │   (9)    │   │          │         │          │              │
│  └─────────┘   └─────────┘   └─────────┘         └─────────┘              │
├─────────────────────────────────────────────────────────────────────────────┤
│                         CORE KERNEL PRIMITIVES                              │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    TRANSACTION ENTITY (7)                            │   │
│  │   Groups: Events (6) + Movements (5) + Authorizations (16)          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐          │
│  │   Value     │ │   Datomic   │ │   Document  │ │  Geography  │          │
│  │ Containers  │ │  Event Store│ │ Management  │ │Jurisdiction │          │
│  │    (4)      │ │    (6)      │ │    (18)     │ │    (17)     │          │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘          │
├─────────────────────────────────────────────────────────────────────────────┤
│                         IDENTITY & SECURITY                                 │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐          │
│  │  Identity & │ │   Economic  │ │Entitlements │ │   Health    │          │
│  │   Tenancy   │ │   Agents    │ │     &       │ │   Checks    │          │
│  │    (1)      │ │    (3)      │ │   Auth      │ │    (24)     │          │
│  │             │ │             │ │   (16)      │ │             │          │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘          │
├─────────────────────────────────────────────────────────────────────────────┤
│                         ACCOUNTING & COMPLIANCE                             │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐          │
│  │   Double-   │ │  Sub-Ledger │ │   Capital   │ │   Control   │          │
│  │   Entry     │ │Segregation  │ │    &        │ │    &        │          │
│  │  Movement   │ │    (19)     │ │ Liquidity   │ │    EOD      │          │
│  │    (5)      │ │             │ │    (20)     │ │   (15)      │          │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘          │
├─────────────────────────────────────────────────────────────────────────────┤
│                         DATA LIFECYCLE                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │              ARCHIVAL & COMPRESSION (23)                             │   │
│  │   TimescaleDB Compression → Parquet Export → S3 Cold Storage        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## File Structure

```
database/
├── 01_schema_setup.sql                    # Foundation: extensions, schemas
├── 02_crypto_utilities.sql                # Cryptographic functions
├── 03_base_entities.sql                   # Common properties
├── 04_core_primitives_part1.sql           # Participants, Devices
├── 04_core_primitives_part2.sql           # Insurance, Claims, Sales
├── 04_core_primitives_part3.sql           # Event Store, Merkle Trees
├── 04_core_primitives_part4.sql           # Diagnostics, VCs, Audit
├── 05_audit_immutability.sql              # Triggers, hash computation
├── 06_rls_policies.sql                    # Row-Level Security
├── 07_stored_procedures.sql               # Business logic
├── 08_indexes_constraints.sql             # Performance optimization
├── 09_seed_data.sql                       # Test data
│
├── 10_primitive_4_5_value_accounting.sql  # Value containers & movements
├── 11_primitive_6_7_datomic_transaction.sql # Datomic indexes & transactions
├── 12_primitive_8_9_contract_auth.sql     # Product contracts & real-time auth
├── 13_primitive_14_15_recon_batch.sql     # Reconciliation & batch processing
├── 14_primitive_17_18_geo_docs.sql        # Geography & document management
├── 15_primitive_19_20_ledger_capital.sql  # Sub-ledger & capital tracking
├── 16_primitive_21_22_23_streaming_caching_archival.sql # Streaming & archival
├── 17_primitive_16_24_entitlements_health.sql # Entitlements & health checks
│
├── deploy.sql                             # Basic deployment
├── deploy_complete.sql                    # Enterprise deployment
├── deploy.sh                              # Shell deployment script
│
├── README.md                              # Basic documentation
├── README_ENTERPRISE.md                   # This file
├── PRIMITIVES_GUIDE.md                    # 24 primitives reference
├── QUICK_REFERENCE.md                     # Developer quick reference
└── ER_DIAGRAM.md                          # Entity relationships
```

## Quick Start

### Prerequisites

- PostgreSQL 14+ (15+ recommended)
- Extensions: `uuid-ossp`, `pgcrypto`, `btree_gist`, `ltree`
- Optional: TimescaleDB, PostGIS

### Deployment

```bash
# Create database
createdb insureledger

# Deploy complete enterprise kernel
psql -U postgres -d insureledger -f database/deploy_complete.sql

# Load seed data (optional)
psql -U postgres -d insureledger -f database/09_seed_data.sql
```

### Verification

```sql
-- Check system status
SELECT * FROM kernel.system_status;

-- Run health check
SELECT * FROM kernel.health_check_full();

-- View deployment statistics
SELECT 
    (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'kernel') as tables,
    (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'kernel') as functions;
```

## Key Features

### 1. Bitemporal Tracking

All records track both system time (audit) and valid time (business):

```sql
SELECT * FROM kernel.devices
WHERE system_to IS NULL           -- Current system version
  AND valid_from <= NOW()         -- Currently valid
  AND (valid_to IS NULL OR valid_to > NOW());
```

### 2. Cryptographic Integrity

Every record includes hash chaining:

```sql
SELECT 
    device_id,
    substring(previous_hash, 1, 16) as prev,
    substring(current_hash, 1, 16) as current
FROM kernel.devices
WHERE system_to IS NULL;
```

### 3. Double-Entry Accounting

Conservation of value enforced:

```sql
-- Create transfer with automatic balancing
SELECT kernel.create_transfer(
    'from-container-uuid',
    'to-container-uuid', 
    100.00,
    'USD',
    'Repair payment'
);
```

### 4. Real-Time Authorization

Sub-10ms authorization decisions:

```sql
SELECT * FROM kernel.process_real_time_auth(
    'container-uuid',
    150.00,
    'USD',
    'merchant-uuid'
);
```

### 5. Event Streaming

Real-time change notifications:

```sql
-- Listen for mutations
LISTEN mutation_stream;

-- Published automatically on all changes
```

## Use Cases

### Insurance Policy Issuance

```sql
-- 1. Deploy product contract (locks terms)
SELECT kernel.deploy_product_contract(
    'product-uuid',
    '{"coverage": "comprehensive", "deductible": 100}',
    'signer-uuid',
    'signature'
);

-- 2. Create policy with contract hash
INSERT INTO kernel.insurance_policies (
    policy_number, device_id, product_contract_hash, ...
) VALUES (...);

-- 3. Collect premium
SELECT kernel.create_transfer(
    'customer-wallet',
    'insurer-premium-account',
    premium_amount,
    'USD'
);
```

### Repair Workflow

```sql
-- 1. Set tenant context
SELECT security.set_tenant_context('repair-shop-uuid');

-- 2. Create repair order
SELECT kernel.create_repair_order(
    'tenant-uuid',
    'device-uuid',
    'customer-uuid',
    'Screen cracked'
);

-- 3. Process payment authorization
SELECT * FROM kernel.process_real_time_auth(...);

-- 4. Complete repair
SELECT kernel.complete_repair_order(
    'repair-order-uuid',
    '[{"part_id": "...", "quantity": 1}]',
    2.5,  -- labor hours
    150.00,  -- labor cost
    89.99   -- parts cost
);
```

### End-of-Day Processing

```sql
-- 1. Start EOD run
SELECT kernel.start_eod_run('2024-01-15', 'final');

-- 2. Execute stages (automatic via pg_cron)
-- Or manually:
SELECT kernel.execute_eod_stage('run-uuid', 'stage-uuid');

-- 3. Reconcile sub-ledgers
SELECT * FROM kernel.reconcile_sub_ledger('master-account-uuid');

-- 4. Generate reports
-- ...
```

## Performance Tuning

### Indexes

All primitives include optimized indexes. Additional indexes for specific queries:

```sql
-- Custom index for frequent query
CREATE INDEX idx_custom ON kernel.claims(adjuster_id, status) 
WHERE status IN ('filed', 'under_review');
```

### Partitioning

Enable TimescaleDB for high-volume tables:

```sql
-- Convert to hypertable
SELECT create_hypertable('kernel.streaming_mutation_log', 'created_at');

-- Set compression policy
SELECT add_compression_policy('kernel.streaming_mutation_log', INTERVAL '7 days');
```

### Archival

Configure data lifecycle:

```sql
INSERT INTO kernel.archival_policies (
    target_table,
    hot_retention_days,
    compression_after_days,
    archive_format,
    archive_storage_backend
) VALUES (
    'audit_logs',
    90,
    7,
    'parquet',
    's3'
);
```

## Security

### Row-Level Security

All tenant-scoped tables enforce RLS:

```sql
-- Set context before queries
SELECT security.set_tenant_context('tenant-uuid');
SELECT security.set_participant_context('user-uuid');

-- Queries automatically filtered
SELECT * FROM kernel.repair_orders;  -- Only tenant's orders
```

### Entitlements

Fine-grained access control:

```sql
-- Check entitlement
SELECT * FROM kernel.check_entitlement(
    'agent-uuid',
    'debit',
    'container-uuid',
    1000.00
);
```

### Audit Trail

Immutable audit logging:

```sql
-- View audit trail
SELECT * FROM audit.audit_logs
WHERE target_row_id = 'record-uuid'
ORDER BY event_timestamp DESC;
```

## Monitoring

### Health Checks

```sql
-- Comprehensive health check
SELECT * FROM kernel.health_check_full();

-- System status overview
SELECT * FROM kernel.system_status;

-- Recent health results
SELECT * FROM kernel.health_check_results
ORDER BY check_run_at DESC
LIMIT 10;
```

### Metrics

```sql
-- Table sizes
SELECT * FROM kernel.table_statistics;

-- Index usage
SELECT * FROM kernel.index_statistics;

-- Slow queries (requires pg_stat_statements)
SELECT * FROM kernel.slow_query_statistics;
```

## Compliance

| Regulation | Feature | Implementation |
|------------|---------|----------------|
| **GDPR** | Right to deletion | Legal holds + retention policies |
| **SOX** | Audit trails | Immutable audit_logs with hash chain |
| **Basel III** | Capital reporting | `capital_positions`, `lcr_calculations` tables |
| **PCI DSS** | Tokenization | `instrument_token` in `real_time_postings` |
| **CASS** | Client money | `master_accounts`, `sub_accounts`, reconciliation |

## Troubleshooting

### Health Check Failures

```sql
-- Check specific component
SELECT * FROM kernel.health_check_results
ORDER BY check_run_at DESC
LIMIT 1;

-- View details
SELECT tables_check_details 
FROM kernel.health_check_results 
ORDER BY check_run_at DESC 
LIMIT 1;
```

### Performance Issues

```sql
-- Identify missing indexes
SELECT 
    schemaname, tablename, attname as column,
    n_tup_read, n_tup_fetch
FROM pg_stats 
WHERE schemaname = 'kernel'
  AND n_tup_read > 100000
  AND NOT EXISTS (
      SELECT 1 FROM pg_indexes 
      WHERE indexdef LIKE '%' || attname || '%'
        AND tablename = pg_stats.tablename
  );
```

### RLS Issues

```sql
-- Check RLS is enabled
SELECT tablename, relrowsecurity 
FROM pg_tables t
JOIN pg_class c ON c.relname = t.tablename
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'kernel';

-- View policies
SELECT * FROM pg_policies WHERE schemaname = 'kernel';
```

## Support

For issues and feature requests:

1. Check `PRIMITIVES_GUIDE.md` for detailed primitive documentation
2. Review `QUICK_REFERENCE.md` for common queries
3. Run `SELECT * FROM kernel.health_check_full()` for diagnostics

## License

Enterprise License - InsureLedger Core Team

---

**Version**: 2.0.0 Enterprise  
**Last Updated**: 2024-03-28  
**Compatibility**: PostgreSQL 14+
