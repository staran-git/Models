# Understanding BRIDGE_METER_USAGE_POINT
# Understanding FACT_END_DEVICE_EVENT

## How AMI Systems Generate Event Data

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




# FACT_END_DEVICE_EVENT - Data Sources and Event Type Catalog

## How AMI Systems Generate Event Data

### Understanding AMI Event Data Flow

**AMI (Advanced Metering Infrastructure)** smart meters don't just send interval readings - they also send **event notifications** when specific conditions are detected. These events come from the same AMI Head-End System that collects meter readings.

```
Smart Meter (at customer site)
    ├─► Interval Readings (every 15 min) ──► AMI Head-End ──► MDM ──► fact_interval_reading
    └─► Event Notifications (real-time)  ──► AMI Head-End ──► MDM ──► fact_end_device_event
```

---

## Where Event Data Comes From

### Source 1: AMI Head-End System (Primary Source)
**Examples**: Itron, Landis+Gyr, Honeywell, Sensus, Aclara, Silver Spring Networks

**What It Sends**:
- Automatic event messages when meters detect anomalies
- Event codes defined by manufacturer
- Timestamp of when event occurred
- Severity level
- Diagnostic payload (voltage snapshot, tamper details, etc.)

**Delivery Methods**:
1. **Push Notifications**: Meter immediately sends event to head-end (for critical events)
2. **Periodic Polling**: Head-end queries meters for event logs every 15 min - 4 hours
3. **Daily Batch**: Full event log downloaded once per day
4. **Exception-Based**: Only abnormal events transmitted

---

### Source 2: Meter Data Management (MDM) System
**Examples**: Oracle Utilities MDM, MDMS, eMeter, eMeter Suite

**Role**:
- Receives raw events from AMI Head-End
- Validates and enriches event data
- Applies business rules (e.g., "3 power outages in 1 hour = sustained outage")
- Stores in staging tables
- ETL process loads into data warehouse `fact_end_device_event`

---

### Source 3: Outage Management System (OMS) Integration
**Examples**: Oracle OMS, Schneider Electric ADMS, GE DERMS

**Role**:
- Correlates meter events to create outage tickets
- Provides confirmation/resolution timestamps
- May generate synthetic "outage resolved" events
- Feeds back status updates to the data warehouse

---

## Complete Event Type Catalog

### Category 1: POWER QUALITY & OUTAGE EVENTS

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `PWR_OUT_MOMENTARY` | Momentary Outage | Power loss < 5 minutes | Warning | Duration, voltage drop profile | Meter |
| `PWR_OUT_SUSTAINED` | Sustained Outage | Power loss > 5 minutes | Critical | Outage start time, estimated duration | Meter |
| `PWR_RESTORATION` | Power Restored | Power returned after outage | Info | Outage duration, voltage at restoration | Meter |
| `VOLTAGE_SAG` | Voltage Sag | Voltage dropped 10-90% for 0.5-1 min | Warning | Min voltage, duration, phase affected | Meter |
| `VOLTAGE_SWELL` | Voltage Swell | Voltage increased >110% nominal | Warning | Max voltage, duration, phase affected | Meter |
| `OVER_VOLTAGE` | Over Voltage | Voltage >120% of nominal sustained | Critical | Voltage reading, duration, timestamp | Meter |
| `UNDER_VOLTAGE` | Under Voltage | Voltage <85% of nominal sustained | Critical | Voltage reading, duration, timestamp | Meter |
| `PHASE_LOSS` | Phase Loss | One or more phases lost (3-phase) | Critical | Phase identifier, voltage readings | Meter |
| `PHASE_REVERSAL` | Phase Reversal | Phase sequence incorrect | Warning | Phase angles, connection type | Meter |
| `FREQUENCY_DEVIATION` | Frequency Out of Spec | Frequency outside 59.5-60.5 Hz | Warning | Measured frequency, duration | Meter |
| `VOLTAGE_IMBALANCE` | Voltage Imbalance | Phase voltages differ >2% | Warning | Per-phase voltages, imbalance % | Meter |
| `HARMONIC_DISTORTION` | Harmonic Distortion | THD exceeds threshold | Info | THD %, harmonic spectrum | Meter |
| `BLINK_EVENT` | Blink | Power interruption < 5 seconds | Info | Blink count, duration | Meter |

---

### Category 2: TAMPER & SECURITY EVENTS

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `TAMPER_DETECT` | Tamper Detected | Physical tamper attempt detected | Critical | Tamper type code, timestamp | Meter |
| `COVER_REMOVAL` | Meter Cover Removed | Cover/seal removed | Critical | Removal timestamp, seal number | Meter |
| `COVER_REPLACED` | Meter Cover Replaced | Cover reattached | Info | Replacement timestamp | Meter |
| `MAGNETIC_TAMPER` | Magnetic Interference | Strong magnetic field detected | Critical | Field strength, duration | Meter |
| `INVERSION_TAMPER` | Meter Inversion | Meter installed upside down | Critical | Orientation angle | Meter |
| `REVERSE_ENERGY_FLOW` | Reverse Energy Flow | Power flowing backward | Warning | kWh reversed, duration | Meter |
| `BYPASS_DETECTED` | Meter Bypass | Current detected without voltage | Critical | Current reading, voltage reading | Meter |
| `CASE_OPEN` | Meter Case Opened | Terminal block access | Critical | Open timestamp | Meter |
| `SEAL_BROKEN` | Physical Seal Broken | Tamper seal broken | Critical | Seal ID, break timestamp | Meter |
| `CT_RATIO_CHANGE` | CT Ratio Altered | Current transformer ratio modified | Critical | Old ratio, new ratio | Meter |

---

### Category 3: COMMUNICATION EVENTS

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `COMM_LOSS` | Communication Loss | Meter stopped responding | Warning | Last successful ping, missed polls | Head-End |
| `COMM_RESTORED` | Communication Restored | Meter back online | Info | Downtime duration, signal strength | Head-End |
| `WEAK_SIGNAL` | Weak RF Signal | Signal strength below threshold | Warning | RSSI value, neighbor count | Meter |
| `NETWORK_JOIN` | Network Join | Meter joined mesh network | Info | Network ID, parent node | Meter |
| `NETWORK_LEAVE` | Network Leave | Meter left mesh network | Warning | Reason code, timestamp | Meter |
| `REPEATER_FAILURE` | Repeater Down | Mesh repeater not functioning | Warning | Repeater ID, affected meters | Head-End |
| `GATEWAY_FAILURE` | Gateway Down | Collection gateway offline | Critical | Gateway ID, meter count affected | Head-End |
| `FIRMWARE_UPDATE_START` | Firmware Update Started | OTA update initiated | Info | Current version, target version | Head-End |
| `FIRMWARE_UPDATE_SUCCESS` | Firmware Update Complete | OTA update successful | Info | New version, update duration | Meter |
| `FIRMWARE_UPDATE_FAIL` | Firmware Update Failed | OTA update failed | Warning | Error code, rollback status | Meter |
| `CONFIG_CHANGE` | Configuration Changed | Meter settings modified | Info | Changed parameters, source | Head-End |
| `TIME_SYNC_FAIL` | Time Sync Failed | Clock synchronization error | Warning | Clock drift, sync source | Meter |

---

### Category 4: HARDWARE & DIAGNOSTIC EVENTS

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `LOW_BATTERY` | Low Battery | Backup battery voltage low | Warning | Battery voltage, estimated life | Meter |
| `BATTERY_CRITICAL` | Battery Critical | Battery needs immediate replacement | Critical | Battery voltage, days remaining | Meter |
| `BATTERY_FAIL` | Battery Failed | Battery completely depleted | Critical | Failure timestamp | Meter |
| `MEMORY_ERROR` | Memory Error | RAM/Flash error detected | Critical | Error type, affected module | Meter |
| `SELF_TEST_FAIL` | Self-Test Failed | Diagnostic test failure | Critical | Failed test ID, error code | Meter |
| `METROLOGY_ERROR` | Metrology Error | Measurement circuit fault | Critical | Error type, affected phases | Meter |
| `DISPLAY_ERROR` | Display Malfunction | LCD/LED display fault | Warning | Error code | Meter |
| `RTC_FAILURE` | Real-Time Clock Failure | Clock chip malfunction | Warning | Last known time | Meter |
| `TEMPERATURE_HIGH` | High Temperature | Internal temp exceeds limit | Warning | Temperature reading, threshold | Meter |
| `WATCHDOG_RESET` | Watchdog Reset | CPU watchdog triggered restart | Warning | Reset count, reset reason | Meter |
| `POWER_ON` | Meter Powered On | Initial power-up or restart | Info | Power-on reason, firmware version | Meter |
| `POWER_QUALITY_LOG_FULL` | PQ Log Buffer Full | Event buffer at capacity | Info | Oldest event timestamp | Meter |

---

### Category 5: LOAD & DEMAND EVENTS

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `DEMAND_THRESHOLD` | Demand Threshold Exceeded | Peak demand exceeded limit | Warning | Peak kW, threshold, timestamp | Meter |
| `DEMAND_RESET` | Demand Reset | Demand register manually reset | Info | Reset timestamp, reset source | Meter/Head-End |
| `LOAD_PROFILE_FULL` | Load Profile Memory Full | Interval data buffer full | Warning | Oldest interval timestamp | Meter |
| `TOU_RATE_CHANGE` | TOU Rate Schedule Change | Time-of-use schedule updated | Info | New schedule ID, effective date | Head-End |
| `HIGH_CONSUMPTION` | Abnormal High Usage | Usage exceeds typical pattern | Warning | Usage kWh, baseline kWh, % increase | MDM |
| `ZERO_CONSUMPTION` | Zero Usage Detected | No consumption for extended period | Warning | Duration, last reading date | MDM |
| `NEGATIVE_CONSUMPTION` | Negative Usage | Cumulative reading decreased | Critical | Previous reading, current reading | Meter |

---

### Category 6: DISCONNECT SWITCH EVENTS (For AMI 2.0 Meters)

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `REMOTE_DISCONNECT` | Remote Disconnect | Service disconnected remotely | Info | Disconnect reason, operator ID | Head-End |
| `REMOTE_RECONNECT` | Remote Reconnect | Service reconnected remotely | Info | Reconnect reason, operator ID | Head-End |
| `DISCONNECT_FAIL` | Disconnect Failed | Remote disconnect unsuccessful | Critical | Failure reason, retry count | Meter |
| `RECONNECT_FAIL` | Reconnect Failed | Remote reconnect unsuccessful | Critical | Failure reason, retry count | Meter |
| `UNAUTHORIZED_RECONNECT` | Unauthorized Reconnect | Service reconnected without command | Critical | Reconnection method | Meter |
| `LOAD_SIDE_VOLTAGE` | Load Side Voltage Detected | Voltage on load side while disconnected | Critical | Voltage reading, duration | Meter |

---

### Category 7: METER READING EVENTS

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `REGISTER_OVERFLOW` | Register Overflow | Cumulative register rolled over | Info | Rollover count, register type | Meter |
| `NEGATIVE_REGISTER` | Negative Register Value | Register decremented unexpectedly | Critical | Register type, value change | Meter |
| `DIAL_TEST_FAIL` | Dial Test Failed | Accuracy test outside tolerance | Critical | Error %, test date | Technician Tool |
| `INTERVAL_DATA_OVERFLOW` | Interval Buffer Overflow | Too many intervals to transmit | Warning | Lost interval count | Meter |
| `BILLING_READ_SUCCESS` | Billing Read Success | Monthly read completed | Info | Read timestamp, kWh total | Head-End |
| `BILLING_READ_FAIL` | Billing Read Failed | Monthly read unsuccessful | Warning | Failure reason, retry scheduled | Head-End |

---

### Category 8: SPECIAL UTILITY EVENTS

| Event Type Code | Event Name | Description | Severity | Typical Payload Data | Source |
|-----------------|------------|-------------|----------|---------------------|--------|
| `EMERGENCY_LOAD_CONTROL` | Emergency Load Control | DR event - load curtailed | Warning | Event ID, curtailment % | Utility System |
| `PREPAY_LOW_BALANCE` | Prepay Low Balance | Prepaid credits running low | Warning | Remaining balance, days left | Meter |
| `PREPAY_EXHAUSTED` | Prepay Balance Zero | Prepaid credits depleted | Critical | Disconnect pending timestamp | Meter |
| `NET_METERING_EXPORT` | Net Metering Export | Solar/generation export detected | Info | Export kWh, timestamp | Meter |
| `EV_CHARGING_DETECTED` | EV Charging Event | Electric vehicle charging signature | Info | Estimated charge duration, kW | Meter |

---

## Sample Event Data Payload Examples

### Example 1: Power Outage Event
```json
{
  "event_id": "EVT_2024_12345",
  "meter_id": "MTR_AAA_5678",
  "event_type_code": "PWR_OUT_SUSTAINED",
  "event_timestamp": "2024-10-27T14:32:18Z",
  "severity_level": "Critical",
  "payload_data": {
    "outage_start": "2024-10-27T14:32:18Z",
    "voltage_before_outage": 120.3,
    "voltage_at_outage": 0.0,
    "phase_affected": "ABC",
    "estimated_duration_minutes": null,
    "outage_cause_code": "Unknown",
    "transformer_id": "XFMR_1234",
    "feeder_id": "FDR_EAST_05"
  }
}
```

### Example 2: Tamper Event
```json
{
  "event_id": "EVT_2024_67890",
  "meter_id": "MTR_BBB_9012",
  "event_type_code": "MAGNETIC_TAMPER",
  "event_timestamp": "2024-10-28T09:15:42Z",
  "severity_level": "Critical",
  "payload_data": {
    "tamper_type": "Magnetic Interference",
    "field_strength_gauss": 450,
    "duration_seconds": 120,
    "meter_serial": "SN-99887-B",
    "seal_status": "Intact",
    "voltage_during_tamper": 121.5,
    "current_during_tamper": 0.0,
    "investigator_assigned": "INV_4567"
  }
}
```

### Example 3: Communication Loss
```json
{
  "event_id": "EVT_2024_11223",
  "meter_id": "MTR_CCC_3456",
  "event_type_code": "COMM_LOSS",
  "event_timestamp": "2024-10-29T18:22:00Z",
  "severity_level": "Warning",
  "payload_data": {
    "last_successful_ping": "2024-10-29T12:00:00Z",
    "missed_poll_count": 12,
    "downtime_hours": 6.37,
    "signal_strength_before_loss": -72,
    "neighbor_meter_count": 4,
    "parent_repeater_id": "RPT_5678",
    "parent_repeater_status": "Online",
    "probable_cause": "Meter Power Loss"
  }
}
```

---

## How Events Flow into fact_end_device_event

### ETL Process Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ STEP 1: AMI HEAD-END SYSTEM                                     │
│ - Meter sends event notification                                │
│ - Head-End logs event with timestamp, meter ID, event code      │
│ - Stored in Head-End database (Oracle, SQL Server, etc.)        │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 2: MDM SYSTEM (Meter Data Management)                      │
│ - Polls Head-End every 15 minutes for new events                │
│ - Validates event data (meter exists, timestamp valid)          │
│ - Enriches with customer/location data                          │
│ - Stores in MDM staging tables                                  │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 3: ETL PROCESS (Extract-Transform-Load)                    │
│ - Runs every 15-60 minutes                                      │
│ - Extracts new events from MDM staging                          │
│ - Transforms:                                                    │
│   * Lookup meter_sk from dim_meter                              │
│   * Lookup topology_bridge_sk (point-in-time)                   │
│   * Lookup event_type_sk from dim_event_type                    │
│   * Create time_sk from event_timestamp                         │
│   * Parse JSON payload into payload_data field                  │
│ - Loads into fact_end_device_event                              │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ STEP 4: DATA WAREHOUSE                                          │
│ - fact_end_device_event populated                               │
│ - Available for analytics, dashboards, outage maps              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Sample ETL SQL (Simplified)

```sql
-- ETL Job: Load Events from MDM to Data Warehouse
-- Runs every 15 minutes

INSERT INTO fact_end_device_event (
    event_sk,
    event_id,
    meter_sk,
    time_sk,
    event_type_sk,
    topology_bridge_sk,
    service_location_sk,
    event_type_code,
    severity_level,
    event_status,
    payload_data,
    event_timestamp,
    etl_batch_id
)
SELECT 
    -- Generate surrogate key
    NEXTVAL('event_sk_seq') as event_sk,
    
    -- Natural key from MDM
    stg.event_id,
    
    -- Lookup dimension keys
    dm.meter_sk,
    dt.time_sk,
    det.event_type_sk,
    
    -- Point-in-time topology lookup (CRITICAL!)
    btc.topology_bridge_sk,
    btc.service_location_sk,
    
    -- Event attributes
    stg.event_type_code,
    stg.severity_level,
    'Open' as event_status,  -- Initial status
    stg.payload_data::JSON,
    stg.event_timestamp,
    
    -- ETL tracking
    :batch_id as etl_batch_id

FROM mdm_staging.events stg

-- Join to meter dimension (current record)
INNER JOIN dim_meter dm 
    ON stg.meter_id = dm.meter_id 
    AND dm.is_current = TRUE

-- Join to time dimension
INNER JOIN dim_time dt 
    ON DATE_TRUNC('hour', stg.event_timestamp) = dt.timestamp_utc

-- Join to event type dimension
INNER JOIN dim_event_type det 
    ON stg.event_type_code = det.event_type_code

-- CRITICAL: Point-in-time topology join
INNER JOIN bridge_topology_connectivity btc
    ON dm.meter_id = btc.meter_id
    AND stg.event_timestamp >= btc.valid_from
    AND stg.event_timestamp < btc.valid_to
    AND btc.is_current = TRUE

-- Only load new events
WHERE stg.event_timestamp > (
    SELECT COALESCE(MAX(event_timestamp), '1900-01-01') 
    FROM fact_end_device_event
)
AND stg.processed_flag = FALSE;

-- Mark events as processed
UPDATE mdm_staging.events
SET processed_flag = TRUE,
    processed_timestamp = CURRENT_TIMESTAMP
WHERE processed_flag = FALSE;
```

---

## Common Use Cases

### Use Case 1: Outage Detection Dashboard
```sql
-- Active outages right now
SELECT 
    btc.feeder_id,
    btc.transformer_id,
    COUNT(DISTINCT f.meter_sk) as affected_meters,
    MIN(f.event_timestamp) as first_outage,
    MAX(f.event_timestamp) as last_outage,
    ROUND(AVG(EXTRACT(EPOCH FROM (NOW() - f.event_timestamp))/60), 1) as avg_minutes_out
FROM fact_end_device_event f
INNER JOIN bridge_topology_connectivity btc ON f.topology_bridge_sk = btc.topology_bridge_sk
INNER JOIN dim_event_type det ON f.event_type_sk = det.event_type_sk
WHERE det.event_category = 'Outage'
  AND f.event_status = 'Open'
  AND f.event_timestamp >= NOW() - INTERVAL '4 HOURS'
GROUP BY btc.feeder_id, btc.transformer_id
HAVING COUNT(DISTINCT f.meter_sk) >= 3  -- Cluster threshold
ORDER BY affected_meters DESC;
```

### Use Case 2: Tamper Investigation
```sql
-- All tamper events in last 30 days
SELECT 
    f.event_id,
    dm.meter_id,
    dm.asset_tag_number,
    dsl.address_line_1,
    dsl.city,
    f.event_type_code,
    f.event_timestamp,
    f.payload_data->>'tamper_type' as tamper_type,
    f.event_status
FROM fact_end_device_event f
INNER JOIN dim_meter dm ON f.meter_sk = dm.meter_sk AND dm.is_current = TRUE
INNER JOIN dim_service_location dsl ON f.service_location_sk = dsl.service_location_sk
INNER JOIN dim_event_type det ON f.event_type_sk = det.event_type_sk
WHERE det.event_category = 'Tamper'
  AND f.event_timestamp >= NOW() - INTERVAL '30 DAYS'
ORDER BY f.event_timestamp DESC;
```

---

## Summary

**Q: How does fact_end_device_event get data if all you get is AMI data?**

**A**: AMI systems send TWO types of data:
1. **Interval Readings** → `fact_interval_reading`
2. **Event Notifications** → `fact_end_device_event`

Both come from the same smart meters, transmitted through the same AMI Head-End system, but serve different analytical purposes. Events are critical for operations (outage management, tamper detection, asset health), while readings are for billing and load analysis.

**Event Volume**: Typical utility might see:
- Interval readings: 50 million/day
- Events: 100,000-500,000/day (depending on network health)

**Real-World Impact**: Without this bridge, you couldn't answer basic operational questions like "How much energy did this house consume last year?" when the meter was swapped mid-year.
