-- =====================================================================
-- PARITY CHECK: prove the pipeline reproduces your current tables.
--
-- A refactor should change how the code is organised, not what it
-- outputs. This script compares the tables the pipeline builds with
-- copies of the tables your hand-run scripts built.
--
-- STEP 1 (once, in DEV, on the SAME DAY as step 3, because gold depends
--         on current_date): snapshot the current tables.
-- STEP 2: drop the three original tables (a pipeline cannot take over a
--         table that a CREATE TABLE AS script made) and run the pipeline.
-- STEP 3: run the comparison queries. Every "diff_rows" must be 0.
-- =====================================================================

-- ---------- STEP 1: snapshot the current tables ----------
CREATE OR REPLACE TABLE example_catalog.silver.program_county_lookup_baseline
  DEEP CLONE example_catalog.silver.program_county_lookup;
CREATE OR REPLACE TABLE example_catalog.silver.snapshot_dashboard_baseline
  DEEP CLONE example_catalog.silver.snapshot_dashboard;
CREATE OR REPLACE TABLE example_catalog.gold.snapshot_dashboard_baseline
  DEEP CLONE example_catalog.gold.snapshot_dashboard;

-- ---------- STEP 2: drop originals, then run the pipeline ----------
-- DROP TABLE example_catalog.silver.program_county_lookup;
-- DROP TABLE example_catalog.silver.snapshot_dashboard;
-- DROP TABLE example_catalog.gold.snapshot_dashboard;

-- ---------- STEP 3: compare ----------
-- EXCEPT ALL compares rows as a multiset, in both directions.
-- Excluded on purpose: _processed_timestamp (differs every run) and
-- n_counties_named (new audit column, last in the lookup).

-- 3a. Row counts
SELECT 'lookup'  AS tbl,
       (SELECT count(*) FROM example_catalog.silver.program_county_lookup_baseline) AS baseline_rows,
       (SELECT count(*) FROM example_catalog.silver.program_county_lookup)          AS new_rows
UNION ALL
SELECT 'silver',
       (SELECT count(*) FROM example_catalog.silver.snapshot_dashboard_baseline),
       (SELECT count(*) FROM example_catalog.silver.snapshot_dashboard)
UNION ALL
SELECT 'gold',
       (SELECT count(*) FROM example_catalog.gold.snapshot_dashboard_baseline),
       (SELECT count(*) FROM example_catalog.gold.snapshot_dashboard);

-- 3b. Rows in the baseline that the new table lacks, and the reverse.
SELECT 'lookup: in baseline, not in new' AS test, count(*) AS diff_rows FROM (
  SELECT * FROM example_catalog.silver.program_county_lookup_baseline
  EXCEPT ALL
  SELECT * EXCEPT (n_counties_named) FROM example_catalog.silver.program_county_lookup)
UNION ALL
SELECT 'lookup: in new, not in baseline', count(*) FROM (
  SELECT * EXCEPT (n_counties_named) FROM example_catalog.silver.program_county_lookup
  EXCEPT ALL
  SELECT * FROM example_catalog.silver.program_county_lookup_baseline)
UNION ALL
SELECT 'silver: in baseline, not in new', count(*) FROM (
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.silver.snapshot_dashboard_baseline
  EXCEPT ALL
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.silver.snapshot_dashboard)
UNION ALL
SELECT 'silver: in new, not in baseline', count(*) FROM (
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.silver.snapshot_dashboard
  EXCEPT ALL
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.silver.snapshot_dashboard_baseline)
UNION ALL
SELECT 'gold: in baseline, not in new', count(*) FROM (
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.gold.snapshot_dashboard_baseline
  EXCEPT ALL
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.gold.snapshot_dashboard)
UNION ALL
SELECT 'gold: in new, not in baseline', count(*) FROM (
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.gold.snapshot_dashboard
  EXCEPT ALL
  SELECT * EXCEPT (_processed_timestamp) FROM example_catalog.gold.snapshot_dashboard_baseline);

-- 3c. Column types. A silent INT -> BIGINT change can break a Power BI model.
SELECT b.col_name, b.data_type AS baseline_type, n.data_type AS new_type
FROM (DESCRIBE TABLE example_catalog.gold.snapshot_dashboard_baseline) AS b
FULL OUTER JOIN (DESCRIBE TABLE example_catalog.gold.snapshot_dashboard) AS n
  ON b.col_name = n.col_name
WHERE b.data_type IS DISTINCT FROM n.data_type;

-- 3d. If 3b shows gold differences, localise them by month.
SELECT coalesce(b.month_start, n.month_start) AS month_start,
       b.people AS baseline_people, n.people AS new_people
FROM (SELECT month_start, sum(homeless_count) AS people
      FROM example_catalog.gold.snapshot_dashboard_baseline GROUP BY month_start) AS b
FULL OUTER JOIN (SELECT month_start, sum(homeless_count) AS people
      FROM example_catalog.gold.snapshot_dashboard GROUP BY month_start) AS n
  ON b.month_start = n.month_start
WHERE b.people IS DISTINCT FROM n.people
ORDER BY month_start;
