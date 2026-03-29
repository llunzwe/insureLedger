# InsureLedger Kernel - Quick Reference Guide

## Table of Contents
1. [Common Queries](#common-queries)
2. [Function Reference](#function-reference)
3. [Error Codes](#error-codes)
4. [Best Practices](#best-practices)

---

## Common Queries

### Device Management

```sql
-- Get device with current owner
SELECT d.*, p.individual_name AS owner_name, p.business_name AS owner_business
FROM kernel.devices d
LEFT JOIN kernel.participants p ON d.current_owner_id = p.participant_id
WHERE d.device_id = 'uuid-here'::UUID;

-- Get device history (all versions)
SELECT * FROM kernel.devices
WHERE device_id = 'uuid-here'::UUID
ORDER BY system_from DESC;

-- Get currently active devices for an owner
SELECT * FROM kernel.devices
WHERE current_owner_id = 'owner-uuid'::UUID
  AND system_to IS NULL
  AND operational_status = 'active';

-- Search devices by model
SELECT * FROM kernel.devices
WHERE model_name ILIKE '%iPhone%'
  AND system_to IS NULL;
```

### Insurance Operations

```sql
-- Get active policies for a device
SELECT * FROM kernel.insurance_policies
WHERE device_id = 'device-uuid'::UUID
  AND status = 'active'
  AND system_to IS NULL;

-- Get claims for a policy
SELECT * FROM kernel.claims
WHERE policy_id = 'policy-uuid'::UUID
ORDER BY incident_date DESC;

-- Get total claims amount by insurer
SELECT 
    ip.insurer_id,
    COUNT(c.claim_id) AS claim_count,
    SUM(c.approved_amount) AS total_payouts
FROM kernel.insurance_policies ip
LEFT JOIN kernel.claims c ON ip.policy_id = c.policy_id
WHERE c.status = 'paid'
GROUP BY ip.insurer_id;
```

### Repair Operations

```sql
-- Get repair orders for a technician tenant
SELECT * FROM kernel.repair_orders
WHERE tenant_id = 'tenant-uuid'::UUID
  AND system_to IS NULL
ORDER BY created_at DESC;

-- Get parts used in repairs
SELECT 
    ro.repair_order_id,
    ro.fault_description,
    jsonb_array_elements(ro.parts_used)->>'part_id' AS part_id
FROM kernel.repair_orders ro
WHERE ro.system_to IS NULL;

-- Get repair completion rate by technician
SELECT 
    ro.tenant_id,
    COUNT(*) FILTER (WHERE status = 'completed') AS completed,
    COUNT(*) FILTER (WHERE status = 'cancelled') AS cancelled,
    COUNT(*) AS total,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE status = 'completed') / COUNT(*), 
        2
    ) AS completion_rate
FROM kernel.repair_orders ro
WHERE ro.system_to IS NULL
GROUP BY ro.tenant_id;
```

### Event Store (Datomic-style)

```sql
-- Get all facts about an entity
SELECT 
    d.attribute_name,
    d.value,
    d.operation,
    d.valid_from,
    d.valid_to,
    p.individual_name AS changed_by
FROM kernel.datoms d
LEFT JOIN kernel.participants p ON d.participant_id = p.participant_id
WHERE d.entity_id = 'entity-uuid'::UUID
ORDER BY d.datom_id;

-- Get current state of an entity
SELECT kernel.get_entity_state('entity-uuid'::UUID);

-- Get state at a specific point in time
SELECT kernel.get_entity_state(
    'entity-uuid'::UUID,
    '2024-01-15'::TIMESTAMP WITH TIME ZONE
);

-- Get all changes in a transaction
SELECT * FROM kernel.datoms
WHERE transaction_id = 'tx-uuid'::UUID;
```

### Audit & Compliance

```sql
-- Get audit trail for a specific record
SELECT * FROM audit.audit_logs
WHERE target_row_id = 'record-uuid'::UUID
ORDER BY event_timestamp DESC;

-- Get all actions by a participant
SELECT * FROM audit.audit_logs
WHERE participant_id = 'participant-uuid'::UUID
ORDER BY event_timestamp DESC
LIMIT 100;

-- Get failed operations
SELECT * FROM audit.audit_logs
WHERE success = FALSE
ORDER BY event_timestamp DESC;

-- Verify audit chain integrity
SELECT 
    audit_entry_id,
    CASE 
        WHEN previous_hash IS NULL THEN 'GENESIS'
        WHEN current_hash = crypto.chain_hash(previous_hash, to_jsonb(audit_logs))
        THEN 'VALID'
        ELSE 'INVALID'
    END AS chain_status
FROM audit.audit_logs
ORDER BY audit_entry_id;
```

---

## Function Reference

### Participant Management

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `kernel.register_participant` | type, business_name, individual_name, did, address, tax_hash, email_hash, phone_hash, roles, created_by | UUID | Register new participant |
| `kernel.register_technician_tenant` | business_name, business_type, address, regions, specialties, certifications, created_by | UUID | Register technician shop |

### Device Management

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `kernel.register_device` | type, manufacturer, model_name, model_number, serial, imei, mfg_date, owner_id, created_by | UUID | Register new device |
| `kernel.transfer_device_ownership` | device_id, new_owner_id, sales_tx_id | UUID | Transfer ownership (creates new version) |

### Insurance

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `kernel.create_insurance_policy` | device_id, insurer_id, holder_id, coverage_type, limit, deductible, premium, start_date, end_date, policy_number | UUID | Create policy |
| `kernel.calculate_dynamic_premium` | device_id, coverage_type, base_premium | DECIMAL | Calculate risk-adjusted premium |
| `kernel.file_claim` | policy_id, incident_date, type, description, location, attachments | UUID | File new claim |
| `kernel.assess_claim` | claim_id, adjuster_id, approved_amount, notes, is_repairable, repair_order_id | UUID | Assess and decide claim |

### Repair

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `kernel.create_repair_order` | tenant_id, device_id, customer_id, fault_desc, repair_types, labor_hours, scheduled_start | UUID | Create repair order |
| `kernel.complete_repair_order` | repair_order_id, parts_used, labor_hours, labor_cost, parts_cost, warranty_months | UUID | Complete repair |

### Event Store

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `kernel.assert_fact` | entity_id, entity_type, attribute, value, transaction_id | UUID | Add new fact |
| `kernel.retract_fact` | entity_id, attribute, valid_to | UUID | Mark fact as no longer valid |
| `kernel.get_entity_state` | entity_id, as_of | JSONB | Get entity state at time |

### Merkle & Anchoring

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `kernel.create_merkle_root` | start_timestamp, end_timestamp | UUID | Create Merkle root from pending transactions |
| `kernel.verify_merkle_inclusion` | target_id, target_type, root_id | BOOLEAN | Verify inclusion proof |

### Cryptography

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `crypto.sha256_hash` | input_data | TEXT | Compute SHA-256 hash |
| `crypto.hash_record` | data (JSONB) | TEXT | Hash JSON record |
| `crypto.chain_hash` | previous_hash, current_data | TEXT | Compute chain hash |
| `crypto.merkle_node_hash` | left_hash, right_hash | TEXT | Compute Merkle node hash |
| `crypto.generate_sign_payload` | entity_type, entity_id, version_data, timestamp | TEXT | Generate signature payload |

### Security Context

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `security.set_tenant_context` | tenant_id (UUID) | VOID | Set tenant for RLS |
| `security.get_tenant_context` | - | UUID | Get current tenant |
| `security.set_participant_context` | participant_id (UUID) | VOID | Set participant for RLS |
| `security.get_participant_context` | - | UUID | Get current participant |

---

## Error Codes

| Code | SQLState | Description | Resolution |
|------|----------|-------------|------------|
| Immutable Table | `insufficient_privilege` | Attempted UPDATE/DELETE on immutable table | Use versioning functions to create new records |
| Duplicate Key | `unique_violation` | Violation of unique constraint | Check for existing record or use versioning |
| Foreign Key | `foreign_key_violation` | Referenced record does not exist | Create referenced record first |
| Invalid Signature | `integrity_constraint_violation` | Digital signature verification failed | Check signature generation and keys |
| Temporal Violation | `check_violation` | Bitemporal constraint violated | Check valid/system time ranges |
| RLS Denied | `insufficient_privilege` | RLS policy denied access | Set correct tenant/participant context |

---

## Best Practices

### 1. Always Set Context Before Operations

```sql
-- Set context for technician operations
SELECT security.set_tenant_context('tenant-uuid'::UUID);
SELECT security.set_participant_context('technician-uuid'::UUID);

-- Now perform operations
SELECT kernel.create_repair_order(...);
```

### 2. Use Stored Procedures for Complex Operations

```sql
-- Good: Use stored procedure
SELECT kernel.transfer_device_ownership(device_id, new_owner_id);

-- Avoid: Direct UPDATE (will fail due to immutability)
UPDATE kernel.devices SET current_owner_id = ...;  -- ERROR!
```

### 3. Query Active Records Only

```sql
-- Always include system_to IS NULL for current state
SELECT * FROM kernel.devices
WHERE device_id = 'uuid'
  AND system_to IS NULL;  -- Current version only
```

### 4. Handle Time-Travel Queries

```sql
-- Query as of specific date
SELECT * FROM kernel.insurance_policies
WHERE device_id = 'uuid'
  AND system_from <= '2024-01-01'::TIMESTAMP WITH TIME ZONE
  AND (system_to IS NULL OR system_to > '2024-01-01'::TIMESTAMP WITH TIME ZONE);
```

### 5. Batch Operations in Transactions

```sql
BEGIN;

-- Set context
SELECT security.set_tenant_context('tenant-uuid'::UUID);

-- Create multiple related records
SELECT kernel.create_repair_order(...);
SELECT kernel.assert_fact(device_id, 'device', 'repair_status', '{"status": "in_progress"}');

COMMIT;
```

### 6. Monitor Performance

```sql
-- Check table sizes regularly
SELECT * FROM kernel.table_statistics;

-- Check index usage
SELECT * FROM kernel.index_statistics;

-- Archive old records
SELECT kernel.archive_old_records('audit_logs', 'audit', NOW() - INTERVAL '2 years');
```

### 7. Verify Data Integrity

```sql
-- Verify audit chain
SELECT * FROM test.verify_immutability();

-- Check for orphaned records
SELECT ro.repair_order_id
FROM kernel.repair_orders ro
LEFT JOIN kernel.devices d ON ro.device_id = d.device_id
WHERE d.device_id IS NULL;
```

---

## Data Types Reference

### Enums

```sql
-- Device types
kernel.device_type: desktop, laptop, tablet, smartphone, smartwatch, other

-- Participant types  
kernel.participant_type: customer, insurer, oem, ecommerce_platform, technician, regulator, certification_body

-- Repair order status
kernel.repair_order_status: draft, in_progress, awaiting_parts, completed, cancelled, disputed

-- Insurance policy status
kernel.policy_status: active, expired, cancelled, suspended, pending

-- Claim status
kernel.claim_status: filed, under_review, approved, denied, paid, closed

-- Incident types
kernel.incident_type: theft, accidental_damage, liquid_damage, fire_damage, natural_disaster, mechanical_failure, electrical_failure

-- Coverage types
kernel.coverage_type: comprehensive, screen_only, accidental_damage, theft, loss, extended_warranty
```

### Common JSONB Structures

```sql
-- Address
{
  "street": "123 Main St",
  "city": "New York",
  "state": "NY",
  "zip": "10001",
  "country": "USA"
}

-- Geolocation
{
  "lat": 40.7128,
  "lon": -74.0060,
  "accuracy": 10,
  "timestamp": "2024-01-15T10:30:00Z"
}

-- Parts used in repair
[
  {
    "part_id": "uuid",
    "part_number": "SCR-001",
    "quantity": 1,
    "unit_cost": 150.00,
    "total_cost": 150.00
  }
]

-- Test results (diagnostics)
{
  "battery_health": {
    "status": "passed",
    "value": 92,
    "threshold": 80,
    "unit": "percent"
  },
  "screen_touch": {
    "status": "failed",
    "value": "unresponsive",
    "error_code": "SCR-001"
  }
}
```
