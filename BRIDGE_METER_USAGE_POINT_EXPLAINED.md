# Understanding BRIDGE_METER_USAGE_POINT

## The Problem It Solves

**Question**: What happens when a meter at a house breaks and needs to be replaced?

**Challenge**: 
- The **Usage Point** (the meter socket on the house) doesn't change - it's the physical location where service is delivered
- The **Meter** (the physical device) changes - you remove the broken one and install a new one
- You need to track which meter was installed at which location, and when

**Without the bridge**: You'd have to modify the meter record or the usage point record, losing history of the swap.

**With the bridge**: You maintain complete history of all meter swaps while keeping both the meter and usage point dimensions clean.

---

## Real-World Example: Meter Swap Scenario

### The Story

**123 Main Street** has a meter socket (Usage Point UP_5678) where meters are installed to measure electricity usage.

**Timeline of Events:**

1. **Jan 1, 2023**: Original meter MTR_AAA installed during home construction
2. **June 15, 2024**: Meter MTR_AAA fails (display malfunction)
3. **June 15, 2024**: Technician replaces with new meter MTR_BBB
4. **Dec 1, 2025**: Utility upgrades to smart meter MTR_CCC

---

## How the Data Model Captures This

### DIM_USAGE_POINT (The Service Location - Stays Constant)

```
usage_point_sk | usage_point_id | service_type | phase_code | customer_account_id | effective_date | expiration_date | is_current
---------------|----------------|--------------|------------|---------------------|----------------|-----------------|------------
9001           | UP_5678        | Electric     | ABC        | CUST_12345          | 2023-01-01     | 9999-12-31      | TRUE
```

**Note**: The usage point record doesn't change when meters are swapped. It represents the physical service point.

---

### DIM_METER (The Physical Devices - Multiple Records)

```
meter_sk | meter_id  | asset_tag_number | hardware_version | firmware_version | life_cycle_status | effective_date | expiration_date | is_current
---------|-----------|------------------|------------------|------------------|-------------------|----------------|-----------------|------------
5001     | MTR_AAA   | SN-12345-A       | HW-v1.0          | FW-v1.5          | Defective         | 2023-01-01     | 2024-06-15      | FALSE
5002     | MTR_AAA   | SN-12345-A       | HW-v1.0          | FW-v1.5          | Retired           | 2024-06-15     | 9999-12-31      | TRUE
6001     | MTR_BBB   | SN-67890-B       | HW-v1.2          | FW-v2.0          | Installed         | 2024-06-15     | 2025-12-01      | FALSE
6002     | MTR_BBB   | SN-67890-B       | HW-v1.2          | FW-v2.0          | Retired           | 2025-12-01     | 9999-12-31      | TRUE
7001     | MTR_CCC   | SN-99999-C       | HW-v2.0          | FW-v3.5          | Installed         | 2025-12-01     | 9999-12-31      | TRUE
```

**Note**: Each meter has multiple records (SCD Type 2) tracking status changes over time.

---

### BRIDGE_METER_USAGE_POINT (The Critical Bridge - Tracks Associations)

```
meter_usage_point_sk | meter_sk | usage_point_sk | meter_id  | usage_point_id | valid_from  | valid_to    | is_current | installation_reason      | removal_reason           | installation_work_order_id
---------------------|----------|----------------|-----------|----------------|-------------|-------------|------------|--------------------------|--------------------------|---------------------------
8001                 | 5001     | 9001           | MTR_AAA   | UP_5678        | 2023-01-01  | 2024-06-15  | FALSE      | New Construction         | Device Malfunction       | WO-2023-001
8002                 | 6001     | 9001           | MTR_BBB   | UP_5678        | 2024-06-15  | 2025-12-01  | FALSE      | Replacement - Defective  | Planned Upgrade          | WO-2024-456
8003                 | 7001     | 9001           | MTR_CCC   | UP_5678        | 2025-12-01  | 9999-12-31  | TRUE       | Smart Meter Upgrade      | NULL                     | WO-2025-789
```

**Key Observations:**
1. Same `usage_point_sk` (9001) across all records - the location doesn't change
2. Different `meter_sk` values - physical meters change
3. `valid_from`/`valid_to` create non-overlapping time windows
4. `is_current` flag shows which association is active now
5. Work order IDs provide audit trail

---

## Query Examples

### Query 1: "What meter is currently installed at 123 Main Street?"

```sql
SELECT 
    dm.meter_id,
    dm.asset_tag_number,
    dm.firmware_version,
    bmup.valid_from as installed_date,
    bmup.installation_reason
FROM bridge_meter_usage_point bmup
INNER JOIN dim_meter dm ON bmup.meter_sk = dm.meter_sk AND dm.is_current = TRUE
INNER JOIN dim_usage_point dup ON bmup.usage_point_sk = dup.usage_point_sk
WHERE dup.usage_point_id = 'UP_5678'
  AND bmup.is_current = TRUE;
```

**Result:**
```
meter_id | asset_tag_number | firmware_version | installed_date | installation_reason
---------|------------------|------------------|----------------|--------------------
MTR_CCC  | SN-99999-C       | FW-v3.5          | 2025-12-01     | Smart Meter Upgrade
```

---

### Query 2: "Show me the complete meter swap history for 123 Main Street"

```sql
SELECT 
    dm.meter_id,
    dm.asset_tag_number,
    bmup.valid_from as installed_date,
    bmup.valid_to as removed_date,
    DATEDIFF(day, bmup.valid_from, bmup.valid_to) as days_installed,
    bmup.installation_reason,
    bmup.removal_reason,
    bmup.installation_work_order_id
FROM bridge_meter_usage_point bmup
INNER JOIN dim_meter dm ON bmup.meter_sk = dm.meter_sk
INNER JOIN dim_usage_point dup ON bmup.usage_point_sk = dup.usage_point_sk
WHERE dup.usage_point_id = 'UP_5678'
ORDER BY bmup.valid_from DESC;
```

**Result:**
```
meter_id | asset_tag_number | installed_date | removed_date | days_installed | installation_reason      | removal_reason      | work_order_id
---------|------------------|----------------|--------------|----------------|--------------------------|---------------------|---------------
MTR_CCC  | SN-99999-C       | 2025-12-01     | 9999-12-31   | NULL (active)  | Smart Meter Upgrade      | NULL                | WO-2025-789
MTR_BBB  | SN-67890-B       | 2024-06-15     | 2025-12-01   | 534 days       | Replacement - Defective  | Planned Upgrade     | WO-2024-456
MTR_AAA  | SN-12345-A       | 2023-01-01     | 2024-06-15   | 531 days       | New Construction         | Device Malfunction  | WO-2023-001
```

---

### Query 3: "Get all readings from 123 Main Street, regardless of which meter was installed"

**This is the POWER of the bridge pattern!**

```sql
SELECT 
    fir.interval_start_time,
    dm.meter_id,
    fir.value_kwh,
    fir.value_volts
FROM fact_interval_reading fir
INNER JOIN bridge_meter_usage_point bmup
    ON fir.meter_sk = bmup.meter_sk
    AND fir.interval_start_time >= bmup.valid_from 
    AND fir.interval_start_time < bmup.valid_to
INNER JOIN dim_meter dm ON bmup.meter_sk = dm.meter_sk
INNER JOIN dim_usage_point dup ON bmup.usage_point_sk = dup.usage_point_sk
WHERE dup.usage_point_id = 'UP_5678'
  AND fir.interval_start_time BETWEEN '2024-06-01' AND '2024-07-01'
ORDER BY fir.interval_start_time;
```

**Result (partial):**
```
interval_start_time   | meter_id | value_kwh | value_volts
----------------------|----------|-----------|------------
2024-06-01 00:00:00   | MTR_AAA  | 2.45      | 120.2      <- Old meter
2024-06-01 01:00:00   | MTR_AAA  | 2.38      | 120.1      <- Old meter
...
2024-06-15 10:00:00   | MTR_AAA  | 2.51      | 119.9      <- Last reading from old meter
2024-06-15 11:00:00   | MTR_BBB  | 2.47      | 120.3      <- First reading from new meter
2024-06-15 12:00:00   | MTR_BBB  | 2.44      | 120.2      <- New meter
...
```

**Key Point**: The query seamlessly transitions between meters based on the `valid_from`/`valid_to` time windows in the bridge table!

---

### Query 4: "Which meters have been installed at the most locations?" (Identifying Portable Test Meters)

```sql
SELECT 
    dm.meter_id,
    dm.asset_tag_number,
    COUNT(DISTINCT bmup.usage_point_sk) as number_of_locations,
    MIN(bmup.valid_from) as first_installed,
    MAX(bmup.valid_to) as last_removed
FROM bridge_meter_usage_point bmup
INNER JOIN dim_meter dm ON bmup.meter_sk = dm.meter_sk AND dm.is_current = TRUE
GROUP BY dm.meter_id, dm.asset_tag_number
HAVING COUNT(DISTINCT bmup.usage_point_sk) > 5
ORDER BY number_of_locations DESC;
```

**Use Case**: Identify test meters or meters that have been moved around frequently (possibly indicating quality issues).

---

## Why This Design Is Better Than Alternatives

### ❌ Alternative 1: Store meter_id directly in DIM_USAGE_POINT

**Problem**: 
- Loses history of previous meters
- Requires updating the dimension record (expensive in SCD Type 2)
- Can't answer "what meter was here on June 1, 2024?"

### ❌ Alternative 2: Store usage_point_id directly in DIM_METER

**Problem**:
- One meter can never be moved to another location
- Loses history if meter is re-assigned
- Can't handle test meters that move between locations

### ✅ The Bridge Pattern

**Benefits**:
1. **Complete History**: Every association is preserved forever
2. **Point-in-Time Queries**: Can reconstruct any past state
3. **Flexibility**: Meters can move, usage points can have multiple meters over time
4. **Audit Trail**: Work orders, reasons, timestamps all tracked
5. **Performance**: Pre-joined surrogate keys avoid expensive joins

---

## Integration with Topology Bridge

**Important**: `BRIDGE_METER_USAGE_POINT` works in tandem with `BRIDGE_TOPOLOGY_CONNECTIVITY`

```
FACT_INTERVAL_READING
    ├── meter_sk ──────────────► BRIDGE_METER_USAGE_POINT ──► DIM_USAGE_POINT
    └── topology_bridge_sk ────► BRIDGE_TOPOLOGY_CONNECTIVITY ──┬─► DIM_TRANSFORMER
                                                                  ├─► DIM_FEEDER  
                                                                  └─► DIM_SUBSTATION
```

**Combined Query**: "Show total consumption at 123 Main Street, broken down by which transformer was feeding it"

```sql
SELECT 
    dup.usage_point_id,
    dt.transformer_name,
    DATE(fir.interval_start_time) as date,
    SUM(fir.value_kwh) as daily_kwh
FROM fact_interval_reading fir
-- Link to meter-usage point association
INNER JOIN bridge_meter_usage_point bmup
    ON fir.meter_sk = bmup.meter_sk
    AND fir.interval_start_time >= bmup.valid_from 
    AND fir.interval_start_time < bmup.valid_to
INNER JOIN dim_usage_point dup ON bmup.usage_point_sk = dup.usage_point_sk
-- Link to topology (which transformer was feeding this usage point)
INNER JOIN bridge_topology_connectivity btc
    ON fir.topology_bridge_sk = btc.topology_bridge_sk
INNER JOIN dim_transformer dt ON btc.transformer_sk = dt.transformer_sk AND dt.is_current = TRUE
WHERE dup.usage_point_id = 'UP_5678'
  AND fir.interval_start_time >= '2024-01-01'
GROUP BY dup.usage_point_id, dt.transformer_name, DATE(fir.interval_start_time)
ORDER BY date;
```

---

## Common ETL Patterns

### Pattern 1: New Meter Installation

```sql
-- Step 1: Insert new meter into DIM_METER
INSERT INTO dim_meter (meter_sk, meter_id, asset_tag_number, ..., is_current)
VALUES (NEXT_SK, 'MTR_NEW', 'SN-11111-X', ..., TRUE);

-- Step 2: Create bridge association
INSERT INTO bridge_meter_usage_point (
    meter_usage_point_sk,
    meter_sk,
    usage_point_sk,
    meter_id,
    usage_point_id,
    valid_from,
    valid_to,
    is_current,
    installation_reason,
    installation_work_order_id
)
VALUES (
    NEXT_BRIDGE_SK,
    NEXT_SK,  -- The new meter's SK
    9001,     -- Existing usage point SK
    'MTR_NEW',
    'UP_5678',
    '2025-12-01',
    '9999-12-31',
    TRUE,
    'Smart Meter Upgrade',
    'WO-2025-789'
);
```

### Pattern 2: Meter Swap (Remove Old, Install New)

```sql
-- Step 1: Close out the old association
UPDATE bridge_meter_usage_point
SET valid_to = '2024-06-15',
    is_current = FALSE,
    removal_reason = 'Device Malfunction',
    removal_work_order_id = 'WO-2024-456'
WHERE meter_id = 'MTR_AAA'
  AND usage_point_id = 'UP_5678'
  AND is_current = TRUE;

-- Step 2: Update old meter status in DIM_METER (SCD Type 2)
UPDATE dim_meter
SET expiration_date = '2024-06-15',
    is_current = FALSE
WHERE meter_id = 'MTR_AAA'
  AND is_current = TRUE;

INSERT INTO dim_meter (meter_sk, meter_id, life_cycle_status, effective_date, is_current, ...)
VALUES (5002, 'MTR_AAA', 'Retired', '2024-06-15', TRUE, ...);

-- Step 3: Insert new meter and create new association
-- (Same as Pattern 1 above)
```

---

## Summary

**BRIDGE_METER_USAGE_POINT** is the critical many-to-many resolver that:

1. **Decouples meters from locations** - Allows flexible reassignment
2. **Preserves complete history** - Never loses a swap event
3. **Enables point-in-time queries** - Reconstruct any past state
4. **Tracks business context** - Reasons, work orders, timestamps
5. **Works with topology bridge** - Combined for full grid-aware analytics

**Real-World Impact**: Without this bridge, you couldn't answer basic operational questions like "How much energy did this house consume last year?" when the meter was swapped mid-year.
