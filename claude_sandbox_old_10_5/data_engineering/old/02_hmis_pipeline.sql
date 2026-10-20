-- Lakeflow pipeline: synthetic HMIS clients + enrollments, bronze -> silver -> gold
--
-- Pipeline settings (set when you create the pipeline):
--   Default catalog / schema : the same ones you used in 01_setup_and_explore
--   Configuration            : landing_path = /Volumes/<catalog>/<schema>/landing
--   Compute                  : Serverless
--
-- Unqualified table names below resolve to the pipeline's default catalog and schema.
-- Databricks reads every statement, works out the dependency graph, and runs them in the right order.


-- =====================================================================
-- BRONZE: raw files in, exactly as delivered, plus lineage columns.
-- Auto Loader (read_files + STREAM) remembers which files it has already
-- loaded, so each run picks up only new files.
-- =====================================================================

CREATE OR REFRESH STREAMING TABLE bronze_clients
COMMENT 'Raw client CSV drops, as delivered'
AS SELECT
  *,
  _metadata.file_path AS source_file,
  current_timestamp() AS ingested_at
FROM STREAM read_files('${landing_path}/clients', format => 'csv', header => true);

CREATE OR REFRESH STREAMING TABLE bronze_enrollments
COMMENT 'Raw enrollment CSV drops, as delivered'
AS SELECT
  *,
  _metadata.file_path AS source_file,
  current_timestamp() AS ingested_at
FROM STREAM read_files('${landing_path}/enrollments', format => 'csv', header => true);


-- =====================================================================
-- SILVER, step 1: type, standardize, validate.
-- Expectations are data-quality rules. DROP ROW removes offenders;
-- no ON VIOLATION clause = keep the row but record the failure (warn).
-- Pass/fail counts appear in the pipeline UI and event log.
-- =====================================================================

CREATE OR REFRESH STREAMING TABLE clients_validated (
  CONSTRAINT has_id           EXPECT (client_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT plausible_birth  EXPECT (birth_year BETWEEN 1900 AND year(current_date()))
)
COMMENT 'Typed and validated client change events'
AS SELECT
  trim(client_id)                 AS client_id,
  CAST(birth_year AS INT)         AS birth_year,
  lower(trim(veteran_status))     AS veteran_status,
  CAST(updated_at AS TIMESTAMP)   AS updated_at
FROM STREAM(bronze_clients);

CREATE OR REFRESH STREAMING TABLE enrollments_validated (
  CONSTRAINT has_client   EXPECT (client_id IS NOT NULL)                        ON VIOLATION DROP ROW,
  CONSTRAINT valid_dates  EXPECT (exit_date IS NULL OR exit_date >= entry_date) ON VIOLATION DROP ROW,
  CONSTRAINT known_type   EXPECT (project_type IN ('ES', 'TH', 'RRH', 'PSH', 'SO'))
)
COMMENT 'Typed and validated enrollment change events'
AS SELECT
  trim(enrollment_id)             AS enrollment_id,
  trim(client_id)                 AS client_id,
  upper(trim(project_type))       AS project_type,
  CAST(entry_date AS DATE)        AS entry_date,
  CAST(exit_date AS DATE)         AS exit_date,
  lower(trim(exit_destination))   AS exit_destination,
  CAST(updated_at AS TIMESTAMP)   AS updated_at
FROM STREAM(bronze_enrollments);


-- =====================================================================
-- SILVER, step 2: apply changes with AUTO CDC.
-- Files contain *versions* of records. AUTO CDC keeps the right version per
-- key using SEQUENCE BY, even when versions arrive late or out of order.
--   SCD TYPE 1 = keep only the latest version (current state)
--   SCD TYPE 2 = keep every version with __START_AT / __END_AT (history)
-- =====================================================================

CREATE OR REFRESH STREAMING TABLE silver_enrollments
COMMENT 'One row per enrollment: its latest version';

CREATE FLOW silver_enrollments_cdc AS AUTO CDC INTO silver_enrollments
FROM STREAM(enrollments_validated)
KEYS (enrollment_id)
SEQUENCE BY updated_at
STORED AS SCD TYPE 1;

CREATE OR REFRESH STREAMING TABLE silver_clients_history
COMMENT 'Every version of every client; current row has __END_AT IS NULL';

CREATE FLOW silver_clients_cdc AS AUTO CDC INTO silver_clients_history
FROM STREAM(clients_validated)
KEYS (client_id)
SEQUENCE BY updated_at
STORED AS SCD TYPE 2;


-- =====================================================================
-- GOLD: business-ready answers. Materialized views are recomputed
-- (incrementally where possible) so they always reflect silver.
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW gold_active_by_project
COMMENT 'Clients currently enrolled, by project type'
AS SELECT
  e.project_type,
  count(DISTINCT e.client_id)                                               AS active_clients,
  count(DISTINCT CASE WHEN c.veteran_status = 'yes' THEN e.client_id END)   AS active_veterans
FROM silver_enrollments AS e
LEFT JOIN silver_clients_history AS c
  ON c.client_id = e.client_id AND c.__END_AT IS NULL
WHERE e.exit_date IS NULL
GROUP BY e.project_type;

CREATE OR REFRESH MATERIALIZED VIEW gold_exits_by_month
COMMENT 'Exits and share to permanent housing, by project type and exit month'
AS SELECT
  project_type,
  date_trunc('MONTH', exit_date)                                        AS exit_month,
  count(*)                                                              AS exits,
  round(avg(CASE WHEN exit_destination = 'permanent' THEN 1 ELSE 0 END), 2) AS share_to_permanent
FROM silver_enrollments
WHERE exit_date IS NOT NULL
GROUP BY ALL;
