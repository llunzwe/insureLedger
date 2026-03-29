# InsureLedger Kernel - PostgreSQL Implementation

An enterprise-grade immutable ledger kernel with bitemporal tracking, cryptographic chaining, and multi-tenant architecture, implemented in PostgreSQL.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Features](#core-features)
3. [Schema Organization](#schema-organization)
4. [Entity Models](#entity-models)
5. [Deployment](#deployment)
6. [Usage Examples](#usage-examples)
7. [Security](#security)
8. [Performance](#performance)
9. [Maintenance](#maintenance)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         INSURE LEDGER KERNEL                                │
├─────────────────────────────────────────────────────────────────────────────┤
│  SECURITY LAYER          │  AUDIT LAYER          │  CRYPTO LAYER          │
│  • RLS Policies          │  • Audit Logs         │  • SHA-256 Hashing     │
│  • RBAC Permissions      │  • Chain Verification │  • Merkle Trees        │
│  • Tenant Isolation      │  • Compliance Tags    │  • Digital Signatures  │
├─────────────────────────────────────────────────────────────────────────────┤
│                         CORE KERNEL PRIMITIVES                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  PARTICIPANTS    │  DEVICES       │  INSURANCE      │  REPAIRS            │
│  • Customers     │  • Smartphones │  • Policies     │  • Orders           │
│  • Insurers      │  • Laptops     │  • Claims       │  • Diagnostics      │
│  • Technicians   │  • Tablets     │  • Coverage     │  • Parts            │
│  • OEMs          │  • IoT         │  • Payouts      │  • Certifications   │
├─────────────────────────────────────────────────────────────────────────────┤
│                         EVENT STORE (DATOMIC-STYLE)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  DATOMS (EAVT)  │  TRANSACTIONS  │  MERKLE ROOTS   │  BLOCKCHAIN ANCHORS │
│  Entity         │  Atomic Groups │  Batch Hashes   │  External Notarization
│  Attribute      │  Commits       │  Inclusion Proofs                     │
│  Value          │  Signatures    │  Verifiability                        │
│  Transaction    │  Context       │                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Core Features

### 1. Immutability
- Append-only data model
- Cryptographic hash chains linking records
- Update and delete prevention via triggers
- Versioning through new record insertion

### 2. Bitemporal Tracking
- **System Time**: When record was inserted (audit)
- **Valid Time**: When record is business-effective
- Supports time-travel queries
- Complete history preservation

### 3. Cryptographic Integrity
- SHA-256 hashing for all records
- Chain hashing with previous record reference
- Merkle tree roots for batch verification
- Blockchain anchoring support

### 4. Multi-Tenancy
- Row Level Security (RLS) policies
- Tenant context management
- Cross-tenant read permissions for insurers/regulators
- Isolated data per technician shop

### 5. Audit Trail
- Comprehensive audit logging
- Digital signatures for non-repudiation
- Compliance tagging (GDPR, SOX, etc.)
- Immutable audit chain

## Schema Organization

| Schema | Purpose | Tables |
|--------|---------|--------|
| `kernel` | Core business entities | devices, participants, policies, claims, repair_orders, etc. |
| `security` | Access control | permissions, role_definitions, session_context, participant_keys |
| `audit` | Compliance & forensics | audit_logs |
| `crypto` | Cryptographic utilities | Hash and signature functions |
| `temporal` | Bitemporal support | Time tracking functions |

## Entity Models

### 1. Participant (Base Entity)
Any actor in the ecosystem:
- **Identity**: UUID, DID, business/individual name
- **Contact**: Hashed email, phone, address
- **Credentials**: Verifiable credential references
- **Roles**: RBAC role assignments

### 2. TechnicianTenant
Repair shop/technician specialization:
- **Tenant ID**: For RLS isolation
- **Certifications**: OEM authorizations, ISO certifications
- **Geographic Scope**: Serviceable regions
- **Reputation**: Ratings and dispute history

### 3. Device
Physical gadget tracking:
- **Identity**: Serial, IMEI, MAC addresses
- **Software**: OS version, firmware, bootloader
- **Ownership**: Current and previous owners
- **Lifecycle**: Manufacture, activation, warranty dates

### 4. InsurancePolicy
Device coverage:
- **Coverage**: Type, limits, deductibles, exclusions
- **Premium**: Amount, billing frequency, risk score
- **Dynamic Pricing**: Based on device history and behavior
- **Claims**: Linked claim references

### 5. Claim
Indemnification request:
- **Incident**: Type, date, location, description
- **Evidence**: Photos, police reports, witness statements
- **Assessment**: Adjuster evaluation, damage amount
- **Payout**: Approved and actual amounts

### 6. RepairOrder
Device repair workflow:
- **Diagnostics**: Pre and post-repair assessments
- **Parts**: Used components with traceability
- **Costs**: Labor, parts, total
- **Timeline**: Scheduled, actual, completion dates

### 7. Datom (Event Store)
Datomic-style immutable facts:
- **EAVT Model**: Entity, Attribute, Value, Transaction
- **Operations**: Assert (add) or Retract (remove)
- **Temporal**: Both system and valid time tracking
- **Chaining**: Hash chain per entity/attribute

### 8. MerkleTreeRoot
Batch verification:
- **Time Window**: Covered transaction range
- **Tree Structure**: Root hash, depth, leaf count
- **Anchoring**: Blockchain network and transaction hash
- **Status**: Pending, anchored, confirmed

## Deployment

### Prerequisites
- PostgreSQL 14+ (15+ recommended)
- Extensions: `uuid-ossp`, `pgcrypto`, `btree_gist`

### Quick Start

```bash
# Create database
createdb insureledger

# Deploy schema
psql -U postgres -d insureledger -f database/deploy.sql

# Load seed data (optional)
psql -U postgres -d insureledger -f database/09_seed_data.sql
```

### Manual Deployment

```bash
# Run files in order
psql -d insureledger -f database/01_schema_setup.sql
psql -d insureledger -f database/02_crypto_utilities.sql
psql -d insureledger -f database/03_base_entities.sql
psql -d insureledger -f database/04_core_primitives_part1.sql
psql -d insureledger -f database/04_core_primitives_part2.sql
psql -d insureledger -f database/04_core_primitives_part3.sql
psql -d insureledger -f database/04_core_primitives_part4.sql
psql -d insureledger -f database/05_audit_immutability.sql
psql -d insureledger -f database/06_rls_policies.sql
psql -d insureledger -f database/07_stored_procedures.sql
psql -d insureledger -f database/08_indexes_constraints.sql
```

## Usage Examples

### Register a Participant

```sql
SELECT kernel.register_participant(
    'insurer',                    -- participant_type
    'SafeGuard Insurance',        -- business_name
    NULL,                         -- individual_name
    'did:insureledger:sg:001',    -- did
    '{"city": "New York"}'::JSONB, -- address
    'EIN123...',                  -- tax_id_hash
    'hash@email.com',             -- email_hash
    'hash@phone.com'              -- phone_hash
);
```

### Register a Device

```sql
SELECT kernel.register_device(
    'smartphone',              -- device_type
    'TechCorp',                -- manufacturer
    'UltraPhone 15',           -- model_name
    'TP15-256-BLK',            -- model_number
    'SN123456789',             -- serial_number
    '354601080768997',         -- imei
    '2024-01-15',              -- manufacture_date
    'a0000000-0000-0000-0000-000000000006'::UUID  -- owner_id
);
```

### Create Insurance Policy

```sql
SELECT kernel.create_insurance_policy(
    'd0000000-0000-0000-0000-000000000001'::UUID,  -- device_id
    'a0000000-0000-0000-0000-000000000001'::UUID,  -- insurer_id
    'a0000000-0000-0000-0000-000000000006'::UUID,  -- holder_id
    'comprehensive',           -- coverage_type
    1200.00,                   -- coverage_limit
    99.00,                     -- deductible
    15.99,                     -- premium
    '2024-03-15',              -- start_date
    '2025-03-15'               -- end_date
);
```

### File a Claim

```sql
SELECT kernel.file_claim(
    'f0000000-0000-0000-0000-000000000001'::UUID,  -- policy_id
    NOW(),                     -- incident_date
    'accidental_damage',       -- incident_type
    'Phone dropped, screen cracked',  -- description
    '{"city": "Austin"}'::JSONB     -- location
);
```

### Assert a Fact (Datomic-style)

```sql
SELECT kernel.assert_fact(
    'd0000000-0000-0000-0000-000000000001'::UUID,  -- entity_id
    'device',                  -- entity_type
    'warranty_status',         -- attribute
    '{"status": "valid"}'::JSONB   -- value
);
```

### Query Entity State

```sql
-- Get current state
SELECT kernel.get_entity_state('d0000000-0000-0000-0000-000000000001'::UUID);

-- Get state at specific time
SELECT kernel.get_entity_state(
    'd0000000-0000-0000-0000-000000000001'::UUID,
    '2024-01-15'::TIMESTAMP WITH TIME ZONE
);
```

### Set Tenant Context (for RLS)

```sql
-- Set tenant for technician operations
SELECT security.set_tenant_context('b0000000-0000-0000-0000-000000000001'::UUID);

-- Set participant context
SELECT security.set_participant_context('a0000000-0000-0000-0000-000000000005'::UUID);
```

## Security

### Row Level Security (RLS)

All tenant-scoped tables have RLS policies:

| Table | Policy | Access |
|-------|--------|--------|
| technician_tenants | Tenant isolation | Own tenant only |
| repair_orders | Multi-role | Tenant, customer, insurer |
| diagnostic_logs | Multi-role | Tenant, owner, insurer |
| parts | Tenant isolation | Own tenant only |

### RBAC Permissions

```sql
-- Grant permission
INSERT INTO security.permissions (
    participant_id,
    role_name,
    resource_type,
    resource_id_pattern,
    action,
    grantor_id
) VALUES (
    'technician_uuid',
    'technician',
    'repair_order',
    'tenant:abc:*',
    'write',
    'admin_uuid'
);
```

### Audit Trail

```sql
-- View recent audit entries
SELECT * FROM audit.audit_logs
ORDER BY event_timestamp DESC
LIMIT 100;

-- View audit chain integrity
SELECT 
    audit_entry_id,
    substring(current_hash, 1, 16) as hash_short,
    substring(previous_hash, 1, 16) as prev_hash_short
FROM audit.audit_logs
ORDER BY audit_entry_id;
```

## Performance

### Key Indexes

| Index | Type | Purpose |
|-------|------|---------|
| system_time | B-tree | Active record queries |
| valid_time | B-tree | Business time queries |
| tenant_id | B-tree | RLS performance |
| datoms_value | GIN | JSONB value search |
| *_fts | GIN | Full-text search |

### Monitoring

```sql
-- Table statistics
SELECT * FROM kernel.table_statistics;

-- Index usage
SELECT * FROM kernel.index_statistics;

-- Query performance
SELECT * FROM kernel.slow_query_statistics;
```

### Partitioning Recommendation

For high-volume deployments:

```sql
-- Partition audit_logs by month
CREATE TABLE audit.audit_logs_partitioned (
    LIKE audit.audit_logs INCLUDING ALL
) PARTITION BY RANGE (event_timestamp);
```

## Maintenance

### Archival

```sql
-- Archive records older than 2 years
SELECT kernel.archive_old_records('audit_logs', 'audit', NOW() - INTERVAL '2 years');
```

### Statistics Update

```sql
-- Analyze all tables
ANALYZE kernel.devices;
ANALYZE kernel.claims;
ANALYZE kernel.datoms;
-- ... etc
```

### Verification

```sql
-- Run immutability tests
SELECT * FROM test.verify_immutability();
```

## File Structure

```
database/
├── 01_schema_setup.sql           # Extensions, schemas, enums
├── 02_crypto_utilities.sql       # Hashing, signatures, Merkle
├── 03_base_entities.sql          # Common properties, utilities
├── 04_core_primitives_part1.sql  # Participants, Technicians, Devices, Parts
├── 04_core_primitives_part2.sql  # Repairs, Insurance, Claims, Sales
├── 04_core_primitives_part3.sql  # Event Store, Merkle Trees, Anchoring
├── 04_core_primitives_part4.sql  # Diagnostics, VCs, Audit, Permissions
├── 05_audit_immutability.sql     # Triggers, hash computation
├── 06_rls_policies.sql           # Row Level Security
├── 07_stored_procedures.sql      # Business logic functions
├── 08_indexes_constraints.sql    # Performance indexes, stats
├── 09_seed_data.sql              # Test data and verification
├── deploy.sql                    # Master deployment script
└── README.md                     # This documentation
```

## License

Enterprise License - InsureLedger Core Team

## Support

For issues and feature requests, contact the InsureLedger Core Team.
