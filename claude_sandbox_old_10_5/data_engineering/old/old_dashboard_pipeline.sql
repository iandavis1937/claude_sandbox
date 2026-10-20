-- =====================================================================
-- HMIS dashboard pipeline (Lakeflow declarative pipeline, SQL)
-- Replaces: make_program_county_lookup.sql, make_dashboard_silver.sql,
--           make_dashboard_gold.sql (run by hand, in order)
--
-- Pipeline settings:
--   Default catalog : example_catalog in dev, the prod catalog in prod
--                     (set per target in the bundle, never in this file)
--   Compute         : Serverless
--   Schedule        : a Lakeflow Job that triggers this pipeline
--
-- Two-part names (schema.table) resolve against the default catalog, so
-- the same file runs unchanged in dev and prod. Databricks works out the
-- run order from the table references; there is no "run this first".
--
-- Reads (existing tables, not owned by this pipeline):
--   silver.admissions_enriched, silver.households,
--   bronze.homeless_causes, reference.county_population_mapping
-- =====================================================================


-- =====================================================================
-- REFERENCE: hand-maintained county assignments.
-- Human judgement lives in data, in version control, with its evidence,
-- not in CASE statements buried in a query. Add a row, open a PR.
--
-- Pending (no evidence yet, so deliberately absent => 'unresolved'):
--   BVH Region 3 (Community Hope), BVH Region 5 (Soldier On)
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.program_county_overrides
COMMENT 'Manual program_county assignments with evidence. Edit via PR.'
AS SELECT * FROM VALUES
  ('cspnj',             'OHP - BVH%', 'Hudson',    'BVH Region 1: dominant county of 1,083 county-tagged OHP rows'),
  ('Garden State Home', 'OHP - BVH%', 'Middlesex', 'BVH Region 4: dominant county of 870 county-tagged OHP rows')
AS t(organization_name, project_name_like, program_county, evidence);


-- =====================================================================
-- SILVER: county lookup. One row per (project_name, organization_name).
-- Strategies in priority order:
--   1. exact_project_org             the pair reports exactly one county elsewhere
--   2. explicit_name_parse           exactly one NJ county named in the text
--   3. organization_history_inferred the org reports exactly one county
--   4. manual_override               program_county_overrides
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.program_county_lookup
COMMENT 'Best available program_county per (project_name, organization_name), with the method used. Fills NULL program_county downstream.'
AS
WITH known AS (
  SELECT project_name, organization_name, program_county
  FROM silver.admissions_enriched
  WHERE program_county IS NOT NULL
),

pairs AS (
  SELECT DISTINCT project_name, organization_name
  FROM silver.admissions_enriched
),

by_pair AS (
  SELECT project_name, organization_name, min(program_county) AS county
  FROM known
  GROUP BY project_name, organization_name
  HAVING count(DISTINCT program_county) = 1
),

-- County names come from the reference table (one list, not 21 CASE
-- branches). Whole-word match. A name mentioning two counties is
-- ambiguous and left for later strategies, rather than letting the
-- alphabetically first county win.
by_name AS (
  SELECT p.project_name, p.organization_name, min(c.County) AS county
  FROM pairs AS p
  JOIN reference.county_population_mapping AS c
    ON upper(concat_ws(' ', p.project_name, p.organization_name))
       RLIKE concat('(^|[^A-Z])', upper(c.County), '([^A-Z]|$)')
  GROUP BY p.project_name, p.organization_name
  HAVING count(DISTINCT c.County) = 1
),

by_org AS (
  SELECT organization_name, min(program_county) AS county
  FROM known
  GROUP BY organization_name
  HAVING count(DISTINCT program_county) = 1
)

SELECT
  p.project_name,
  p.organization_name,
  coalesce(bp.county, bn.county, bo.county, o.program_county) AS lookup_program_county,
  CASE
    WHEN bp.county         IS NOT NULL THEN 'exact_project_org'
    WHEN bn.county         IS NOT NULL THEN 'explicit_name_parse'
    WHEN bo.county         IS NOT NULL THEN 'organization_history_inferred'
    WHEN o.program_county  IS NOT NULL THEN 'manual_override'
    ELSE 'unresolved'
  END AS lookup_method,
  CASE WHEN lookup_method <> 'unresolved'
       THEN lookup_method IN ('organization_history_inferred', 'manual_override')
  END AS program_county_inferred,
  lookup_method = 'manual_override' AS program_county_external_research
FROM pairs AS p
LEFT JOIN by_pair AS bp
  ON p.project_name <=> bp.project_name AND p.organization_name <=> bp.organization_name
LEFT JOIN by_name AS bn
  ON p.project_name <=> bn.project_name AND p.organization_name <=> bn.organization_name
LEFT JOIN by_org AS bo
  ON p.organization_name <=> bo.organization_name
LEFT JOIN silver.program_county_overrides AS o
  ON p.organization_name = o.organization_name AND p.project_name LIKE o.project_name_like;


-- =====================================================================
-- SILVER: homeless cause, cleaned out of bronze. One row per enrollment.
-- Previously silver read bronze directly and picked a row with
-- ROW_NUMBER() ... ORDER BY personal_id, which is random within the
-- partition: refreshes could pick different causes. min() is at least
-- deterministic. TODO: if bronze has an update timestamp, keep the
-- latest instead (max_by(homeless_cause, <timestamp>)).
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.enrollment_homeless_cause (
  CONSTRAINT single_cause_reported EXPECT (n_causes_reported = 1)
)
COMMENT 'One homeless_cause per (personal_id, enrollment_id). n_causes_reported > 1 means the source disagreed with itself.'
AS SELECT
  personal_id,
  EnrollmentID                    AS enrollment_id,
  min(homeless_cause)             AS homeless_cause,
  count(DISTINCT homeless_cause)  AS n_causes_reported
FROM bronze.homeless_causes
GROUP BY personal_id, EnrollmentID;


-- =====================================================================
-- SILVER: dashboard base. One row per enrollment_id, filtered to the
-- five project types the report uses, with conformed labels.
-- Expectations without ON VIOLATION keep the row and count failures,
-- so the unresolved-county rate etc. show up in the pipeline UI.
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.snapshot_dashboard (
  CONSTRAINT has_entry_date          EXPECT (entry_date IS NOT NULL),
  CONSTRAINT exit_not_before_entry   EXPECT (exit_date IS NULL OR exit_date >= entry_date),
  CONSTRAINT county_resolved         EXPECT (program_county IS NOT NULL),
  CONSTRAINT county_in_reference     EXPECT (program_county IS NULL OR county_population IS NOT NULL),
  CONSTRAINT known_population_type   EXPECT (population_type IN ('Sheltered', 'Unsheltered'))
)
COMMENT 'One row per enrollment in ES, SO, TH and Safe Haven projects, with repaired county and dashboard labels.'
AS
WITH admissions AS (
  SELECT
    *,
    size(filter(
      array(race_am_ind_ak_native, race_asian, race_black, race_hispanic_latino,
            race_mid_east_n_african, race_native_hi_pacific, race_white),
      x -> x = '1'
    )) AS n_races
  FROM silver.admissions_enriched
  WHERE project_type_description IN (
    'Emergency Shelter - Entry Exit',
    'Emergency Shelter - Night-by-Night',
    'Street Outreach',
    'Transitional Housing',
    'Safe Haven'
  )
),

labeled AS (
  -- Labels are computed here and sort keys in the outer SELECT: several
  -- labels reuse source column names, and a lateral alias would lose to
  -- the source column.
  SELECT
    a.enrollment_id,
    a.personal_id,
    a.household_id,
    a.entry_date,
    a.exit_date,
    a.project_type_description,
    a.has_any_disability,
    a.veteran_status,
    a.project_name,
    a.organization_name,
    current_timestamp() AS _processed_timestamp,

    -- County: the source value wins; the lookup only fills NULLs.
    coalesce(a.program_county, pcl.lookup_program_county)          AS program_county,
    a.program_county                                               AS source_program_county,
    a.program_county IS NULL AND coalesce(pcl.program_county_inferred, FALSE)          AS program_county_inferred,
    a.program_county IS NULL AND coalesce(pcl.program_county_external_research, FALSE) AS program_county_external_research,
    CASE WHEN a.program_county IS NOT NULL THEN 'source' ELSE pcl.lookup_method END    AS program_county_lookup_method,

    -- Race: one label per person-enrollment.
    CASE
      WHEN a.n_races > 1                    THEN 'Multiracial'
      WHEN a.race_am_ind_ak_native   = '1'  THEN 'American Indian or Alaska Native'
      WHEN a.race_asian              = '1'  THEN 'Asian'
      WHEN a.race_black              = '1'  THEN 'Black'
      WHEN a.race_hispanic_latino    = '1'  THEN 'Hispanic or Latino'
      WHEN a.race_mid_east_n_african = '1'  THEN 'Middle Eastern or North African'
      WHEN a.race_native_hi_pacific  = '1'  THEN 'Native Hawaiian or Other Pacific Islander'
      WHEN a.race_white              = '1'  THEN 'White'
      ELSE 'Unknown'
    END AS race,

    -- Age at entry, banded.
    CASE
      WHEN a.age_at_entry IS NULL
        OR a.dob_data_quality > 2
        OR a.age_at_entry NOT BETWEEN 0 AND 100 THEN 'Unknown'
      WHEN a.age_at_entry < 18  THEN 'Under 18'
      WHEN a.age_at_entry <= 24 THEN '18-24'
      WHEN a.age_at_entry <= 34 THEN '25-34'
      WHEN a.age_at_entry <= 44 THEN '35-44'
      WHEN a.age_at_entry <= 54 THEN '45-54'
      WHEN a.age_at_entry <= 61 THEN '55-61'
      ELSE '62+'
    END AS age_group,

    coalesce(hc.homeless_cause, 'No Match') AS homeless_cause,

    -- Only these five project types survive the filter above; widen both
    -- lists together if the report scope changes.
    CASE
      WHEN a.project_type_description IN (
        'Emergency Shelter - Entry Exit', 'Emergency Shelter - Night-by-Night', 'Safe Haven'
      ) THEN 'Shelter'
      ELSE a.project_type_description
    END AS project_type_grouped,

    CASE a.population_type
      WHEN 'Sheltered Homelessness'            THEN 'Sheltered'
      WHEN 'Transitional Housing Programs'     THEN 'Sheltered'
      WHEN 'Unsheltered Homelessness Programs' THEN 'Unsheltered'
      ELSE a.population_type
    END AS population_type,

    CASE a.disabling_condition
      WHEN '1' THEN 'Yes'
      WHEN '0' THEN 'No'
      ELSE 'Unknown'                 -- 8, 9, 99, NULL, anything unexpected
    END AS disabling_condition,

    CASE a.is_veteran
      WHEN TRUE  THEN 'Veteran'
      WHEN FALSE THEN 'Not a Veteran'
      ELSE 'Unknown'                 -- previously NULL was counted as 'Not a Veteran'
    END AS is_veteran,

    h.actual_household_member_count,
    h.household_size_category,
    h.detailed_household_category,
    h.is_family_with_children,
    h.is_single_parent_household,
    h.household_vulnerability_count,
    h.household_has_chronically_homeless,
    h.household_has_veteran,
    h.household_has_disabled_member,
    h.household_has_dv_survivor,
    h.income_category,

    cpm.Population AS county_population

  FROM admissions AS a
  LEFT JOIN silver.enrollment_homeless_cause AS hc
    ON a.personal_id = hc.personal_id AND a.enrollment_id = hc.enrollment_id
  LEFT JOIN silver.households AS h
    ON a.household_id = h.household_id
  LEFT JOIN silver.program_county_lookup AS pcl
    ON a.project_name <=> pcl.project_name AND a.organization_name <=> pcl.organization_name
  LEFT JOIN reference.county_population_mapping AS cpm
    ON coalesce(a.program_county, pcl.lookup_program_county) = cpm.County
)

SELECT
  *,
  -- Sort key = position in display order; one list per dimension.
  array_position(array(
    'American Indian or Alaska Native', 'Asian', 'Black', 'Hispanic or Latino',
    'Middle Eastern or North African', 'Native Hawaiian or Other Pacific Islander',
    'White', 'Multiracial', 'Unknown'
  ), race)                                                                        AS race_sort,
  array_position(array('Under 18', '18-24', '25-34', '35-44', '45-54', '55-61', '62+', 'Unknown'),
                 age_group)                                                       AS age_group_sort,
  array_position(array('Shelter', 'Homelessness Prevention', 'Permanent Housing',
                       'Transitional Housing', 'Street Outreach'),
                 project_type_grouped)                                            AS project_type_grouped_sort,
  array_position(array('Yes', 'No', 'Unknown'), disabling_condition)              AS disabling_condition_sort,
  array_position(array('Veteran', 'Not a Veteran', 'Unknown'), is_veteran)        AS is_veteran_sort
FROM labeled;


-- =====================================================================
-- GOLD: monthly homeless count by demographic slice.
-- Grain: month_start x program_county x population_type x race x
--        detailed_household_category x age_group x disabling_condition x
--        is_veteran x homeless_cause x project_type_grouped
-- Window: the month 60 months ago through the current (partial) month,
--         i.e. 61 month rows.
--
-- Each person contributes exactly one row per month (their canonical
-- enrollment: Sheltered > Unsheltered, then open > closed, then latest
-- entry, then enrollment_id as a final deterministic tiebreak).
--
-- ADDITIVITY - read before building visuals:
--   * Within ONE month, homeless_count sums correctly across any slice.
--   * Across months it does NOT: someone homeless Jan-Mar is counted 3
--     times. Yearly or multi-month totals need a distinct-person measure
--     on silver, not SUM over this table.
--   * A person enrolled in two counties in the same month appears only
--     under their canonical county, so county totals can be lower than a
--     DAX DISTINCTCOUNT filtered by county.
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW gold.snapshot_dashboard
COMMENT 'Distinct people homeless per month by demographic slice. Additive within a month only; see pipeline source for details.'
AS
WITH bounds AS (
  SELECT
    date_trunc('month', add_months(current_date(), -60)) AS window_start,
    date_trunc('month', current_date())                  AS window_end
),

person_months AS (
  SELECT
    d.*,
    explode(sequence(
      greatest(date_trunc('month', d.entry_date), b.window_start),
      least(date_trunc('month', coalesce(d.exit_date, current_date())), b.window_end),
      interval 1 month
    )) AS month_start
  FROM silver.snapshot_dashboard AS d
  CROSS JOIN bounds AS b
  WHERE d.entry_date IS NOT NULL
    AND (d.exit_date IS NULL OR d.exit_date >= d.entry_date)   -- sequence() errors otherwise
    AND d.entry_date <= b.window_end
    AND (d.exit_date IS NULL OR d.exit_date >= b.window_start)
),

canonical AS (
  SELECT *
  FROM person_months
  QUALIFY row_number() OVER (
    PARTITION BY personal_id, month_start
    ORDER BY population_type = 'Sheltered' DESC,
             exit_date IS NULL DESC,
             entry_date DESC,
             enrollment_id
  ) = 1
)

SELECT
  month_start,
  year(month_start)                    AS year,
  date_format(month_start, 'MMM yyyy') AS month_label,
  program_county,
  population_type,
  race,                        race_sort,
  detailed_household_category,
  age_group,                   age_group_sort,
  disabling_condition,         disabling_condition_sort,
  is_veteran,                  is_veteran_sort,
  homeless_cause,
  project_type_grouped,        project_type_grouped_sort,
  count(*)                     AS homeless_count,   -- one row per person-month, so count(*) = distinct people
  current_timestamp()          AS _processed_timestamp
FROM canonical
GROUP BY
  month_start, program_county, population_type,
  race, race_sort, detailed_household_category,
  age_group, age_group_sort,
  disabling_condition, disabling_condition_sort,
  is_veteran, is_veteran_sort,
  homeless_cause,
  project_type_grouped, project_type_grouped_sort;


-- =====================================================================
-- CHECKS: grain assertions. A duplicate key means a join fanned out and
-- every count downstream is inflated, so fail the update instead of
-- publishing wrong numbers quietly. PRIVATE = not published to the catalog.
-- =====================================================================

CREATE OR REFRESH PRIVATE MATERIALIZED VIEW dashboard_grain_checks (
  CONSTRAINT lookup_one_row_per_pair       EXPECT (lookup_dupes = 0) ON VIOLATION FAIL UPDATE,
  CONSTRAINT cause_one_row_per_enrollment  EXPECT (cause_dupes  = 0) ON VIOLATION FAIL UPDATE,
  CONSTRAINT silver_one_row_per_enrollment EXPECT (silver_dupes = 0) ON VIOLATION FAIL UPDATE
)
AS SELECT
  (SELECT count(*) FROM (
     SELECT 1 FROM silver.program_county_lookup
     GROUP BY project_name, organization_name HAVING count(*) > 1))  AS lookup_dupes,
  (SELECT count(*) FROM (
     SELECT 1 FROM silver.enrollment_homeless_cause
     GROUP BY personal_id, enrollment_id HAVING count(*) > 1))       AS cause_dupes,
  (SELECT count(*) FROM (
     SELECT 1 FROM silver.snapshot_dashboard
     GROUP BY enrollment_id HAVING count(*) > 1))                    AS silver_dupes;
