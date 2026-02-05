# AMI Star Schema - Entity Catalog

## Complete List of 18 Entities

| # | Entity Name | Type | Description | Key Characteristics |
|---|-------------|------|-------------|---------------------|
| 1 | **FACT_INTERVAL_READING** | Fact (Transactional) | High-volume meter interval readings (15-min, 1-hour). Core fact table for consumption analytics. | Grain: One row per meter per interval. Contains kWh, kVARh, voltage, amps. Bi-temporal attributes for late-arriving corrections. Links to topology via `topology_bridge_sk`. |
| 2 | **FACT_END_DEVICE_EVENT** | Fact (Transactional) | Meter events for outage detection, tamper alerts, and communication failures. | Grain: One row per event. Tracks severity, status (Open/Acknowledged/Resolved), and diagnostic payload. Critical for outage management. |
| 3 | **FACT_TOPOLOGY_SNAPSHOT** | Fact (Periodic Snapshot) | Daily snapshot of grid topology state capturing "As-Operated" configuration. | Grain: One row per usage point per day. Captures switch states, energization status, and connectivity clusters. Enables As-Built vs. As-Operated analysis. |
| 4 | **FACT_METER_LIFECYCLE** | Fact (Accumulating Snapshot) | Tracks meter journey from manufacture through installation to retirement. | Grain: One row per meter (updated as milestones occur). Contains milestone dates and calculated durations (days in service, days to first reading). |
| 5 | **DIM_METER** | Dimension (SCD Type 2) | Smart meter device attributes and technical specifications. | Tracks meter hardware/firmware versions, communication modules, lifecycle status. Includes CIM EndDevice attributes (MAC, IP). SCD Type 2 for version tracking. |
| 6 | **DIM_USAGE_POINT** | Dimension (SCD Type 2) | Service point (meter socket) representing the point of consumption. | Links customer to grid via `connectivity_node_id`. Tracks service type, phase, voltage class, rate class. SCD Type 2 for customer/configuration changes. |
| 7 | **DIM_SERVICE_LOCATION** | Dimension (SCD Type 1) | Physical address and geographic coordinates of service locations. | Contains GIS attributes (lat/long, geohash, parcel ID). Includes property characteristics and hierarchical rollup attributes (census tract, region, county). |
| 8 | **DIM_TRANSFORMER** | Dimension (SCD Type 2) | Distribution transformers stepping down voltage for customer delivery. | Tracks kVA rating, voltage levels, phase configuration, GIS location. Denormalized hierarchy (contains `feeder_id`, `substation_id`). As-Built topology. |
| 9 | **DIM_FEEDER** | Dimension (SCD Type 2) | Medium-voltage distribution feeders emanating from substations. | Tracks voltage level (12kV, 25kV), rated capacity, operating status. Links to substation via denormalized `substation_id`. |
| 10 | **DIM_SUBSTATION** | Dimension (SCD Type 2) | Transmission-to-distribution substations. | High-level grid hierarchy. Tracks capacity, voltage levels (primary/secondary), geographic location, operating zone. |
| 11 | **BRIDGE_TOPOLOGY_CONNECTIVITY** | Bridge (Bi-Temporal SCD Type 2) | **CRITICAL**: Binds meters to grid topology at any point in time. Enables topology-addressable queries. | Contains both valid time (real-world) and transaction time (system recording). Tracks As-Built vs. As-Operated connectivity. Links usage points → transformers → feeders → substations. Pre-joined surrogate keys for performance. |
| 12 | **BRIDGE_METER_USAGE_POINT** | Bridge (SCD Type 2) | Tracks meter-to-service-point associations over time (handles meter swaps). | Temporal tracking of installations/removals. Links to work orders. Tracks installation/removal reasons (defective, upgrade, end-of-life). |
| 13 | **DIM_TIME** | Dimension (Type 1) | Date/time attributes for temporal analysis and rollups. | Pre-built calendar with fiscal periods, seasons, TOU (time-of-use) blocks, rate periods, holiday flags. Supports hourly/daily/monthly aggregations. |
| 14 | **DIM_READING_TYPE** | Dimension (Type 1) | Defines measurement types and units (kWh, kW, kVARh, Volts, Amps). | Tracks measurement kind, unit of measure, flow direction (forward/reverse), accumulation behavior (delta/cumulative), interval length. |
| 15 | **DIM_EVENT_TYPE** | Dimension (Type 1) | Event classification for device events (outages, tamper, communication). | Categories: Outage, Tamper, Communication, Hardware. Includes severity levels, SLA response times, escalation requirements. |
| 16 | **DIM_MANUFACTURER** | Dimension (Type 1) | Meter vendor/manufacturer information. | Tracks warranty periods, MTBF (mean time between failures), contact information. Used for quality analysis and vendor performance. |
| 17 | **REF_CONNECTIVITY_NODE** | Reference Table | GIS grid topology nodes (busbars, junctions, endpoints) from GIS/OMS systems. | Self-referencing hierarchy via `parent_node_id`. Synced from GIS (ArcGIS, Smallworld). Links to `dim_usage_point` via `connectivity_node_id`. |
| 18 | **REF_CONNECTIVITY_CLUSTER** | Reference Table | Pre-computed electrical islands (connectivity clusters) for performance optimization. | Represents all usage points sharing a common electrical source. Tracks total load, meter count per cluster. Updated when topology changes. Enables instant outage impact analysis. |

---

## Entity Summary by Type

### Fact Tables (4)
- **Transactional Facts (2)**: `FACT_INTERVAL_READING`, `FACT_END_DEVICE_EVENT`
- **Periodic Snapshot (1)**: `FACT_TOPOLOGY_SNAPSHOT`
- **Accumulating Snapshot (1)**: `FACT_METER_LIFECYCLE`

### Dimension Tables (10)
- **SCD Type 2 (6)**: `DIM_METER`, `DIM_USAGE_POINT`, `DIM_TRANSFORMER`, `DIM_FEEDER`, `DIM_SUBSTATION`, `BRIDGE_TOPOLOGY_CONNECTIVITY`
- **SCD Type 1 (4)**: `DIM_SERVICE_LOCATION`, `DIM_TIME`, `DIM_READING_TYPE`, `DIM_EVENT_TYPE`, `DIM_MANUFACTURER`

### Bridge Tables (2)
- **Topology Binding**: `BRIDGE_TOPOLOGY_CONNECTIVITY` (bi-temporal, critical for topology-addressable queries)
- **Meter Association**: `BRIDGE_METER_USAGE_POINT` (handles meter swaps)

### Reference Tables (2)
- **Grid Topology**: `REF_CONNECTIVITY_NODE` (GIS integration)
- **Performance Optimization**: `REF_CONNECTIVITY_CLUSTER` (pre-aggregated clusters)

---

## Key Relationships

### Star Schema Core
```
FACT_INTERVAL_READING
    ├── DIM_METER (meter_sk)
    ├── DIM_TIME (time_sk)
    ├── DIM_READING_TYPE (reading_type_sk)
    ├── BRIDGE_TOPOLOGY_CONNECTIVITY (topology_bridge_sk) ← CRITICAL
    └── DIM_SERVICE_LOCATION (service_location_sk)
```

### Topology Hierarchy (Denormalized in Dimensions)
```
DIM_SUBSTATION
    └── DIM_FEEDER (via feeder.substation_id)
        └── DIM_TRANSFORMER (via transformer.feeder_id)
            └── BRIDGE_TOPOLOGY_CONNECTIVITY
                └── DIM_USAGE_POINT
                    └── DIM_METER (via BRIDGE_METER_USAGE_POINT)
```

### Grid Integration (As-Built)
```
DIM_USAGE_POINT.connectivity_node_id
    └── REF_CONNECTIVITY_NODE.connectivity_node_id
        └── REF_CONNECTIVITY_NODE.parent_node_id (self-referencing hierarchy)
```

---

## Critical Design Notes

1. **`BRIDGE_TOPOLOGY_CONNECTIVITY` is the innovation** that makes this schema topology-addressable. It enables point-in-time joins between facts and grid hierarchy.

2. **Bi-Temporal Modeling**: Tracks both when changes occurred in reality (`valid_from`/`valid_to`) and when the system recorded them (`recorded_from`/`recorded_to`).

3. **SCD Type 2 Throughout**: All changing entities maintain full history via effective/expiration dates and version numbers.

4. **As-Built vs. As-Operated**: 
   - As-Built: Physical wiring stored in SCD Type 2 dimensions
   - As-Operated: Dynamic switch states captured in `FACT_TOPOLOGY_SNAPSHOT`

5. **GIS Integration**: Multiple GIS touchpoints (lat/long, geohash, gis_feature_id, gis_parcel_id) enable spatial analysis and synchronization with GIS systems.

6. **Performance Optimization**: 
   - Denormalized hierarchies in dimensions
   - Pre-computed connectivity clusters
   - Surrogate keys pre-joined in bridge table
   - Partitioning by time aligned between facts and bridges
# Models
