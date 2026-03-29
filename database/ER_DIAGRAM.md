# InsureLedger Kernel - Entity Relationship Diagram
## Enterprise Edition with 24 Primitives

> **Version:** 2.0.0  
> **Last Updated:** 2024-03-28  
> **Standards:** ISO 17442, ISO 9362, ISO 4217, ISO 3166, ISO 20022, Basel III, GDPR, CASS

---

## Executive Summary

This document describes the complete entity-relationship model for the InsureLedger immutable ledger kernel. The system implements **24 primitives** covering identity, accounting, insurance, event sourcing, settlement, geography, and operations.

---

## Schema Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           SCHEMA ARCHITECTURE                                            │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│   │    kernel    │  │   security   │  │    audit     │  │    crypto    │  │ temporal  │ │
│   │  (Core Data) │  │  (Auth/RLS)  │  │ (Audit Log)  │  │  (Hashing)   │  │ (Bitemp)  │ │
│   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  └───────────┘ │
│                                                                                          │
│   Core Tables: 50+ entities across 24 primitives                                         │
│   Total Relationships: 200+ foreign key constraints                                      │
│   Indexes: 60+ (B-tree, GIN, GIST, Partial, BRIN)                                       │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 1-3: Identity & Core Entities

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           PARTICIPANT ECOSYSTEM                                          │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────┐                                                                │
│   │   TechnicianTenant  │◄──────────────────┐                                            │
│   │   (Shop/Workspace)  │                   │                                            │
│   └──────────┬──────────┘                   │                                            │
│              │ tenant_id                    │                                            │
│              │                              │                                            │
│              ▼                              │                                            │
│   ┌─────────────────────┐     ┌─────────────────────────────┐                           │
│   │    Participant      │     │   ParticipantIdentifier     │                           │
│   │  (Universal Entity) │◄────┤  (Hashed PII for GDPR)      │                           │
│   ├─────────────────────┤     ├─────────────────────────────┤                           │
│   │ • participant_id    │     │ • identifier_hash (SHA256)  │                           │
│   │ • participant_type  │     │ • identifier_type (email)   │                           │
│   │ • lei_code (ISO)    │     │ • encryption_key_id         │                           │
│   │ • bic_code (ISO)    │     └─────────────────────────────┘                           │
│   │ • kyc_status        │                                                                │
│   │ • risk_rating       │     ┌─────────────────────────────┐                           │
│   └──────────┬──────────┘     │      EntitySequences        │                           │
│              │                │   (Human-readable codes)    │                           │
│              │ subtype        ├─────────────────────────────┤                           │
│              │                │ • sequence_type             │                           │
│     ┌────────┼────────┐       │ • prefix / next_value       │                           │
│     │        │        │       │ • tenant-scoped             │                           │
│     ▼        ▼        ▼       └─────────────────────────────┘                           │
│  ┌──────┐ ┌──────┐ ┌──────┐                                                             │
│  │Cust- │ │Insur-│ │Techn-│     ┌─────────────────────────────┐                          │
│  │omer  │ │er    │ │ician │     │    SanctionsScreenings      │                          │
│  │OEM   │ │Regul-│ │      │     │   (FATF Compliance)         │                          │
│  │      │ │ator  │ │      │────►├─────────────────────────────┤                          │
│  └──────┘ └──────┘ └──────┘     │ • screening_result          │                          │
│                                 │ • sanction_list_source      │                          │
│   ┌─────────────────────────┐   │ • match_confidence          │                          │
│   │   AgentRelationships    │   │ • screened_at               │                          │
│   │   (Ownership Graph)     │   └─────────────────────────────┘                          │
│   ├─────────────────────────┤                                                            │
│   │ • from_agent → to_agent │   ┌─────────────────────────────┐                          │
│   │ • relationship_type     │   │     KycVerifications        │                          │
│   │ • percentage (ownership)│   │    (Identity Verification)  │                          │
│   │ • valid_from / valid_to │   ├─────────────────────────────┤                          │
│   │ • Circular detection    │   │ • verification_level        │                          │
│   └─────────────────────────┘   │ • verified_document_type    │                          │
│                                 │ • verification_provider     │                          │
│                                 └─────────────────────────────┘                          │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 2: Device & Product Registry

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           DEVICE ECOSYSTEM                                               │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────┐                                                                │
│   │      Device         │◄──────────────────────────────────────────────┐                │
│   │    (Digital Twin)   │                                               │                │
│   ├─────────────────────┤                                               │                │
│   │ • device_id (ULID)  │                                               │                │
│   │ • serial_number     │                                               │                │
│   │ • imei (unique)     │                                               │                │
│   │ • manufacturer      │                                               │                │
│   │ • model             │                                               │                │
│   │ • attributes (JSON) │                                               │                │
│   │ • current_owner_id  │                                               │                │
│   │ • ownership_history │                                               │                │
│   └──────────┬──────────┘                                               │                │
│              │                                                          │                │
│              │ 1:N relationships to:                                     │                │
│              │                                                          │                │
│     ┌────────┼────────┬──────────────┬──────────────┬──────────────┐   │                │
│     │        │        │              │              │              │   │                │
│     ▼        ▼        ▼              ▼              ▼              ▼   │                │
│  ┌──────┐ ┌──────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐│                │
│  │Device│ │Device│ │Insurance │ │   Claim  │ │  Repair  │ │  Sales   ││                │
│  │Diag- │ │Owner- │ │  Policy  │ │          │ │  Order   │ │  Order   ││                │
│  │nostic│ │shipHis│ │          │ │          │ │          │ │          ││                │
│  │Log   │ │tory   │ │          │ │          │ │          │ │          ││                │
│  └──────┘ └──────┘ └─────┬────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘│                │
│                          │           │            │            │      │                │
│                          │           │            │            │      │                │
│   ┌──────────────────────┴───────────┴────────────┴────────────┘      │                │
│   │                    ProductCatalog                                  │                │
│   │  ┌─────────────────────────────────────────────────────────┐      │                │
│   │  │ • product_id  • product_code  • category                │      │                │
│   │  │ • base_price  • currency_code • description             │      │                │
│   │  │ • coverage_details • terms (JSON)                       │      │                │
│   │  │ Categories: insurance, repair_service, spare_part       │      │                │
│   │  └─────────────────────────────────────────────────────────┘      │                │
│   └────────────────────────────────────────────────────────────────────┘                │
│                                                                                          │
│   ┌─────────────────────┐     ┌─────────────────────┐                                    │
│   │    SpareParts       │     │   DeviceDiagnostic  │                                    │
│   │   (Inventory)       │     │      (Testing)      │                                    │
│   ├─────────────────────┤     ├─────────────────────┤                                    │
│   │ • part_number       │     │ • battery_health    │                                    │
│   │ • compatibility     │     │ • screen_condition  │                                    │
│   │ • quantity_in_stock │     │ • water_damage_ind  │                                    │
│   │ • reorder_point     │     │ • sensor_tests      │                                    │
│   │ • supplier_id       │     │ • diagnostic_logs   │                                    │
│   └─────────────────────┘     └─────────────────────┘                                    │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 4-5,19: Accounting & Value Management

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    UNIVERSAL ACCOUNTING (Double-Entry)                                   │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────┐       │
│   │                        ValueContainer (Account)                              │       │
│   │  ┌───────────────────────────────────────────────────────────────────────┐  │       │
│   │  │ • container_id (ULID)      • container_code (LTREE)                  │  │       │
│   │  │ • container_type:          │ • currency_code                         │  │       │
│   │  │   - asset                  │ • owner_participant_id                  │  │       │
│   │  │   - liability              │ • parent_container_id (hierarchy)       │  │       │
│   │  │   - equity                 │ • path (LTREE for queries)              │  │       │
│   │  │   - income                 │ • is_universal_account                  │  │       │
│   │  │   - expense                │ • balance (calculated)                  │  │       │
│   │  │                            │ • status: open/frozen/closed            │  │       │
│   │  └───────────────────────────────────────────────────────────────────────┘  │       │
│   └─────────────────────────────────┬───────────────────────────────────────────┘       │
│                                     │                                                    │
│                                     │ 1:N                                                │
│                                     ▼                                                    │
│   ┌─────────────────────────────────────────────────────────────────────────────┐       │
│   │                        ValueMovement (Transaction)                           │       │
│   │  ┌───────────────────────────────────────────────────────────────────────┐  │       │
│   │  │ • movement_id (ULID)       • previous_hash / current_hash (chain)    │  │       │
│   │  │ • total_debits = total_credits  (conservation enforced)              │  │       │
│   │  │ • currency_code            • entry_date                              │  │       │
│   │  │ • value_date               • narrative                               │  │       │
│   │  │ • uetr (ISO 20022)         • end_to_end_id                           │  │       │
│   │  │ • status: draft/pending/posted/reversed                              │  │       │
│   │  │ • immutable_flag (TRUE)    • signature                               │  │       │
│   │  └───────────────────────────────────────────────────────────────────────┘  │       │
│   └─────────────────────────────────┬───────────────────────────────────────────┘       │
│                                     │                                                    │
│                                     │ 1:N (always 2+ legs)                               │
│                                     ▼                                                    │
│   ┌─────────────────────────────────────────────────────────────────────────────┐       │
│   │                          MovementLegs (Journal Lines)                        │       │
│   │  ┌───────────────────────────────────────────────────────────────────────┐  │       │
│   │  │ • leg_id (ULID)            • container_id (references ValueContainer)│  │       │
│   │  │ • movement_id              • direction: debit/credit                 │  │       │
│   │  │ • amount                   • previous_balance                        │  │       │
│   │  │ • running_balance          • description                             │  │       │
│   │  └───────────────────────────────────────────────────────────────────────┘  │       │
│   └─────────────────────────────────┬───────────────────────────────────────────┘       │
│                                     │                                                    │
│                                     │ 1:N (postings over time)                           │
│                                     ▼                                                    │
│   ┌─────────────────────────────────────────────────────────────────────────────┐       │
│   │                        MovementPostings (Hypertable)                         │       │
│   │  ┌───────────────────────────────────────────────────────────────────────┐  │       │
│   │  │ • posting_id               • leg_id                                  │  │       │
│   │  │ • posted_at (TIMESTAMPTZ)  • effective_date                          │  │       │
│   │  │ • posted_by                • posting_reference                       │  │       │
│   │  └───────────────────────────────────────────────────────────────────────┘  │       │
│   └─────────────────────────────────────────────────────────────────────────────┘       │
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                        CASS CLIENT MONEY SEGREGATION                             │   │
│   │                                                                                  │   │
│   │   ┌───────────────────┐         ┌───────────────────┐                            │   │
│   │   │  MasterAccount    │────────►│    SubAccount     │                            │   │
│   │   │  (Omnibus/Escrow) │  1:N    │  (Client Level)   │                            │   │
│   │   ├───────────────────┤         ├───────────────────┤                            │   │
│   │   │ • segregation_type│         │ • sub_account_code│                            │   │
│   │   │   - client_money  │         │ • virtual_iban    │                            │   │
│   │   │   - trust         │         │ • balance         │                            │   │
│   │   │   - escrow        │         │ • blocked_balance │                            │   │
│   │   │ • reg_framework   │         │ • status          │                            │   │
│   │   │ • master_physical │         │ • owner_part_id   │                            │   │
│   │   │ • total_subledger │         └───────────────────┘                            │   │
│   │   │ • reconciliation  │                                                        │   │
│   │   │   _gap (checked)  │         ┌───────────────────┐                            │   │
│   │   └───────────────────┘         │SubLedgerReconcil- │                            │   │
│   │                                 │  iation (Daily)   │                            │   │
│   │                                 │ • is_balanced     │                            │   │
│   │                                 │ • closing_gap     │                            │   │
│   │                                 └───────────────────┘                            │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 10-12: Insurance, Repair & Commerce

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    INSURANCE WORKFLOW (IFRS 17 Compliant)                                │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐                                                            │
│   │   ProductContract       │                                                            │
│   │      Template           │                                                            │
│   ├─────────────────────────┤                                                            │
│   │ • contract_template_id  │                                                            │
│   │ • contract_code         │                                                            │
│   │ • terms_json (immutable)│                                                            │
│   │ • pricing_rules (JSON)  │                                                            │
│   │ • base_premium_formula  │                                                            │
│   └───────────┬─────────────┘                                                            │
│               │ publish                                                                  │
│               ▼                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐                            │
│   │   ProductContractAnchor │     │     PricingRules        │                            │
│   │   (Immutable Instance)  │     │  (Dynamic Pricing)      │                            │
│   ├─────────────────────────┤     ├─────────────────────────┤                            │
│   │ • contract_hash (UUID)  │     │ • condition_type        │                            │
│   │ • terms_hash (SHA256)   │     │ • adjustment_type       │                            │
│   │ • anchored_at           │     │ • priority              │                            │
│   └───────────┬─────────────┘     └─────────────────────────┘                            │
│               │                                                                          │
│               │ used by                                                                  │
│               ▼                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │    InsurancePolicy      │◄────│      PriceQuote         │     │     Claim         │  │
│   │    (Contract Instance)  │     │    (Before Purchase)    │     │  (Indemnification)│  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • policy_number         │     │ • quote_reference       │     │ • claim_number    │  │
│   │ • policyholder_id       │     │ • base_premium          │     │ • incident_type   │  │
│   │ • insurer_id            │     │ • final_premium         │     │ • incident_date   │  │
│   │ • device_id             │     │ • valid_until           │     │ • status          │  │
│   │ • contract_hash         │     │ • factors_applied (JSON)│     │ • assessed_amount │  │
│   │ • coverage_type         │     └─────────────────────────┘     │ • approved_amount │  │
│   │ • coverage_limit        │                                     │ • actual_payout   │  │
│   │ • deductible            │     1:N policies generate         │ • payout_timestamp│  │
│   │ • premium_amount        │     N:1 claims per policy         │ • repair_order_id │  │
│   │ • effective_start/end   │◄──────────────────────────────────┤                   │  │
│   │ • claims_count          │                                     └─────────┬─────────┘  │
│   │ • claims_total          │                                               │            │
│   │ • risk_score            │                                               │ links to   │
│   │ • risk_factors (JSON)   │                                               ▼            │
│   │ • status (bitemporal)   │                                     ┌───────────────────┐  │
│   └─────────────────────────┘                                     │   RepairOrder     │  │
│                                                                   │  (if repairable)  │  │
│                                                                   ├───────────────────┤  │
│                                                                   │ • order_number    │  │
│                                                                   │ • status workflow │  │
│                                                                   │ • problem_desc    │  │
│                                                                   │ • estimated_cost  │  │
│                                                                   │ • final_cost      │  │
│                                                                   │ • warranty_days   │  │
│                                                                   └─────────┬─────────┘  │
│                                                                             │            │
│                                                                             │ 1:N        │
│                                                                             ▼            │
│                                                                   ┌───────────────────┐  │
│                                                                   │  DiagnosticReport │  │
│                                                                   │ • battery_health  │  │
│                                                                   │ • screen_condition│  │
│                                                                   │ • findings_summary│  │
│                                                                   └───────────────────┘  │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    E-COMMERCE & PAYMENTS (PCI DSS Compliant)                             │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │      SalesOrder         │◄────│    OrderLineItem        │     │     Payment       │  │
│   │    (Transaction)        │ 1:N ├─────────────────────────┤ 1:N ├───────────────────┤  │
│   ├─────────────────────────┤     │ • product_id            │     │ • amount          │  │
│   │ • order_number          │     │ • unit_price            │     │ • currency        │  │
│   │ • customer_id           │     │ • quantity              │     │ • payment_method  │  │
│   │ • subtotal_amount       │     │ • line_total            │     │ • masked_card     │  │
│   │ • tax_amount            │     │ • discount_amount       │     │ • gateway_ref     │  │
│   │ • total_amount          │     │ • coverage dates        │     │ • status          │  │
│   │ • payment_status        │     └─────────────────────────┘     │ • authorized_at   │  │
│   │ • fulfillment_status    │                                     │ • captured_at     │  │
│   │ • device_id (optional)  │                                     │ • refunded_amount │  │
│   │ • insurance_policy_id   │                                     └───────────────────┘  │
│   └─────────────────────────┘                                                            │
│                                                                                          │
│   ┌─────────────────────────┐                                                            │
│   │  CustomerPaymentMethod  │                                                            │
│   │   (Tokenized - PCI)     │                                                            │
│   ├─────────────────────────┤                                                            │
│   │ • payment_type          │                                                            │
│   │ • gateway_token         │                                                            │
│   │ • masked_identifier     │                                                            │
│   │ • card_brand            │                                                            │
│   │ • expiry_month/year     │                                                            │
│   │ • is_default            │                                                            │
│   └─────────────────────────┘                                                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 6-7: Event Store & Transaction Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    IMMUTABLE EVENT STORE (Datomic-style)                                 │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                              Datoms (EAVT)                                       │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • datom_id (ULID)                                                         │  │   │
│   │  │ • entity_id (UUID)      ───────┐                                          │  │   │
│   │  │ • attribute (TEXT)             │  Entity = entity_id + all datoms         │  │   │
│   │  │ • value (TEXT/JSON)            │  (not a separate table)                  │  │   │
│   │  │ • value_type (enum)            │                                          │  │   │
│   │  │ • value_hash (SHA256)          │                                          │  │   │
│   │  │ • operation (create/update/    │                                          │  │   │
│   │  │             delete/patch)      │                                          │  │   │
│   │  │ • transaction_time             │                                          │  │   │
│   │  │ • valid_time                   │                                          │  │   │
│   │  │ • previous_datom_hash          │                                          │  │   │
│   │  │ • current_hash (chain)         │                                          │  │   │
│   │  │ • participant_id               │                                          │  │   │
│   │  │ • sequence_number (BIGSERIAL)  │                                          │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────┬───────────────────────────────────────┘   │
│                                             │                                            │
│                                             │ grouped by                                 │
│                                             ▼                                            │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          DatomTransactions                                       │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • transaction_id         • datom_ids (array)                             │  │   │
│   │  │ • description            • datom_count                                    │  │   │
│   │  │ • transaction_hash       • status (pending/committed/aborted)            │  │   │
│   │  │ • started_at             • committed_at                                   │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────┬───────────────────────────────────────┘   │
│                                             │                                            │
│                                             │ aggregates into                            │
│                                             ▼                                            │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          EntitySnapshots (Materialized)                          │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • entity_id              • entity_type                                    │  │   │
│   │  │ • current_state (JSON)   • datom_ids (array of sources)                  │  │   │
│   │  │ • first_datom_id         • last_datom_id                                  │  │   │
│   │  │ • datom_count            • version                                        │  │   │
│   │  │ • first_seen_at          • last_modified_at                               │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          DatomMerkleNodes (Merkle Tree)                          │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • level (0=leaf)         • position in level                              │  │   │
│   │  │ • left_child_hash        • right_child_hash                               │  │   │
│   │  │ • node_hash              • datom_ids (leaves)                             │  │   │
│   │  │ • start_time / end_time  (temporal window)                                 │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    TRANSACTION LIFECYCLE (Saga Pattern)                                  │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          TransactionEntity                                       │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • transaction_id         • transaction_type (payment/transfer/claim)     │  │   │
│   │  │ • transaction_reference  • status (pending→validating→executing→         │  │   │
│   │  │ • initiator_id                    committed/failed/compensating)         │  │   │
│   │  │ • beneficiary_id         • amount / currency_code                        │  │   │
│   │  │ • initiated_at           • committed_at                                  │  │   │
│   │  │ • datom_transaction_id   • compensation_transaction_id                   │  │   │
│   │  │ • context (JSON)         • bitemporal fields                             │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────┬───────────────────────────────────────┘   │
│                                             │                                            │
│                                             │ 1:N operations                             │
│                                             ▼                                            │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          TransactionOperations (Steps)                           │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • operation_id           • sequence_number (order)                       │  │   │
│   │  │ • operation_type         • target_entity_type/id                         │  │   │
│   │  │ • operation_data (JSON)  • status (pending→executing→completed/failed)   │  │   │
│   │  │ • started_at             • completed_at                                  │  │   │
│   │  │ • compensation_op_id     • error_message                                 │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          SagaInstances (Long-running)                            │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • saga_id                • saga_type (claim_processing/policy_issuance)  │  │   │
│   │  │ • status (running/completed/failed/compensating)                         │  │   │
│   │  │ • current_step / total_steps                                             │  │   │
│   │  │ • context (JSON)         • result_data                                   │  │   │
│   │  │ • started_at             • completed_at                                  │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 8-9,16: Contracts, Authorization & Entitlements

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    AUTHORIZATION & ACCESS CONTROL                                        │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          Real-Time Authorization                                 │   │
│   │                                                                                  │   │
│   │   ┌───────────────────┐     ┌───────────────────┐     ┌───────────────────┐    │   │
│   │   │ AuthorizationReq  │     │     Session       │     │     APIKey        │    │   │
│   │   ├───────────────────┤     ├───────────────────┤     ├───────────────────┤    │   │
│   │   │ • subject_id      │     │ • session_token   │     │ • api_key_hash    │    │   │
│   │   │ • action          │     │ • participant_id  │     │ • api_key_prefix  │    │   │
│   │   │ • resource_type   │     │ • auth_method     │     │ • allowed_actions │    │   │
│   │   │ • resource_id     │     │ • auth_factors[]  │     │ • rate_limit      │    │   │
│   │   │ • decision        │     │ • expires_at      │     │ • last_used_at    │    │   │
│   │   │ • latency_ms      │     │ • last_activity   │     │                   │    │   │
│   │   └───────────────────┘     └───────────────────┘     └───────────────────┘    │   │
│   │                                                                                  │   │
│   │   ┌───────────────────┐     ┌───────────────────┐     ┌───────────────────┐    │   │
│   │   │  RateLimitBucket  │     │    AuthToken      │     │   MFADevice       │    │   │
│   │   ├───────────────────┤     ├───────────────────┤     ├───────────────────┤    │   │
│   │   │ • bucket_key      │     │ • token_jti       │     │ • mfa_type        │    │   │
│   │   │ • max_requests    │     │ • scopes[]        │     │ • totp_secret_enc │    │   │
│   │   │ • current_count   │     │ • is_revoked      │     │ • credential_id   │    │   │
│   │   │ • window_start    │     │ • expires_at      │     │ • is_verified     │    │   │
│   │   └───────────────────┘     └───────────────────┘     └───────────────────┘    │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          Entitlements (RBAC/ABAC)                                │   │
│   │                                                                                  │   │
│   │   ┌───────────────────┐     ┌───────────────────┐     ┌───────────────────┐    │   │
│   │   │      Role         │◄────┤   RolePermission  │────►│   Permission      │    │   │
│   │   ├───────────────────┤ N:M ├───────────────────┤ N:M ├───────────────────┤    │   │
│   │   │ • role_code       │     │ • tenant_id       │     │ • permission_code │    │   │
│   │   │ • scope           │     │ • constraints     │     │ • resource_type   │    │   │
│   │   │ • permissions[]   │     │                   │     │ • action          │    │   │
│   │   │ • parent_role_id  │     │                   │     │ • conditions      │    │   │
│   │   └─────────┬─────────┘     └───────────────────┘     └───────────────────┘    │   │
│   │             │                                                                      │   │
│   │             │ N:M                                                                  │   │
│   │             ▼                                                                      │   │
│   │   ┌───────────────────┐                                                            │   │
│   │   │     UserRole      │                                                            │   │
│   │   ├───────────────────┤                                                            │   │
│   │   │ • user_id         │                                                            │   │
│   │   │ • role_id         │                                                            │   │
│   │   │ • tenant_id       │                                                            │   │
│   │   │ • valid_from/to   │                                                            │   │
│   │   │ • granted_by      │                                                            │   │
│   │   └───────────────────┘                                                            │   │
│   │                                                                                  │   │
│   │   ┌───────────────────┐     ┌───────────────────┐                                │   │
│   │   │   AccessPolicy    │     │ EntitlementGrant  │                                │   │
│   │   ├───────────────────┤     ├───────────────────┤                                │   │
│   │   │ • policy_name     │     │ • grantee_type    │                                │   │
│   │   │ • effect (allow/  │     │ • entitlement_type│                                │   │
│   │   │   deny)           │     │ • scope_type      │                                │   │
│   │   │ • subject_attrs   │     │ • constraints     │                                │   │
│   │   │ • actions[]       │     │ • valid_from/to   │                                │   │
│   │   │ • resource_attrs  │     │                   │                                │   │
│   │   │ • env_conditions  │     │                   │                                │   │
│   │   │ • priority        │     │                   │                                │   │
│   │   └───────────────────┘     └───────────────────┘                                │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 13-15: Settlement, Reconciliation & Control

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    SETTLEMENT & CLEARING (ISO 20022)                                     │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                          SettlementInstruction                                   │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • instruction_id         • instruction_reference                          │  │   │
│   │  │ • movement_id (link)     • payer_container_id                             │  │   │
│   │  │ • payee_container_id     • amount / currency_code                         │  │   │
│   │  │ • method (RTGS/net/DVP)  • priority                                       │  │   │
│   │  │ • requested_settle_date  • actual_settle_timestamp                        │  │   │
│   │  │ • status (pending→settled) • clearing_system (TARGET2/CHIPS)              │  │   │
│   │  │ • uetr (ISO 20022)       • end_to_end_id                                  │  │   │
│   │  │ • correspondent banks    • bitemporal fields                              │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────┬───────────────────────────────────────┘   │
│                                             │                                            │
│                              ┌──────────────┴──────────────┐                            │
│                              │                             │                            │
│                              ▼                             ▼                            │
│   ┌─────────────────────────────────┐   ┌─────────────────────────────────┐              │
│   │      ClearingBatch              │   │      NettingPosition            │              │
│   │   (Net Settlement)              │   │   (Inter-Participant)           │              │
│   ├─────────────────────────────────┤   ├─────────────────────────────────┤              │
│   │ • batch_reference               │   │ • participant_a_id              │              │
│   │ • clearing_system               │   │ • participant_b_id              │              │
│   │ • settlement_date               │   │ • amount_a_owed                 │              │
│   │ • instruction_count             │   │ • amount_b_owed                 │              │
│   │ • total_debit/credit            │   │ • net_position                  │              │
│   │ • net_position                  │   │ • net_debtor_id                 │              │
│   │ • status (open→settled)         │   │ • settlement_instruction_id     │              │
│   └─────────────────────────────────┘   └─────────────────────────────────┘              │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    RECONCILIATION & MATCHING                                             │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐                                                            │
│   │   ReconciliationRun     │                                                            │
│   ├─────────────────────────┤                                                            │
│   │ • recon_id              │                                                            │
│   │ • recon_type (bank/     │                                                            │
│   │   internal/nostro)      │                                                            │
│   │ • container_id          │                                                            │
│   │ • period_start/end      │                                                            │
│   │ • status                │                                                            │
│   │ • internal/external     │                                                            │
│   │   totals                │                                                            │
│   │ • matched/unmatched     │                                                            │
│   │   counts                │                                                            │
│   └───────────┬─────────────┘                                                            │
│               │                                                                          │
│       ┌───────┴───────┐                                                                  │
│       │               │                                                                  │
│       ▼               ▼                                                                  │
│  ┌──────────┐   ┌──────────┐     ┌──────────┐                                           │
│  │ ReconInt │   │ ReconExt │────►│   Break  │                                           │
│  │ ernalItem│   │ ernalItem│     │  (Gap)   │                                           │
│  ├──────────┤   ├──────────┤     ├──────────┤                                           │
│  │•movement_│   │•external_│     │•break_type│                                           │
│  │   id     │   │   ref    │     │•difference│                                           │
│  │•amount   │   │•raw_data │     │•resolution│                                           │
│  │•matched_ │   │•matched_ │     │•status    │                                           │
│  │   to_ext │   │   to_int │     └──────────┘                                           │
│  └──────────┘   └──────────┘                                                             │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐                            │
│   │    NostroAccount        │     │    MatchingRule         │                            │
│   ├─────────────────────────┤     ├─────────────────────────┤                            │
│   │ • owner_participant_id  │     │ • match_fields[]        │                            │
│   │ • correspondent_bank_id │     │ • tolerance_amount      │                            │
│   │ • ledger_balance        │     │ • tolerance_days        │                            │
│   │ • statement_balance     │     │ • match_threshold       │                            │
│   │ • reconciliation_gap    │     │ • is_active             │                            │
│   └─────────────────────────┘     └─────────────────────────┘                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    CONTROL & BATCH PROCESSING                                            │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │        Control          │     │    ControlExecution     │     │  ControlFinding   │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • control_code          │────►│ • control_id            │────►│ • execution_id    │  │
│   │ • control_type          │ 1:N │ • execution_type        │ 1:N │ • severity        │  │
│   │   (preventive/          │     │ • result                │     │ • category        │  │
│   │    detective)           │     │ • result_details        │     │ • remediation_    │  │
│   │ • frequency             │     │ • findings_count        │     │   owner           │  │
│   │ • automation_level      │     │ • reviewed_by           │     │ • due_date        │  │
│   │ • owner_id              │     └─────────────────────────┘     └───────────────────┘  │
│   └─────────────────────────┘                                                            │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │       BatchJob          │     │       BatchRun          │     │   BatchRunItem    │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • job_name              │────►│ • job_id                │────►│ • run_id          │  │
│   │ • job_type              │ 1:N │ • status                │ 1:N │ • item_type       │  │
│   │ • schedule_type         │     │ • total/processed/      │     │ • status          │  │
│   │ • cron_expression       │     │   failed_items          │     │ • result_data     │  │
│   │ • next_run_at           │     │ • progress_percent      │     │ • error_message   │  │
│   │ • is_active             │     │ • output_location       │     └───────────────────┘  │
│   └─────────────────────────┘     └─────────────────────────┘                            │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │      EODProcess         │     │        EODStep          │     │ EODBalanceSnapshot│  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • business_date         │────►│ • eod_id                │     │ • eod_id          │  │
│   │ • scope                 │ 1:N │ • step_name             │     │ • container_id    │  │
│   │ • status (pending→      │     │ • step_number           │     │ • opening_balance │  │
│   │   completed)            │     │ • status                │     │ • closing_balance │  │
│   │ • steps_total/          │     │ • records_processed     │     │ • total_credits   │  │
│   │   completed/failed      │     │ • result_summary        │     │ • total_debits    │  │
│   │ • validation_passed     │     │ • error_message         │     │ • is_balanced     │  │
│   └─────────────────────────┘     └─────────────────────────┘     └───────────────────┘  │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐                            │
│   │     BusinessCalendar    │     │      CutoffTime         │                            │
│   ├─────────────────────────┤     ├─────────────────────────┤                            │
│   │ • calendar_date         │     │ • process_type          │                            │
│   │ • is_business_day       │     │ • currency_code         │                            │
│   │ • day_type              │     │ • cutoff_time           │                            │
│   │ • next_business_day     │     │ • effective_days[]      │                            │
│   │ • previous_business_day │     │ • jurisdiction_code     │                            │
│   └─────────────────────────┘     └─────────────────────────┘                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 17-18: Geography & Documents

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    JURISDICTIONS & REGULATORY                                            │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │      Jurisdiction       │────►│    RegulatoryBody       │────►│ RegulatoryRequire-│  │
│   ├─────────────────────────┤ 1:N ├─────────────────────────┤ 1:N │      ment         │  │
│   │ • jurisdiction_code     │     │ • body_code             │     ├───────────────────┤  │
│   │   (ISO 3166-1)          │     │ • body_type             │     │ • requirement_type│  │
│   │ • subdivision_code      │     │   (central_bank/        │     │   (reporting/KYC/ │  │
│   │   (ISO 3166-2)          │     │    regulator)           │     │    capital)       │  │
│   │ • fatf_risk_rating      │     │ • regulatory_scope[]    │     │ • frequency       │  │
│   │ • eu_high_risk_third    │     │ • jurisdiction_id       │     │ • jurisdiction_id │  │
│   │ • ofac_sanctioned       │     │ • website/address       │     │ • threshold       │  │
│   │ • regulatory_framework[]│     └─────────────────────────┘     │   requirements    │  │
│   │ • currency_codes[]      │                                      │ • penalty_desc    │  │
│   │ • timezone              │                                      └───────────────────┘  │
│   └─────────────────────────┘                                                           │
│            │                                                                             │
│            │ referenced by                                                              │
│            ▼                                                                             │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │  ComplianceRegistration │     │    ComplianceReport     │     │   TaxInformation  │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • participant_id        │     │ • requirement_id        │     │ • participant_id  │  │
│   │ • jurisdiction_id       │     │ • participant_id        │     │ • jurisdiction_id │  │
│   │ • registration_type     │     │ • reporting_period      │     │ • tax_id_type     │  │
│   │ • registration_number   │     │ • status                │     │ • tax_id_number   │  │
│   │ • regulatory_body_id    │     │ • report_data (JSON)    │     │ • withholding_rate│  │
│   │ • effective_date        │     │ • submission_reference  │     │ • fatca_status    │  │
│   │ • expiration_date       │     │ • regulatory_response   │     │ • crs_classification││
│   │ • conditions[]          │     └─────────────────────────┘     └───────────────────┘  │
│   └─────────────────────────┘                                                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    DOCUMENTS & EVIDENCE (GDPR/eIDAS)                                     │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                              Document (WORM)                                     │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • document_id (ULID)     • previous_hash / current_hash (immutability)   │  │   │
│   │  │ • document_number        • document_type (contract/policy/KYC/evidence)  │  │   │
│   │  │ • title / description    • classification (public/internal/confidential) │  │   │
│   │  │ • file_name / mime_type  • file_size_bytes                               │  │   │
│   │  │ • storage_provider       • storage_path / storage_url                    │  │   │
│   │  │ • content_hash (SHA256)  • encryption_key_id                             │  │   │
│   │  │ • version                • is_latest_version                             │  │   │
│   │  │ • linked_entity_type/id  • retention_period_days                         │  │   │
│   │  │ • retain_until_date      • legal_hold (blocks deletion)                  │  │   │
│   │  │ • bitemporal fields      • signature / proof_inclusion                   │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────┬───────────────────────────────────────┘   │
│                                             │                                            │
│                              ┌──────────────┴──────────────┐                            │
│                              │                             │                            │
│                              ▼                             ▼                            │
│   ┌─────────────────────────────────┐   ┌─────────────────────────────────┐              │
│   │      DocumentVersion            │   │      DocumentSignature          │              │
│   ├─────────────────────────────────┤   ├─────────────────────────────────┤              │
│   │ • document_id                   │   │ • document_id                   │              │
│   │ • version_number                │   │ • signer_id                     │              │
│   │ • content_hash                  │   │ • signature_type                │              │
│   │ • change_description            │   │   (digital/electronic/          │              │
│   │ • approved_by                   │   │    biometric)                   │              │
│   └─────────────────────────────────┘   │ • signature_value               │              │
│                                         │ • signature_level (SES/AdES/    │              │
│                                         │   QES per eIDAS)                │              │
│                                         │ • certificate_serial            │              │
│                                         │ • signed_at / signed_ip         │              │
│                                         └─────────────────────────────────┘              │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │        Evidence         │     │   DocumentAccessLog     │     │ RetentionPolicy   │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • evidence_type         │     │ • document_id           │     │ • document_types[]│  │
│   │   (photo/video/audio/   │     │ • access_type           │     │ • retention_years │  │
│   │    document/data)       │     │   (view/download/edit)  │     │ • post_retention  │  │
│   │ • source_type           │     │ • accessed_by           │     │   _action         │  │
│   │ • captured_location     │     │ • access_timestamp      │     │ • gdpr_category   │  │
│   │ • custody_chain (JSON)  │     │ • client_ip             │     │ • is_active       │  │
│   │ • verification_status   │     │ • data_volume_bytes     │     └───────────────────┘  │
│   │ • case_type / case_id   │     │   (GDPR tracking)       │                            │
│   └─────────────────────────┘     └─────────────────────────┘                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 20: Capital & Liquidity (Basel III)

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    CAPITAL ADEQUACY (Basel III/CRD IV)                                   │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │     CapitalPosition     │     │   RiskWeightedAssets    │     │   CapitalRatio    │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • entity_id             │     │ • entity_id             │     │ • entity_id       │  │
│   │ • reporting_date        │     │ • reporting_date        │     │ • reporting_date  │  │
│   │ • capital_tier          │     │ • risk_category         │     │ • tier_1_capital  │  │
│   │   (tier_1_core/         │     │   (credit/market/       │     │ • tier_1_core_cap │  │
│   │    tier_1_add/          │     │    operational)         │     │ • total_capital   │  │
│   │    tier_2/tier_3)       │     │ • asset_class           │     │ • total_rwa       │  │
│   │ • capital_component     │     │ • exposure_amount       │     │ • cet1_ratio      │  │
│   │ • gross_amount          │     │ • risk_weight           │     │ • tier_1_ratio    │  │
│   │ • regulatory_adjustments│     │ • risk_weighted_assets  │     │ • total_cap_ratio │  │
│   │ • net_amount            │     │   (calculated)          │     │ • is_compliant    │  │
│   └─────────────────────────┘     └─────────────────────────┘     │ • surplus_deficit │  │
│                                                                   └───────────────────┘  │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │    LCRCalculation       │     │    NSFRCalculation      │     │ LeverageRatioCalc │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • total_hqla            │     │ • total_asf             │     │ • tier_1_capital  │  │
│   │   (high quality         │     │   (available stable     │     │ • total_exposure  │  │
│   │    liquid assets)       │     │    funding)             │     │ • leverage_ratio  │  │
│   │ • net_cash_outflows     │     │ • total_rsf             │     │ • is_compliant    │  │
│   │ • lcr_ratio (>=100%)    │     │   (required stable      │     │   (>=3%)          │  │
│   │ • is_compliant          │     │    funding)             │     └───────────────────┘  │
│   └─────────────────────────┘     │ • nsfr_ratio (>=100%)   │                            │
│                                   │ • is_compliant          │                            │
│                                   └─────────────────────────┘                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Primitive 21-24: Streaming, Caching, Archival & Health

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    STREAMING & EVENT ARCHITECTURE                                        │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │      EventStream        │     │      EventProducer      │     │   EventConsumer   │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • stream_name           │◄────│ • stream_id             │     │ • consumer_group  │  │
│   │ • stream_type           │     │ • producer_type         │     │ • stream_id       │  │
│   │   (kafka/kinesis/       │     │   (app/connector/       │     │ • consumer_type   │  │
│   │    pubsub)              │     │    trigger)             │     │ • current_offset  │  │
│   │ • topic_pattern         │     │ • source_table          │     │ • lag_seconds     │  │
│   │ • partition_count       │     │ • transformation_logic  │     │ • status          │  │
│   │ • delivery_guarantee    │     │ • max_events_per_sec    │     └───────────────────┘  │
│   │ • retention_hours       │     └─────────────────────────┘                            │
│   └───────────┬─────────────┘                                                            │
│               │                                                                          │
│               │ publishes to                                                             │
│               ▼                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                              EventLog (Materialized)                             │   │
│   │  ┌───────────────────────────────────────────────────────────────────────────┐  │   │
│   │  │ • event_id               • stream_name / partition / offset               │  │   │
│   │  │ • event_type             • event_version                                  │  │   │
│   │  │ • payload (JSON)         • entity_type / entity_id                        │  │   │
│   │  │ • event_time             • correlation_id / causation_id                  │  │   │
│   │  │ • partition_key          • producer_id                                    │  │   │
│   │  └───────────────────────────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │        Mutation         │     │    CDCConfiguration     │     │ MaterializedView  │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • source_table          │     │ • source_table          │     │ • view_name       │  │
│   │ • mutation_type         │     │ • capture_inserts/      │     │ • last_refresh_at │  │
│   │   (insert/update/       │     │   updates/deletes       │     │ • is_fresh        │  │
│   │    delete)              │     │ • row_filter            │     │ • row_count       │  │
│   │ • old_data / new_data   │     │ • target_stream_id      │     │ • refresh_in_prog │  │
│   │ • changed_fields[]      │     └─────────────────────────┘     └───────────────────┘  │
│   │ • processed (boolean)   │                                                            │
│   │ • retry_count           │                                                            │
│   └─────────────────────────┘                                                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    PEER CACHING & REPLICATION                                            │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │         Node            │     │   ReplicationSlot       │     │   CacheRegion     │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • node_name             │────►│ • node_id               │     │ • region_name     │  │
│   │ • node_type             │ 1:N │ • slot_name             │     │ • entity_type     │  │
│   │   (primary/replica/     │     │ • plugin                │     │ • cache_strategy  │  │
│   │    edge/witness)        │     │ • confirmed_lsn         │     │   (LRU/LFU/FIFO)  │  │
│   │ • data_center           │     │ • restart_lsn           │     │ • max_size        │  │
│   │ • replication_lag_sec   │     │ • lag_bytes             │     │ • ttl_seconds     │  │
│   │ • storage_capacity/used │     └─────────────────────────┘     │ • node_ids[]      │  │
│   │ • status                │                                      └─────────┬─────────┘  │
│   └─────────────────────────┘                                                │            │
│                                                                              │ 1:N        │
│   ┌─────────────────────────┐     ┌─────────────────────────┐                ▼            │
│   │      ConflictLog        │     │       SyncQueue         │     ┌───────────────────┐   │
│   ├─────────────────────────┤     ├─────────────────────────┤     │    CacheEntry     │   │
│   │ • entity_type/id        │     │ • source/target_node_id │     ├───────────────────┤   │
│   │ • local/remote_version  │     │ • entity_type/id        │     │ • cache_key       │   │
│   │ • local/remote_node_id  │     │ • operation             │     │ • region_id       │   │
│   │ • resolution_strategy   │     │ • payload               │     │ • cached_data     │   │
│   │ • resolved_version      │     │ • status                │     │ • version         │   │
│   └─────────────────────────┘     │ • retry_count           │     │ • expires_at      │   │
│                                   └─────────────────────────┘     │ • is_stale        │   │
│                                                                   └───────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    ARCHIVAL & DATA LIFECYCLE (GDPR)                                      │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │    ArchivalPolicy       │     │      ArchiveJob         │     │  ArchiveManifest  │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • source_table          │────►│ • policy_id             │────►│ • job_id          │  │
│   │ • archive_after_days    │ 1:N │ • source_table          │ 1:N │ • source_record_id│  │
│   │ • delete_after_days     │     │ • target_tier           │     │ • archive_tier    │  │
│   │ • tier_progression[]    │     │   (hot/warm/cold/       │     │   (cold/glacier)  │  │
│   │   (hot→warm→cold→       │     │    glacier/tape)        │     │ • archive_location│  │
│   │    glacier)             │     │ • status                │     │ • content_hash    │  │
│   │ • worm_required         │     │ • total/processed/      │     │ • record_summary  │  │
│   │ • gdpr_category         │     │   archived_records      │     │   (for search)    │  │
│   │ • is_active             │     │ • checksum              │     │ • legal_hold      │  │
│   └─────────────────────────┘     └─────────────────────────┘     └───────────────────┘  │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │       LegalHold         │     │      GDPRRequest        │     │   DataTierState   │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • hold_reference        │     │ • request_reference     │     │ • source_table    │  │
│   │ • hold_reason           │     │ • request_type          │     │ • source_record_id│  │
│   │   (litigation/          │     │   (access/erasure/      │     │ • current_tier    │  │
│   │    investigation)       │     │    rectification)       │     │ • tier_history    │  │
│   │ • scope_type/criteria   │     │ • scope_participant_id  │     │ • last_tier_change│  │
│   │ • is_active             │     │ • status                │     │ • access_count    │  │
│   │ • issued_by/issued_at   │     │ • deadline_date         │     └───────────────────┘  │
│   │ • case_number/matter_id │     │ • legal_hold_blocks     │                            │
│   └─────────────────────────┘     └─────────────────────────┘                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    OBSERVABILITY & HEALTH (SRE)                                          │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │      HealthCheck        │     │   HealthCheckResult     │     │        SLO        │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • check_name            │────►│ • check_id              │     ├───────────────────┤  │
│   │ • check_type            │ 1:N │ • status                │     │ • slo_name        │  │
│   │   (db/api/cache/disk)   │     │   (healthy/degraded/    │     │ • sli_metric      │  │
│   │ • target_system         │     │    unhealthy)           │     │ • target_%        │  │
│   │ • check_query           │     │ • response_time_ms      │     │ • window_days     │  │
│   │ • warning_threshold     │     │ • result_value          │     │ • is_active       │  │
│   │ • critical_threshold    │     │ • result_message        │     └─────────┬─────────┘  │
│   │ • interval_seconds      │     └─────────────────────────┘               │            │
│   └─────────────────────────┘                                              │ 1:N        │
│                                                                            ▼            │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────┐  │
│   │        Alert            │     │       Incident          │     │  SLMeasurement    │  │
│   ├─────────────────────────┤     ├─────────────────────────┤     ├───────────────────┤  │
│   │ • alert_name            │────►│ • incident_number       │     │ • measurement_date│  │
│   │ • severity              │     │ • title                 │     │ • sli_value       │  │
│   │   (critical/high/       │     │ • severity (sev1-sev5)  │     │ • target_value    │  │
│   │    medium/low)          │     │ • status                │     │ • is_compliant    │  │
│   │ • status                │     │ • commander/responders  │     │ • error_budget_%  │  │
│   │   (firing/ack/resolved) │     │ • time_to_detect_min    │     │ • burn_rate       │  │
│   │ • summary/description   │     │ • time_to_resolve_min   │     │ • days_to_exhaust │  │
│   │ • runbook_url           │     │ • root_cause            │     └───────────────────┘  │
│   │ • fired_at/resolved_at  │     │ • post_mortem_url       │                            │
│   └─────────────────────────┘     └─────────────────────────┘                            │
│                                                                                          │
│   ┌─────────────────────────┐     ┌─────────────────────────┐                            │
│   │        Metric           │     │    AlertNotification    │                            │
│   ├─────────────────────────┤     ├─────────────────────────┤                            │
│   │ • metric_name           │     │ • alert_id              │                            │
│   │ • metric_type           │     │ • channel_type          │                            │
│   │   (counter/gauge/       │     │   (email/slack/pagerduty│                            │
│   │    histogram/summary)   │     │ • channel_target        │                            │
│   │ • service_name          │     │ • status (sent/failed)  │                            │
│   │ • labels (JSON)         │     │ • sent_at/delivered_at  │                            │
│   │ • metric_value          │     │ • retry_count           │                            │
│   │ • metric_timestamp      │     └─────────────────────────┘                            │
│   └─────────────────────────┘                                                            │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Security Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    ROW LEVEL SECURITY (RLS) FLOW                                         │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   ┌─────────────────┐                                                                    │
│   │  Application    │                                                                    │
│   │  (API/Client)   │                                                                    │
│   └────────┬────────┘                                                                    │
│            │ 1. SET security.set_tenant_session(tenant_id)                              │
│            │ 2. SET security.set_participant_session(participant_id)                    │
│            ▼                                                                            │
│   ┌─────────────────────────────────────────────────────────────────────────┐          │
│   │                    PostgreSQL Session Context                            │          │
│   │  • app.current_tenant_id = 'tenant-uuid'                                 │          │
│   │  • app.current_participant_id = 'user-uuid'                              │          │
│   └─────────────────────────────────┬───────────────────────────────────────┘          │
│                                     │                                                    │
│                                     │ All queries filtered by                            │
│                                     ▼                                                    │
│   ┌─────────────────────────────────────────────────────────────────────────┐          │
│   │                    RLS Policy (Example: InsurancePolicy)                 │          │
│   │                                                                          │          │
│   │  USING (                                                                 │          │
│   │      tenant_id = security.get_tenant_context()::UUID                   │          │
│   │      OR insurer_id = security.get_participant_context()                │          │
│   │      OR policyholder_id = security.get_participant_context()           │          │
│   │      OR EXISTS (SELECT 1 FROM kernel.roles r                            │          │
│   │                  JOIN kernel.user_roles ur ON r.role_id = ur.role_id    │          │
│   │                  WHERE ur.user_id = security.get_participant_context()   │          │
│   │                  AND r.role_code = 'super_admin')                        │          │
│   │  )                                                                       │          │
│   └─────────────────────────────────────────────────────────────────────────┘          │
│                                                                                          │
│   Result: Users only see data they are authorized to see                                │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Bitemporal & Immutable Model

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    BITEMPORAL TIME TRACKING                                              │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   System Time (Audit Timeline)    Valid Time (Business Timeline)                         │
│   ────────────────────────────    ─────────────────────────────                          │
│                                                                                          │
│   • When record was stored        • When fact was true in business reality              │
│   • Immutable after insert        • Can be future-dated                                  │
│   • Used for forensics            • Supports corrections                                 │
│                                                                                          │
│   Example: Insurance Policy Coverage Period                                              │
│   ═══════════════════════════════════════════════════════════                           │
│                                                                                          │
│   System Timeline (audit):                                                               │
│   ─────────────────────────────────────────────────────────►                             │
│                                                                                          │
│   ┌─────────────────────────────────────────────────────────────────────────┐           │
│   │ Record 1: system_from=Jan 1, system_to=Jan 15                          │           │
│   │           valid_from=Jan 1, valid_to=Dec 31 (original policy)          │           │
│   └─────────────────────────────────────────────────────────────────────────┘           │
│                              │                                                           │
│   ┌──────────────────────────┴─────────────────────────────────────────────┐           │
│   │ Record 2: system_from=Jan 15, system_to=null (current)                 │           │
│   │           valid_from=Jan 15, valid_to=Jun 30 (early termination)       │           │
│   │           This is a correction - policy actually ended Jun 30          │           │
│   └─────────────────────────────────────────────────────────────────────────┘           │
│                                                                                          │
│   Query: "Was policy active on March 1?"                                                │
│   • System view (as of now): Check Record 2 (current system record)                     │
│   • Valid time: valid_from <= March 1 < valid_to → YES (until Jun 30)                   │
│                                                                                          │
│   Query: "What did we think on Feb 1?"                                                  │
│   • System time: system_from <= Feb 1 < system_to → Record 1                            │
│   • Answer: Policy valid until Dec 31 (our knowledge at that time)                      │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    IMMUTABLE HASH CHAIN                                                  │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   Genesis: SHA256("entity_type:entity_id:genesis") = H₀                                 │
│                              │                                                           │
│                              ▼                                                           │
│   ┌─────────────────────────────────────────────────────────────────────────┐           │
│   │ Record 1 (Insert)                                                        │           │
│   │ Data: {status: "active", value: 100}                                     │           │
│   │ previous_hash = H₀                                                       │           │
│   │ current_hash = SHA256(H₀ + JSON(Data)) = H₁                             │           │
│   └─────────────────────────────────────────────────────────────────────────┘           │
│                              │                                                           │
│                              ▼                                                           │
│   ┌─────────────────────────────────────────────────────────────────────────┐           │
│   │ Record 2 (Update = New Insert)                                           │           │
│   │ Data: {status: "active", value: 150}                                     │           │
│   │ previous_hash = H₁                                                       │           │
│   │ current_hash = SHA256(H₁ + JSON(Data)) = H₂                             │           │
│   │ (Record 1 still exists with system_to set)                               │           │
│   └─────────────────────────────────────────────────────────────────────────┘           │
│                              │                                                           │
│                              ▼                                                           │
│   ┌─────────────────────────────────────────────────────────────────────────┐           │
│   │ Record 3 (Delete = New Insert with flag)                                 │           │
│   │ Data: {status: "deleted", value: null}                                   │           │
│   │ previous_hash = H₂                                                       │           │
│   │ current_hash = SHA256(H₂ + JSON(Data)) = H₃                             │           │
│   └─────────────────────────────────────────────────────────────────────────┘           │
│                                                                                          │
│   Verification: Any break in chain indicates tampering                                  │
│                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Entity Cardinality Reference

| Relationship | Cardinality | Description |
|-------------|-------------|-------------|
| **Identity & Access** |||
| Participant → TechnicianTenant | 1:1 | Tenant specialization |
| Participant → AgentRelationship | 1:N | Ownership/control relationships |
| Participant → UserRole | 1:N | Role assignments |
| Role → RolePermission | N:M | Permission grants |
| Permission → RolePermission | 1:N | Role assignments |
| **Device & Product** |||
| Participant → Device | 1:N | Device ownership |
| Device → InsurancePolicy | 1:N | Coverage over time |
| Device → RepairOrder | 1:N | Service history |
| Device → DiagnosticReport | 1:N | Test history |
| Device → Claim | 1:N | Claim history |
| **Insurance Domain** |||
| Participant → InsurancePolicy | 1:N | As insurer |
| Participant → InsurancePolicy | 1:N | As policyholder |
| InsurancePolicy → Claim | 1:N | Policy claims |
| Claim → RepairOrder | 1:1 | Linked repair |
| RepairOrder → DiagnosticReport | 1:N | Pre/post tests |
| RepairOrder → SparePart | 1:N | Parts used |
| **Accounting** |||
| Participant → ValueContainer | 1:N | Owned accounts |
| ValueContainer → MovementLeg | 1:N | Debit/credit entries |
| ValueMovement → MovementLeg | 1:N | Always 2+ legs |
| MovementLeg → MovementPosting | 1:N | Temporal postings |
| MasterAccount → SubAccount | 1:N | Client accounts |
| **Event Store** |||
| Transaction → Datom | 1:N | Atomic changes |
| Datom → DatomMerkleNode | N:1 | Merkle inclusion |
| Entity → Datom | 1:N | All attributes |
| DatomTransaction → TransactionEntity | 1:1 | Business link |
| **Settlement** |||
| ValueMovement → SettlementInstruction | 1:1 | Settlement link |
| SettlementInstruction → ClearingBatch | N:1 | Batch grouping |
| Participant → NettingPosition | 1:N | With counterparties |
| **Documents** |||
| Participant → Document | 1:N | Owned documents |
| Document → DocumentVersion | 1:N | Version history |
| Document → DocumentSignature | 1:N | Signatures |
| AnyEntity → Document | 1:N | Linked documents |
| **Audit** |||
| AnyTable → AuditLog | 1:N | Change history |
| Participant → SecurityEvent | 1:N | Auth events |

---

## Standards Compliance Matrix

| Standard | Implementation | File(s) |
|----------|---------------|---------|
| **ISO 17442 (LEI)** | Participant LEI validation | 001, 004 |
| **ISO 9362 (BIC/SWIFT)** | Participant BIC validation | 001, 004 |
| **ISO 13616 (IBAN)** | Sub-account IBAN validation | 009, 030 |
| **ISO 4217 (Currency)** | Currency codes table | 001, 032 |
| **ISO 3166 (Country)** | Country codes table | 001, 032 |
| **ISO 20022 (Messages)** | UETR, end_to_end_id fields | 008, 018 |
| **ISO 8601 (Date/Time)** | TIMESTAMPTZ usage | All |
| **Basel III** | LCR, NSFR, Capital Ratios | 024 |
| **GDPR** | PII hashing, retention, erasure | 004, 023, 027 |
| **CASS (FCA)** | Client money segregation | 009 |
| **PCI DSS** | Masked card data, tokens | 012 |
| **eIDAS** | Digital signature levels | 023 |
| **SOC 2** | Audit logging, controls | 020, 031 |

---

## File Reference

| File | Primitive | Description |
|------|-----------|-------------|
| 000-003 | Foundation | Schema, types, crypto, temporal |
| 004 | 1 | Identity & Tenancy |
| 005 | 2 | Device & Product |
| 006 | 3 | Agent Relationships |
| 007 | 4 | Value Containers |
| 008 | 5 | Value Movements |
| 009 | 19 | Sub-Ledger & Segregation |
| 010 | 10 | Insurance Policy |
| 011 | 11 | Repair Order |
| 012 | 12 | Sales Transaction |
| 013 | 6 | Datoms (Event Store) |
| 014 | 7 | Transaction Entity |
| 015 | 8 | Product Contract |
| 016 | 9 | Real-Time Authorization |
| 017 | 16 | Entitlements |
| 018 | 13 | Settlement |
| 019 | 14 | Reconciliation |
| 020-021 | 15 | Control, Batch, EOD |
| 022 | 17 | Jurisdictions |
| 023 | 18 | Documents |
| 024 | 20 | Capital & Liquidity |
| 025 | 21 | Streaming |
| 026 | 22 | Peer Caching |
| 027 | 23 | Archival |
| 028 | 24 | Health Checks |
| 029-033 | Operations | Wiring, indexes, audit, seed, verify |

---

*End of Entity Relationship Diagram*
