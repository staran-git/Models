-- ============================================================================
-- AMI ANALYTICS STAR SCHEMA - FULLY ATTRIBUTED ERD
-- Topology-Addressable, Bi-Temporal, SCD Type 2 Implementation
-- ============================================================================

-- ============================================================================
-- FACT TABLES
-- ============================================================================

-- Primary Fact: Interval Readings (High-Volume Grain)
CREATE TABLE fact_interval_reading (
    -- Surrogate Key
    interval_reading_sk BIGINT PRIMARY KEY,
    
    -- Natural Key (for idempotency)
    interval_id VARCHAR(50) UNIQUE NOT NULL,
    
    -- Dimension Foreign Keys
    meter_sk BIGINT NOT NULL,
    time_sk BIGINT NOT NULL,
    reading_type_sk INT NOT NULL,
    topology_bridge_sk BIGINT NOT NULL,  -- Critical: Point-in-Time Topology
    service_location_sk BIGINT NOT NULL,
    
    -- Degenerate Dimensions (high cardinality, not worth separate dimension)
    reading_id VARCHAR(50) NOT NULL,
    collection_timestamp TIMESTAMP NOT NULL,
    source_system VARCHAR(50),
    
    -- Measurements (Additive Facts)
    value_kwh DECIMAL(18,6),
    value_kvarh DECIMAL(18,6),
    value_volts DECIMAL(10,3),
    value_amps DECIMAL(10,3),
    
    -- Semi-Additive Facts
    min_voltage DECIMAL(10,3),
    max_voltage DECIMAL(10,3),
    avg_power_factor DECIMAL(5,4),
    
    -- Non-Additive Facts (States)
    quality_code VARCHAR(20),  -- Valid, Estimated, Suspect, Missing
    
    -- Temporal Attributes (Bi-Temporal Model)
    interval_start_time TIMESTAMP NOT NULL,
    interval_end_time TIMESTAMP NOT NULL,
    valid_from TIMESTAMP NOT NULL,      -- When this record became valid in reality
    valid_to TIMESTAMP NOT NULL,        -- When this record ceased to be valid
    recorded_at TIMESTAMP NOT NULL,     -- When system recorded this fact
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    etl_batch_id BIGINT,
    
    -- Indexes for Performance
    INDEX idx_meter_time (meter_sk, time_sk),
    INDEX idx_topology_time (topology_bridge_sk, time_sk),
    INDEX idx_interval_times (interval_start_time, interval_end_time),
    INDEX idx_bitemporal (valid_from, valid_to, recorded_at)
);

-- Fact: Meter Events (Critical for Outage & Tamper)
CREATE TABLE fact_end_device_event (
    -- Surrogate Key
    event_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    event_id VARCHAR(50) UNIQUE NOT NULL,
    
    -- Dimension Foreign Keys
    meter_sk BIGINT NOT NULL,
    time_sk BIGINT NOT NULL,
    event_type_sk INT NOT NULL,
    topology_bridge_sk BIGINT NOT NULL,  -- Where was meter connected when event occurred
    service_location_sk BIGINT NOT NULL,
    
    -- Event Attributes
    event_type_code VARCHAR(50) NOT NULL,
    severity_level VARCHAR(20),  -- Critical, Warning, Info
    event_status VARCHAR(20),    -- Open, Acknowledged, Resolved
    payload_data JSON,           -- Diagnostic details
    
    -- Temporal Attributes
    event_timestamp TIMESTAMP NOT NULL,
    acknowledgment_timestamp TIMESTAMP,
    resolution_timestamp TIMESTAMP,
    
    -- Duration Calculation (Derived)
    duration_seconds INT,
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    etl_batch_id BIGINT,
    
    INDEX idx_meter_event (meter_sk, event_timestamp),
    INDEX idx_event_type_time (event_type_sk, time_sk),
    INDEX idx_event_status (event_status, severity_level)
);

-- Periodic Snapshot Fact: Daily Topology State (As-Operated)
CREATE TABLE fact_topology_snapshot (
    -- Composite Key
    snapshot_sk BIGINT PRIMARY KEY,
    
    -- Dimension Foreign Keys
    usage_point_sk BIGINT NOT NULL,
    transformer_sk BIGINT NOT NULL,
    feeder_sk BIGINT NOT NULL,
    substation_sk BIGINT NOT NULL,
    time_sk BIGINT NOT NULL,
    
    -- Snapshot Attributes
    snapshot_timestamp TIMESTAMP NOT NULL,
    phase_configuration VARCHAR(10),  -- A, B, C, AB, ABC
    nominal_voltage DECIMAL(10,3),
    
    -- Switch States (As-Operated)
    upstream_switch_state VARCHAR(20),    -- Open, Closed
    downstream_switch_state VARCHAR(20),
    is_energized BOOLEAN,
    
    -- Connectivity Cluster
    connectivity_cluster_id VARCHAR(50),  -- Electrical Island ID
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    etl_batch_id BIGINT,
    
    INDEX idx_usage_point_time (usage_point_sk, time_sk),
    INDEX idx_feeder_snapshot (feeder_sk, snapshot_timestamp),
    INDEX idx_cluster (connectivity_cluster_id)
);

-- Accumulating Snapshot Fact: Meter Lifecycle
CREATE TABLE fact_meter_lifecycle (
    -- Surrogate Key
    lifecycle_sk BIGINT PRIMARY KEY,
    
    -- Dimension Foreign Keys
    meter_sk BIGINT NOT NULL,
    manufacturer_sk INT NOT NULL,
    initial_location_sk BIGINT,
    current_location_sk BIGINT,
    
    -- Milestone Timestamps
    manufacture_date DATE,
    received_date DATE,
    tested_date DATE,
    installed_date DATE,
    first_reading_date DATE,
    last_reading_date DATE,
    removed_date DATE,
    retired_date DATE,
    
    -- Duration Metrics (Days)
    days_in_inventory INT,
    days_in_service INT,
    days_to_first_reading INT,
    
    -- Status
    current_lifecycle_status VARCHAR(50),
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_meter (meter_sk),
    INDEX idx_lifecycle_status (current_lifecycle_status)
);

-- ============================================================================
-- CORE DIMENSION TABLES
-- ============================================================================

-- Dimension: Meter (SCD Type 2)
CREATE TABLE dim_meter (
    -- Surrogate Key
    meter_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    meter_id VARCHAR(50) NOT NULL,
    asset_tag_number VARCHAR(50) UNIQUE NOT NULL,
    
    -- Type 2 SCD Attributes
    effective_date DATE NOT NULL,
    expiration_date DATE NOT NULL,
    is_current BOOLEAN NOT NULL,
    version_number INT NOT NULL,
    
    -- Meter Attributes
    manufacturer_id VARCHAR(50),
    hardware_version VARCHAR(50),
    firmware_version VARCHAR(50),
    meter_type VARCHAR(50),  -- Residential, Commercial, Industrial
    communication_module_type VARCHAR(50),  -- RF Mesh, PLC, Cellular
    form_factor VARCHAR(10),  -- 2S, 12S
    seal_number VARCHAR(50),
    
    -- Technical Specs
    rated_voltage DECIMAL(10,3),
    rated_amperage DECIMAL(10,3),
    accuracy_class VARCHAR(10),
    
    -- EndDevice Attributes (CIM)
    device_category VARCHAR(50),  -- Smart Meter, Gatekeeper, Repeater
    is_gateway BOOLEAN,
    mac_address VARCHAR(17),
    ip_address VARCHAR(45),
    last_ping_timestamp TIMESTAMP,
    
    -- Lifecycle
    manufacture_date DATE,
    installation_date DATE,
    removal_date DATE,
    life_cycle_status VARCHAR(50),  -- In-Stock, Installed, Retired, Defective
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    source_system VARCHAR(50),
    
    -- Indexes
    INDEX idx_meter_natural (meter_id, is_current),
    INDEX idx_asset_tag (asset_tag_number),
    INDEX idx_lifecycle_status (life_cycle_status),
    INDEX idx_effective_dates (effective_date, expiration_date)
);

-- Dimension: Service Location (SCD Type 1 - Address changes are rare)
CREATE TABLE dim_service_location (
    -- Surrogate Key
    service_location_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    location_id VARCHAR(50) UNIQUE NOT NULL,
    
    -- Address Attributes
    address_line_1 VARCHAR(200),
    address_line_2 VARCHAR(200),
    city VARCHAR(100),
    state VARCHAR(50),
    postal_code VARCHAR(20),
    country VARCHAR(50),
    
    -- Geographic Attributes
    latitude DECIMAL(10,8),
    longitude DECIMAL(11,8),
    geohash VARCHAR(20),  -- For spatial indexing
    
    -- GIS Integration
    gis_parcel_id VARCHAR(50),
    gis_updated_at TIMESTAMP,
    
    -- Property Attributes
    premise_type VARCHAR(50),  -- Single Family, Multi-Unit, Commercial
    building_type VARCHAR(50),
    square_footage INT,
    year_built INT,
    
    -- Hierarchy (For Rollup)
    census_tract VARCHAR(20),
    zip_code_extension VARCHAR(10),
    municipality VARCHAR(100),
    county VARCHAR(100),
    region VARCHAR(50),
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_geo (latitude, longitude),
    INDEX idx_geohash (geohash),
    INDEX idx_region (region, municipality)
);

-- Dimension: Usage Point (The Service Point - SCD Type 2)
CREATE TABLE dim_usage_point (
    -- Surrogate Key
    usage_point_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    usage_point_id VARCHAR(50) NOT NULL,
    
    -- Type 2 SCD Attributes
    effective_date DATE NOT NULL,
    expiration_date DATE NOT NULL,
    is_current BOOLEAN NOT NULL,
    version_number INT NOT NULL,
    
    -- Service Attributes
    service_type VARCHAR(50),  -- Electric, Gas, Water
    phase_code VARCHAR(10),    -- A, B, C, ABC
    nominal_voltage DECIMAL(10,3),
    load_class VARCHAR(50),    -- Residential, Industrial
    
    -- Customer Association
    customer_account_id VARCHAR(50),
    rate_class VARCHAR(50),
    
    -- Grid Connection (Static - As-Built)
    connectivity_node_id VARCHAR(50),  -- Link to GIS/Grid Topology
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_usage_point_natural (usage_point_id, is_current),
    INDEX idx_effective_dates (effective_date, expiration_date),
    INDEX idx_connectivity_node (connectivity_node_id)
);

-- ============================================================================
-- TOPOLOGY DIMENSIONS (Grid Hierarchy)
-- ============================================================================

-- Dimension: Transformer (SCD Type 2)
CREATE TABLE dim_transformer (
    -- Surrogate Key
    transformer_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    transformer_id VARCHAR(50) NOT NULL,
    
    -- Type 2 SCD Attributes
    effective_date DATE NOT NULL,
    expiration_date DATE NOT NULL,
    is_current BOOLEAN NOT NULL,
    version_number INT NOT NULL,
    
    -- Transformer Attributes
    transformer_name VARCHAR(100),
    kva_rating DECIMAL(10,2),
    primary_voltage DECIMAL(10,3),
    secondary_voltage DECIMAL(10,3),
    phase_configuration VARCHAR(10),
    
    -- Location
    latitude DECIMAL(10,8),
    longitude DECIMAL(11,8),
    installation_date DATE,
    
    -- Hierarchy (As-Built)
    feeder_id VARCHAR(50),
    substation_id VARCHAR(50),
    
    -- GIS Integration
    gis_feature_id VARCHAR(50),
    gis_updated_at TIMESTAMP,
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_transformer_natural (transformer_id, is_current),
    INDEX idx_feeder (feeder_id),
    INDEX idx_effective_dates (effective_date, expiration_date)
);

-- Dimension: Feeder (SCD Type 2)
CREATE TABLE dim_feeder (
    -- Surrogate Key
    feeder_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    feeder_id VARCHAR(50) NOT NULL,
    
    -- Type 2 SCD Attributes
    effective_date DATE NOT NULL,
    expiration_date DATE NOT NULL,
    is_current BOOLEAN NOT NULL,
    version_number INT NOT NULL,
    
    -- Feeder Attributes
    feeder_name VARCHAR(100),
    feeder_number VARCHAR(20),
    voltage_level VARCHAR(20),  -- 12kV, 25kV
    rated_capacity_mva DECIMAL(10,2),
    
    -- Hierarchy
    substation_id VARCHAR(50),
    region VARCHAR(50),
    
    -- Operational
    operating_status VARCHAR(50),  -- In-Service, Out-of-Service, Maintenance
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_feeder_natural (feeder_id, is_current),
    INDEX idx_substation (substation_id),
    INDEX idx_effective_dates (effective_date, expiration_date)
);

-- Dimension: Substation (SCD Type 2)
CREATE TABLE dim_substation (
    -- Surrogate Key
    substation_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    substation_id VARCHAR(50) NOT NULL,
    
    -- Type 2 SCD Attributes
    effective_date DATE NOT NULL,
    expiration_date DATE NOT NULL,
    is_current BOOLEAN NOT NULL,
    version_number INT NOT NULL,
    
    -- Substation Attributes
    substation_name VARCHAR(100),
    voltage_level_primary VARCHAR(20),
    voltage_level_secondary VARCHAR(20),
    total_capacity_mva DECIMAL(10,2),
    
    -- Location
    address VARCHAR(200),
    latitude DECIMAL(10,8),
    longitude DECIMAL(11,8),
    
    -- Hierarchy
    region VARCHAR(50),
    operating_zone VARCHAR(50),
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_substation_natural (substation_id, is_current),
    INDEX idx_region (region),
    INDEX idx_effective_dates (effective_date, expiration_date)
);

-- ============================================================================
-- BRIDGE/ASSOCIATION TABLES (Topology Binding)
-- ============================================================================

-- Bridge: Topology Connectivity (Bi-Temporal SCD Type 2)
-- This is the CRITICAL table for topology-addressable queries
CREATE TABLE bridge_topology_connectivity (
    -- Surrogate Key
    topology_bridge_sk BIGINT PRIMARY KEY,
    
    -- Entity Keys
    usage_point_id VARCHAR(50) NOT NULL,
    meter_id VARCHAR(50) NOT NULL,
    transformer_id VARCHAR(50) NOT NULL,
    feeder_id VARCHAR(50) NOT NULL,
    substation_id VARCHAR(50) NOT NULL,
    
    -- Dimension Surrogate Keys (for fast joins)
    usage_point_sk BIGINT NOT NULL,
    meter_sk BIGINT NOT NULL,
    transformer_sk BIGINT NOT NULL,
    feeder_sk BIGINT NOT NULL,
    substation_sk BIGINT NOT NULL,
    service_location_sk BIGINT NOT NULL,
    
    -- Bi-Temporal Attributes
    -- Valid Time (Real-World Validity)
    valid_from TIMESTAMP NOT NULL,
    valid_to TIMESTAMP NOT NULL DEFAULT '9999-12-31 23:59:59',
    
    -- Transaction Time (System Recording)
    recorded_from TIMESTAMP NOT NULL,
    recorded_to TIMESTAMP NOT NULL DEFAULT '9999-12-31 23:59:59',
    
    -- Current Flag
    is_current BOOLEAN NOT NULL,
    
    -- Connectivity Type
    connectivity_type VARCHAR(50),  -- As-Built, As-Operated, Planned
    
    -- Connectivity Attributes
    phase_connection VARCHAR(10),  -- A, B, C, AB, BC, CA, ABC
    service_voltage DECIMAL(10,3),
    connectivity_cluster_id VARCHAR(50),  -- Electrical Island
    
    -- Change Tracking
    change_reason VARCHAR(200),  -- Work Order, Switch Operation, Emergency
    work_order_id VARCHAR(50),
    scada_event_id VARCHAR(50),
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    source_system VARCHAR(50),
    
    -- Critical Indexes for Point-in-Time Queries
    INDEX idx_usage_point_temporal (usage_point_id, valid_from, valid_to),
    INDEX idx_meter_temporal (meter_id, valid_from, valid_to),
    INDEX idx_transformer_temporal (transformer_id, valid_from, valid_to),
    INDEX idx_feeder_temporal (feeder_id, valid_from, valid_to),
    INDEX idx_bitemporal (valid_from, valid_to, recorded_from, recorded_to),
    INDEX idx_current (is_current, connectivity_type),
    INDEX idx_cluster (connectivity_cluster_id)
);

-- Bridge: Meter-to-UsagePoint (Handles Meter Swaps)
CREATE TABLE bridge_meter_usage_point (
    -- Surrogate Key
    meter_usage_point_sk BIGINT PRIMARY KEY,
    
    -- Foreign Keys
    meter_sk BIGINT NOT NULL,
    usage_point_sk BIGINT NOT NULL,
    
    -- Natural Keys
    meter_id VARCHAR(50) NOT NULL,
    usage_point_id VARCHAR(50) NOT NULL,
    
    -- Temporal Attributes
    valid_from TIMESTAMP NOT NULL,
    valid_to TIMESTAMP NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current BOOLEAN NOT NULL,
    
    -- Association Attributes
    installation_reason VARCHAR(100),  -- New Install, Replacement, Upgrade
    removal_reason VARCHAR(100),       -- Defective, End-of-Life, Customer Request
    installed_by VARCHAR(100),
    
    -- Work Order Reference
    installation_work_order_id VARCHAR(50),
    removal_work_order_id VARCHAR(50),
    
    -- Audit Columns
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_meter_temporal (meter_id, valid_from, valid_to),
    INDEX idx_usage_point_temporal (usage_point_id, valid_from, valid_to),
    INDEX idx_current (is_current)
);

-- ============================================================================
-- SUPPORTING DIMENSIONS
-- ============================================================================

-- Dimension: Time (Critical for temporal queries)
CREATE TABLE dim_time (
    -- Surrogate Key
    time_sk BIGINT PRIMARY KEY,
    
    -- Natural Key
    timestamp_utc TIMESTAMP UNIQUE NOT NULL,
    
    -- Date Components
    date DATE NOT NULL,
    year INT NOT NULL,
    quarter INT NOT NULL,
    month INT NOT NULL,
    day_of_month INT NOT NULL,
    day_of_week INT NOT NULL,  -- 1=Monday
    day_of_year INT NOT NULL,
    
    -- Time Components
    hour INT NOT NULL,
    minute INT NOT NULL,
    second INT NOT NULL,
    
    -- Business Attributes
    is_weekend BOOLEAN,
    is_holiday BOOLEAN,
    holiday_name VARCHAR(100),
    
    -- Utility-Specific
    season VARCHAR(20),  -- Summer, Winter, Spring, Fall
    rate_period VARCHAR(20),  -- On-Peak, Off-Peak, Mid-Peak
    time_of_use_block VARCHAR(20),
    
    -- Fiscal Period
    fiscal_year INT,
    fiscal_quarter INT,
    fiscal_month INT,
    
    INDEX idx_date (date),
    INDEX idx_year_month (year, month),
    INDEX idx_hour (hour)
);

-- Dimension: Reading Type
CREATE TABLE dim_reading_type (
    -- Surrogate Key
    reading_type_sk INT PRIMARY KEY,
    
    -- Natural Key
    reading_type_id VARCHAR(50) UNIQUE NOT NULL,
    
    -- Reading Attributes
    reading_type_name VARCHAR(100),
    measurement_kind VARCHAR(50),  -- Energy, Power, Voltage, Current
    unit_of_measure VARCHAR(20),   -- kWh, kW, kVARh, kVAR, V, A
    
    -- Measurement Details
    multiplier DECIMAL(10,6),
    flow_direction VARCHAR(20),    -- Forward, Reverse, Net
    phase VARCHAR(10),              -- Total, A, B, C
    
    -- Accumulation
    accumulation_behavior VARCHAR(50),  -- Delta, Cumulative, Instantaneous
    
    -- Interval
    interval_length_minutes INT,
    
    INDEX idx_measurement_kind (measurement_kind),
    INDEX idx_unit (unit_of_measure)
);

-- Dimension: Event Type
CREATE TABLE dim_event_type (
    -- Surrogate Key
    event_type_sk INT PRIMARY KEY,
    
    -- Natural Key
    event_type_code VARCHAR(50) UNIQUE NOT NULL,
    
    -- Event Attributes
    event_type_name VARCHAR(100),
    event_category VARCHAR(50),  -- Outage, Tamper, Communication, Hardware
    severity_level VARCHAR(20),  -- Critical, Warning, Info
    
    -- Response SLA
    response_time_minutes INT,
    escalation_required BOOLEAN,
    
    -- Description
    event_description TEXT,
    
    INDEX idx_category (event_category),
    INDEX idx_severity (severity_level)
);

-- Dimension: Manufacturer
CREATE TABLE dim_manufacturer (
    -- Surrogate Key
    manufacturer_sk INT PRIMARY KEY,
    
    -- Natural Key
    manufacturer_id VARCHAR(50) UNIQUE NOT NULL,
    
    -- Manufacturer Attributes
    manufacturer_name VARCHAR(100),
    manufacturer_code VARCHAR(20),
    country VARCHAR(50),
    
    -- Contact
    website VARCHAR(200),
    support_email VARCHAR(100),
    support_phone VARCHAR(50),
    
    -- Quality Metrics
    warranty_period_months INT,
    average_mtbf_hours INT,  -- Mean Time Between Failures
    
    INDEX idx_name (manufacturer_name)
);

-- ============================================================================
-- REFERENCE/LOOKUP TABLES
-- ============================================================================

-- Reference: Connectivity Node (GIS Grid Topology)
CREATE TABLE ref_connectivity_node (
    connectivity_node_id VARCHAR(50) PRIMARY KEY,
    node_name VARCHAR(100),
    node_type VARCHAR(50),  -- Busbar, Junction, Endpoint
    
    -- Grid Location
    latitude DECIMAL(10,8),
    longitude DECIMAL(11,8),
    
    -- Electrical Attributes
    nominal_voltage DECIMAL(10,3),
    
    -- Topology
    parent_node_id VARCHAR(50),
    
    -- GIS Integration
    gis_feature_id VARCHAR(50),
    gis_layer VARCHAR(50),
    gis_updated_at TIMESTAMP,
    
    INDEX idx_node_type (node_type),
    INDEX idx_parent (parent_node_id)
);

-- Reference: Connectivity Cluster (Electrical Islands)
CREATE TABLE ref_connectivity_cluster (
    connectivity_cluster_id VARCHAR(50) PRIMARY KEY,
    cluster_name VARCHAR(100),
    
    -- Cluster Attributes
    total_usage_points INT,
    total_load_kw DECIMAL(12,2),
    
    -- Primary Source
    primary_transformer_id VARCHAR(50),
    primary_feeder_id VARCHAR(50),
    primary_substation_id VARCHAR(50),
    
    -- Status
    is_energized BOOLEAN,
    last_updated TIMESTAMP,
    
    INDEX idx_feeder (primary_feeder_id),
    INDEX idx_energized (is_energized)
);

-- ============================================================================
-- AUDIT AND ETL TRACKING
-- ============================================================================

-- ETL Batch Tracking
CREATE TABLE etl_batch_log (
    etl_batch_id BIGINT PRIMARY KEY,
    batch_name VARCHAR(100),
    start_timestamp TIMESTAMP,
    end_timestamp TIMESTAMP,
    status VARCHAR(50),  -- Running, Success, Failed
    records_processed BIGINT,
    records_inserted BIGINT,
    records_updated BIGINT,
    records_failed BIGINT,
    error_message TEXT,
    source_system VARCHAR(50)
);

-- ============================================================================
-- SAMPLE QUERIES FOR VALIDATION
-- ============================================================================

/*
-- Query 1: Point-in-Time Load on Transformer (Topology-Addressable)
SELECT 
    dt.transformer_name,
    df.feeder_name,
    ds.substation_name,
    SUM(fir.value_kwh) as total_load_kwh,
    COUNT(DISTINCT fir.meter_sk) as meter_count
FROM fact_interval_reading fir
INNER JOIN bridge_topology_connectivity btc
    ON fir.topology_bridge_sk = btc.topology_bridge_sk
    AND fir.interval_start_time >= btc.valid_from 
    AND fir.interval_start_time < btc.valid_to
INNER JOIN dim_transformer dt ON btc.transformer_sk = dt.transformer_sk AND dt.is_current = TRUE
INNER JOIN dim_feeder df ON btc.feeder_sk = df.feeder_sk AND df.is_current = TRUE
INNER JOIN dim_substation ds ON btc.substation_sk = ds.substation_sk AND ds.is_current = TRUE
WHERE btc.transformer_id = 'TRFR_1234'
  AND fir.interval_start_time BETWEEN '2024-10-27 00:00:00' AND '2024-10-27 23:59:59'
GROUP BY dt.transformer_name, df.feeder_name, ds.substation_name;

-- Query 2: Bi-Temporal Audit - Show Topology History for a Meter
SELECT 
    btc.meter_id,
    btc.transformer_id,
    btc.feeder_id,
    btc.valid_from,
    btc.valid_to,
    btc.recorded_from,
    btc.recorded_to,
    btc.change_reason,
    btc.connectivity_type
FROM bridge_topology_connectivity btc
WHERE btc.meter_id = 'MTR_98765'
ORDER BY btc.valid_from DESC;

-- Query 3: As-Built vs As-Operated (Current Snapshot)
SELECT 
    fts.usage_point_sk,
    fts.transformer_sk,
    fts.is_energized,
    fts.connectivity_cluster_id,
    btc.transformer_id as built_transformer,
    btc.connectivity_type
FROM fact_topology_snapshot fts
LEFT JOIN bridge_topology_connectivity btc
    ON fts.usage_point_sk = btc.usage_point_sk
    AND fts.snapshot_timestamp BETWEEN btc.valid_from AND btc.valid_to
    AND btc.connectivity_type = 'As-Built'
WHERE fts.snapshot_timestamp = (SELECT MAX(snapshot_timestamp) FROM fact_topology_snapshot)
  AND fts.transformer_sk != btc.transformer_sk;  -- Deviations from as-built

-- Query 4: Outage Impact Analysis (Topology-Aware)
SELECT 
    btc.feeder_id,
    btc.connectivity_cluster_id,
    COUNT(DISTINCT fede.meter_sk) as affected_meters,
    MIN(fede.event_timestamp) as first_outage,
    MAX(fede.event_timestamp) as last_outage
FROM fact_end_device_event fede
INNER JOIN bridge_topology_connectivity btc
    ON fede.meter_sk = btc.meter_sk
    AND fede.event_timestamp >= btc.valid_from
    AND fede.event_timestamp < btc.valid_to
INNER JOIN dim_event_type det ON fede.event_type_sk = det.event_type_sk
WHERE det.event_category = 'Outage'
  AND fede.event_timestamp >= NOW() - INTERVAL '24 HOURS'
GROUP BY btc.feeder_id, btc.connectivity_cluster_id
HAVING COUNT(DISTINCT fede.meter_sk) > 10;  -- Cluster outage threshold

-- Query 5: Meter Swap History (SCD Type 2)
SELECT 
    dm.meter_id,
    dm.asset_tag_number,
    dup.usage_point_id,
    bmup.valid_from as installed_date,
    bmup.valid_to as removed_date,
    bmup.installation_reason,
    bmup.removal_reason,
    DATEDIFF(DAY, bmup.valid_from, bmup.valid_to) as days_installed
FROM bridge_meter_usage_point bmup
INNER JOIN dim_meter dm ON bmup.meter_sk = dm.meter_sk
INNER JOIN dim_usage_point dup ON bmup.usage_point_sk = dup.usage_point_sk
WHERE bmup.usage_point_id = 'UP_12345'
ORDER BY bmup.valid_from DESC;
*/

-- ============================================================================
-- PARTITIONING STRATEGY (Example for Snowflake/BigQuery)
-- ============================================================================

/*
-- Partition fact_interval_reading by interval_start_time (Monthly)
-- This aligns with both fact grain and topology valid_from partitioning

ALTER TABLE fact_interval_reading 
PARTITION BY RANGE(MONTH(interval_start_time));

-- Partition bridge_topology_connectivity by valid_from (Monthly)
ALTER TABLE bridge_topology_connectivity
PARTITION BY RANGE(MONTH(valid_from));

-- Clustering Keys (Snowflake)
ALTER TABLE fact_interval_reading 
CLUSTER BY (topology_bridge_sk, time_sk, meter_sk);

ALTER TABLE bridge_topology_connectivity
CLUSTER BY (usage_point_id, valid_from, is_current);
*/

-- ============================================================================
-- MATERIALIZED VIEWS FOR PERFORMANCE
-- ============================================================================

/*
-- Materialized View: Hourly Transformer Load Summary
CREATE MATERIALIZED VIEW mv_hourly_transformer_load AS
SELECT 
    btc.transformer_id,
    btc.feeder_id,
    btc.substation_id,
    dt.date,
    dt.hour,
    SUM(fir.value_kwh) as total_kwh,
    SUM(fir.value_kvarh) as total_kvarh,
    AVG(fir.value_volts) as avg_voltage,
    COUNT(DISTINCT fir.meter_sk) as meter_count,
    MIN(fir.min_voltage) as min_voltage,
    MAX(fir.max_voltage) as max_voltage
FROM fact_interval_reading fir
INNER JOIN bridge_topology_connectivity btc
    ON fir.topology_bridge_sk = btc.topology_bridge_sk
INNER JOIN dim_time dt ON fir.time_sk = dt.time_sk
GROUP BY btc.transformer_id, btc.feeder_id, btc.substation_id, dt.date, dt.hour;

-- Refresh Strategy: Incremental every 15 minutes
*/
