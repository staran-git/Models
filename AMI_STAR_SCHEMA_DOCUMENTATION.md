# AMI Analytics Star Schema - Design Documentation

## Executive Summary

This star schema is designed for **topology-addressable, bi-temporal analytics** of Advanced Metering Infrastructure (AMI) data. It enables utilities to query meter readings, events, and outages in the context of the electrical grid's **dynamic topology** while maintaining full historical accuracy of both real-world changes and system recordings.

---

## Core Design Principles

### 1. Topology-Addressable Design

**Problem:** AMI data is useless if you can't answer "What's the load on Transformer X right now?"

**Solution:** The `bridge_topology_connectivity` table acts as the **critical binding** between meters and the grid hierarchy.

#### Key Features:
- Every fact table has a `topology_bridge_sk` foreign key
- Point-in-time joins ensure readings are attributed to the **correct transformer/feeder** at the time they occurred
- Supports both **As-Built** (physical wiring) and **As-Operated** (current switch states) connectivity

#### Example Query Pattern:
```sql
-- Get all readings for Transformer X between two timestamps
SELECT SUM(value_kwh) 
FROM fact_interval_reading fir
INNER JOIN bridge_topology_connectivity btc
    ON fir.topology_bridge_sk = btc.topology_bridge_sk
    AND fir.interval_start_time >= btc.valid_from 
    AND fir.interval_start_time < btc.valid_to
WHERE btc.transformer_id = 'TRFR_X'
  AND btc.is_current = TRUE;
```

---

### 2. Bi-Temporal Modeling

**Two Time Dimensions:**

1. **Valid Time** (`valid_from`, `valid_to`): When the fact was **true in the real world**
2. **Transaction Time** (`recorded_from`, `recorded_to`): When the system **knew** about it

#### Why Bi-Temporal?

**Scenario:** A meter was physically moved on March 10th, but the GIS update wasn't recorded until March 15th.

- **Valid Time:** March 10th (when the change actually happened)
- **Transaction Time:** March 15th (when the system recorded it)

This allows:
- **Reprocessing** historical data with "what we know now"
- **Auditing** what the system believed at any point in time
- **Compliance** with regulatory requirements for data lineage

#### Implementation:
- `bridge_topology_connectivity` has both valid/transaction time
- `fact_interval_reading` has `valid_from`/`valid_to` for late-arriving corrections
- All SCD Type 2 dimensions have `effective_date`/`expiration_date`

---

### 3. Slowly Changing Dimensions (SCD Type 2)

**Entities with SCD Type 2:**
- `dim_meter` - Firmware upgrades, hardware changes
- `dim_usage_point` - Customer/rate class changes
- `dim_transformer`, `dim_feeder`, `dim_substation` - Grid reconfigurations
- `bridge_topology_connectivity` - The critical topology binding

#### SCD Type 2 Pattern:
```sql
-- Every version of the same entity gets a new surrogate key
meter_sk | meter_id | firmware_version | effective_date | expiration_date | is_current
---------|----------|------------------|----------------|-----------------|------------
1001     | MTR_123  | v1.0            | 2023-01-01     | 2024-03-15      | FALSE
1002     | MTR_123  | v2.1            | 2024-03-15     | 9999-12-31      | TRUE
```

**Benefits:**
- Full history of changes
- Point-in-time reconstruction of any dimension state
- Supports "as-of" reporting for regulatory compliance

---

## Schema Architecture

### Fact Tables (4 Types)

#### 1. **Transactional Fact: `fact_interval_reading`**
- **Grain:** One row per meter per interval (15-min, 1-hour)
- **Volume:** Billions of rows/year
- **Key Design:** 
  - `topology_bridge_sk` enables topology-addressable queries
  - Bi-temporal attributes for late-arriving corrections
  - Semi-additive facts (min/max voltage)

#### 2. **Transactional Fact: `fact_end_device_event`**
- **Grain:** One row per meter event
- **Purpose:** Outage detection, tamper alerts, communication failures
- **Key Design:**
  - Links to topology at event time
  - Severity/status for operational dashboards

#### 3. **Periodic Snapshot Fact: `fact_topology_snapshot`**
- **Grain:** One row per usage point per day
- **Purpose:** Capture "As-Operated" state (switch positions)
- **Key Design:**
  - Tracks SCADA-driven topology changes
  - `connectivity_cluster_id` for electrical islands
  - Enables "As-Built vs. As-Operated" analysis

#### 4. **Accumulating Snapshot Fact: `fact_meter_lifecycle`**
- **Grain:** One row per meter
- **Purpose:** Track meter from manufacture → installation → retirement
- **Key Design:**
  - Multiple milestone dates
  - Calculated durations (days in service)
  - Updated as milestones occur

---

### Critical Bridge Tables

#### **`bridge_topology_connectivity`** (The Heart of Topology-Addressability)

**Purpose:** Bind meters to transformers/feeders at any point in time.

**Attributes:**
- **Entity Keys:** `meter_id`, `transformer_id`, `feeder_id`, `substation_id`
- **Surrogate Keys:** Pre-joined to dimensions for performance
- **Bi-Temporal:** `valid_from`/`valid_to` + `recorded_from`/`recorded_to`
- **Connectivity Type:** `As-Built` vs. `As-Operated`
- **Change Tracking:** `work_order_id`, `scada_event_id`, `change_reason`

**Query Pattern:**
```sql
-- All readings for a feeder on a specific day
SELECT SUM(fir.value_kwh)
FROM fact_interval_reading fir
INNER JOIN bridge_topology_connectivity btc
    ON fir.topology_bridge_sk = btc.topology_bridge_sk
WHERE btc.feeder_id = 'FDR_EAST_01'
  AND fir.interval_start_time BETWEEN '2024-10-27 00:00' AND '2024-10-27 23:59'
  AND fir.interval_start_time >= btc.valid_from 
  AND fir.interval_start_time < btc.valid_to;
```

#### **`bridge_meter_usage_point`**

**Purpose:** Track meter swaps (e.g., defective meter replaced).

**Attributes:**
- Temporal tracking (`valid_from`/`valid_to`)
- Installation/removal reasons
- Work order references

---

### Dimension Tables

#### **Core Dimensions (SCD Type 2):**

1. **`dim_meter`**
   - Tracks firmware versions, hardware changes
   - CIM EndDevice attributes (MAC, IP)
   - Lifecycle status

2. **`dim_usage_point`**
   - The "service point" (meter socket)
   - Links to GIS via `connectivity_node_id`
   - Tracks customer/rate class changes

3. **`dim_service_location`**
   - Physical address + GIS coordinates
   - Uses `geohash` for spatial indexing
   - SCD Type 1 (addresses rarely change)

#### **Topology Dimensions (SCD Type 2):**

4. **`dim_transformer`**
5. **`dim_feeder`**
6. **`dim_substation`**

All have:
- Denormalized hierarchy (e.g., transformer has `feeder_id`)
- GIS attributes (`latitude`, `longitude`, `gis_feature_id`)
- Effective/expiration dates for SCD Type 2

#### **Supporting Dimensions:**

7. **`dim_time`** - Date/time attributes, TOU blocks, fiscal periods
8. **`dim_reading_type`** - kWh, kW, kVARh, etc.
9. **`dim_event_type`** - Outage, tamper, communication failure
10. **`dim_manufacturer`** - Meter vendor info

---

### Reference Tables

#### **`ref_connectivity_node`**
- GIS grid topology (busbars, junctions)
- Self-referencing hierarchy (`parent_node_id`)
- Updated from GIS system

#### **`ref_connectivity_cluster`**
- Represents "electrical islands"
- Pre-computed for performance
- Tracks total load, meter count per cluster

---

## Advanced Concepts Implementation

### 1. **As-Built vs. As-Operated**

**As-Built (Static):**
- Physical wiring in GIS
- Modeled as: SCD Type 2 in topology dimensions
- Changes via work orders

**As-Operated (Dynamic):**
- Current electrical path based on switch states (SCADA)
- Modeled as: `fact_topology_snapshot` (periodic snapshots)
- Changes multiple times daily

**Query to Find Deviations:**
```sql
-- Meters operating on different transformer than as-built
SELECT *
FROM fact_topology_snapshot fts
INNER JOIN bridge_topology_connectivity btc_built
    ON fts.usage_point_sk = btc_built.usage_point_sk
    AND btc_built.connectivity_type = 'As-Built'
WHERE fts.transformer_sk != btc_built.transformer_sk;
```

---

### 2. **Connectivity Clusters (Electrical Islands)**

**Problem:** Joining millions of rows to find all meters on a feeder is slow.

**Solution:** Pre-compute `connectivity_cluster_id` and store in bridge table.

**Benefits:**
- Instant outage impact analysis
- Faster load aggregation
- Efficient "what-if" scenario modeling

**Implementation:**
```sql
-- Assign cluster ID during ETL
UPDATE bridge_topology_connectivity
SET connectivity_cluster_id = (
    SELECT cluster_id 
    FROM ref_connectivity_cluster 
    WHERE primary_transformer_id = btc.transformer_id
);
```

---

### 3. **Late-Arriving Facts (Buffer & Reprocess)**

**Scenario:** Meter reading arrives before topology update.

**Solution:**
1. **Silver Layer:** Hold facts in staging until topology is known
2. **Reprocessing:** Daily job re-binds facts to latest topology
3. **Bi-Temporal:** Track when the binding was corrected

**ETL Pattern:**
```sql
-- Daily reprocessing job
UPDATE fact_interval_reading fir
SET topology_bridge_sk = (
    SELECT topology_bridge_sk
    FROM bridge_topology_connectivity btc
    WHERE fir.meter_id = btc.meter_id
      AND fir.interval_start_time >= btc.valid_from
      AND fir.interval_start_time < btc.valid_to
      AND btc.is_current = TRUE
)
WHERE fir.topology_bridge_sk IS NULL;
```

---

## Performance Optimization

### 1. **Partitioning Strategy**

**Fact Tables:**
- Partition by `interval_start_time` (monthly)
- Aligns with temporal queries

**Bridge Tables:**
- Partition by `valid_from` (monthly)
- Enables partition pruning on point-in-time joins

**Example (Snowflake):**
```sql
ALTER TABLE fact_interval_reading 
CLUSTER BY (topology_bridge_sk, time_sk, meter_sk);

ALTER TABLE bridge_topology_connectivity
CLUSTER BY (usage_point_id, valid_from, is_current);
```

---

### 2. **Materialized Views**

**Purpose:** Pre-aggregate for common queries

**Example:**
```sql
CREATE MATERIALIZED VIEW mv_hourly_transformer_load AS
SELECT 
    transformer_id,
    date,
    hour,
    SUM(value_kwh) as total_kwh,
    COUNT(DISTINCT meter_sk) as meter_count
FROM fact_interval_reading fir
JOIN bridge_topology_connectivity btc USING (topology_bridge_sk)
JOIN dim_time dt USING (time_sk)
GROUP BY transformer_id, date, hour;
```

---

### 3. **Inferred Member Pattern**

**Problem:** Dimension may not exist when fact arrives.

**Solution:** Create placeholder dimension record with `is_inferred = TRUE`.

**Example:**
```sql
-- If meter not in dim_meter, create placeholder
INSERT INTO dim_meter (meter_id, is_inferred, is_current)
VALUES ('MTR_UNKNOWN_123', TRUE, TRUE)
ON CONFLICT DO NOTHING;
```

---

## GIS Integration

### **Data Flow:**
1. GIS system (ArcGIS, Smallworld) → ETL → `ref_connectivity_node`
2. Asset management → `dim_transformer`, `dim_feeder`, `dim_substation`
3. Work orders → `bridge_topology_connectivity` (As-Built updates)
4. SCADA → `fact_topology_snapshot` (As-Operated updates)

### **Key Attributes:**
- `gis_feature_id` - Links to GIS layers
- `latitude`/`longitude` - Spatial coordinates
- `geohash` - Spatial indexing for proximity queries
- `gis_updated_at` - Timestamp of last GIS sync

---

## Query Patterns & Use Cases

### **Use Case 1: Transformer Load Profile**
```sql
-- Hourly load on a transformer for last 7 days
SELECT 
    dt.date,
    dt.hour,
    SUM(fir.value_kwh) as total_kwh,
    AVG(fir.value_volts) as avg_voltage
FROM fact_interval_reading fir
INNER JOIN bridge_topology_connectivity btc
    ON fir.topology_bridge_sk = btc.topology_bridge_sk
INNER JOIN dim_time dt ON fir.time_sk = dt.time_sk
WHERE btc.transformer_id = 'TRFR_1234'
  AND dt.date >= CURRENT_DATE - 7
GROUP BY dt.date, dt.hour
ORDER BY dt.date, dt.hour;
```

### **Use Case 2: Outage Impact Analysis**
```sql
-- Find all affected meters during a feeder outage
SELECT 
    btc.feeder_id,
    btc.connectivity_cluster_id,
    COUNT(DISTINCT fede.meter_sk) as affected_meters,
    MIN(fede.event_timestamp) as first_outage
FROM fact_end_device_event fede
INNER JOIN bridge_topology_connectivity btc
    ON fede.topology_bridge_sk = btc.topology_bridge_sk
INNER JOIN dim_event_type det ON fede.event_type_sk = det.event_type_sk
WHERE det.event_category = 'Outage'
  AND fede.event_timestamp >= NOW() - INTERVAL '1 HOUR'
GROUP BY btc.feeder_id, btc.connectivity_cluster_id
HAVING COUNT(DISTINCT fede.meter_sk) > 10;
```

### **Use Case 3: Meter Swap Audit**
```sql
-- Show all meter swaps at a location
SELECT 
    dm.asset_tag_number,
    bmup.valid_from as installed_date,
    bmup.valid_to as removed_date,
    bmup.installation_reason,
    DATEDIFF(day, bmup.valid_from, bmup.valid_to) as days_installed
FROM bridge_meter_usage_point bmup
INNER JOIN dim_meter dm ON bmup.meter_sk = dm.meter_sk
WHERE bmup.usage_point_id = 'UP_12345'
ORDER BY bmup.valid_from DESC;
```

### **Use Case 4: As-Built vs. As-Operated Deviation**
```sql
-- Find usage points where current operation differs from as-built
SELECT 
    fts.usage_point_sk,
    btc_built.transformer_id as built_transformer,
    btc_operated.transformer_id as operated_transformer,
    fts.upstream_switch_state
FROM fact_topology_snapshot fts
LEFT JOIN bridge_topology_connectivity btc_built
    ON fts.usage_point_sk = btc_built.usage_point_sk
    AND btc_built.connectivity_type = 'As-Built'
    AND btc_built.is_current = TRUE
LEFT JOIN bridge_topology_connectivity btc_operated
    ON fts.usage_point_sk = btc_operated.usage_point_sk
    AND btc_operated.connectivity_type = 'As-Operated'
    AND btc_operated.is_current = TRUE
WHERE fts.snapshot_timestamp = (SELECT MAX(snapshot_timestamp) FROM fact_topology_snapshot)
  AND btc_built.transformer_id != btc_operated.transformer_id;
```

---

## ETL Considerations

### **Data Lineage:**
- Every table has `etl_batch_id` linking to `etl_batch_log`
- Bi-temporal tracking (`recorded_at`) shows when data entered system
- Source system tracked for multi-vendor environments

### **Idempotency:**
- Natural keys (`interval_id`, `event_id`) ensure duplicate prevention
- Upsert logic based on natural keys

### **Late-Arriving Dimensions:**
- Use inferred member pattern
- Daily reconciliation jobs

### **Topology Synchronization:**
- GIS changes → Update `dim_transformer`/`dim_feeder` (SCD Type 2)
- Create new `bridge_topology_connectivity` record
- Reprocess recent facts if needed

---

## Summary of Best Practices

1. ✅ **Never delete topology records** - Expire with `valid_to`
2. ✅ **Use surrogate keys** - Not natural keys for joins
3. ✅ **Partition by time** - Facts and bridge tables aligned
4. ✅ **Index bi-temporal columns** - `(valid_from, valid_to, is_current)`
5. ✅ **Pre-compute clusters** - Avoid expensive joins
6. ✅ **Materialize common aggregations** - Hourly/daily summaries
7. ✅ **Track both valid and transaction time** - Full auditability
8. ✅ **Denormalize carefully** - Hierarchy in dimensions for performance
9. ✅ **GIS integration** - Keep `gis_updated_at` timestamps
10. ✅ **Version everything** - SCD Type 2 on all changing entities

---

## Technology Recommendations

**Optimal Platforms:**
- **Snowflake** - Excellent clustering, time-travel, zero-copy cloning
- **BigQuery** - Partitioning, clustering, GIS functions
- **Databricks** - Delta Lake time-travel, lakehouse architecture

**Not Recommended:**
- Traditional OLTP databases (Oracle, SQL Server) - Poor performance at scale
- Graph databases (Neo4j) - Good for topology, poor for high-volume time-series

---

## Regulatory & Compliance

This schema supports:
- **FERC 714** - Load data reporting
- **PUC** - Customer billing audits
- **NERC CIP** - Critical infrastructure tracking
- **Data retention** - Full historical reconstruction via SCD Type 2
- **Audit trails** - Bi-temporal tracking of all changes

---

## Conclusion

This star schema provides **enterprise-grade AMI analytics** with:
- ✅ Topology-addressable queries (critical for grid operations)
- ✅ Bi-temporal modeling (full audit trail)
- ✅ SCD Type 2 (complete history)
- ✅ As-Built vs. As-Operated support
- ✅ GIS integration
- ✅ Scalability to billions of rows
- ✅ Regulatory compliance

The `bridge_topology_connectivity` table is the innovation that makes this work - it's the glue between meters and the grid, with full temporal tracking.
