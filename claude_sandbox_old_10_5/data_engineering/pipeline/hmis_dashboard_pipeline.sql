-- =====================================================================
-- HMIS dashboard pipeline (Lakeflow Declarative Pipeline, SQL)
--
-- Replaces three hand-run scripts (run in this order, by a person):
--   make_program_county_lookup.sql -> make_dashboard_silver.sql -> make_dashboard_gold.sql
-- Databricks now works out the order from the table references, so
-- "run this first" comments are no longer needed.
--
-- OUTPUT CONTRACT: the three tables you already publish keep the same
-- names, columns, column order and values:
--   silver.program_county_lookup   (+1 audit column at the end: n_counties_named)
--   silver.snapshot_dashboard
--   gold.snapshot_dashboard        <- the table Power BI reads
-- Anything that would change a number Power BI shows is NOT in here.
-- See PIPELINE_NOTES.md, "Decisions for you".
--
-- Pipeline settings (set in databricks.yml, never in this file):
--   Default catalog : example_catalog in dev, the prod catalog in prod
--   Compute         : Serverless
-- Two-part names (schema.table) resolve against the default catalog, so
-- the same file runs unchanged in every environment.
--
-- Reads (existing tables this pipeline does not own):
--   silver.admissions_enriched, silver.households,
--   bronze.homeless_causes, reference.county_population_mapping
--
-- LAYERS
--   reference  small hand-maintained tables (config as data)
--   silver     one row per enrollment, cleaned and labelled
--   checks     assertions that stop bad numbers reaching Power BI
--   gold       one row per month x demographic slice
-- =====================================================================


-- =====================================================================
-- REFERENCE: judgement and configuration live in data, not in CASE
-- statements. Edit a row, open a pull request, and the change has an
-- author, a date and evidence.
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.program_county_overrides
COMMENT 'Manual program_county assignments with evidence. Edit via pull request. Pending, no evidence yet: BVH Region 3 (Community Hope), BVH Region 5 (Soldier On). They stay unresolved.'
AS SELECT * FROM VALUES
  ('cspnj',             'OHP - BVH%', 'Hudson',    'BVH Region 1: dominant county of 1,083 county-tagged OHP rows'),
  ('Garden State Home', 'OHP - BVH%', 'Middlesex', 'BVH Region 4: dominant county of 870 county-tagged OHP rows')
AS t(organization_name, project_name_like, program_county, evidence);


-- Report scope AND grouping in one place. Previously the five project
-- types appeared in a WHERE list, again in a CASE for the group label,
-- and again in a CASE for the sort key. Widen the report by adding a
-- row here (for example 'Day Shelter', 'Shelter', 1).
CREATE OR REFRESH MATERIALIZED VIEW silver.dashboard_project_type_map
COMMENT 'Project types included in the dashboard, with report group and display order. A project type not listed here is out of scope.'
AS SELECT * FROM VALUES
  ('Emergency Shelter - Entry Exit',    'Shelter',              1),
  ('Emergency Shelter - Night-by-Night','Shelter',              1),
  ('Safe Haven',                        'Shelter',              1),
  ('Transitional Housing',              'Transitional Housing', 4),
  ('Street Outreach',                   'Street Outreach',      5)
AS t(project_type_description, project_type_grouped, project_type_grouped_sort);


-- =====================================================================
-- SILVER: county lookup. One row per (project_name, organization_name).
-- Fills NULL program_county downstream; the source value always wins.
-- Strategies in priority order:
--   1. exact_project_org             the pair reports exactly one county elsewhere
--   2. explicit_name_parse           an NJ county is named in the text
--   3. organization_history_inferred the organization reports exactly one county
--   4. ohp_bvh_region_map            program_county_overrides
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.program_county_lookup (
  -- Warn-only: a name that mentions two counties currently resolves to
  -- the alphabetically first one. This counts how often that happens.
  CONSTRAINT name_parse_unambiguous EXPECT (n_counties_named IS NULL OR n_counties_named = 1)
)
COMMENT 'Best available program_county per (project_name, organization_name), with the method used and audit flags.'
AS
WITH pairs AS (
  SELECT DISTINCT project_name, organization_name
  FROM silver.admissions_enriched
),

known AS (
  SELECT project_name, organization_name, program_county
  FROM silver.admissions_enriched
  WHERE program_county IS NOT NULL
),

by_pair AS (
  SELECT project_name, organization_name, min(program_county) AS county
  FROM known
  GROUP BY project_name, organization_name
  HAVING count(DISTINCT program_county) = 1
),

by_org AS (
  SELECT organization_name, min(program_county) AS county
  FROM known
  GROUP BY organization_name
  HAVING count(DISTINCT program_county) = 1
),

-- County names come from the reference table: one list instead of 21
-- copy-pasted CASE branches. Whole-word match. min() picks the
-- alphabetically first county, which is exactly what the old CASE ladder
-- did (its branches were in alphabetical order).
by_name AS (
  SELECT p.project_name,
         p.organization_name,
         min(c.County)            AS county,
         count(DISTINCT c.County) AS n_counties_named
  FROM pairs AS p
  JOIN reference.county_population_mapping AS c
    ON upper(concat_ws(' ', p.project_name, p.organization_name))
       RLIKE concat('(^|[^A-Z])', upper(c.County), '([^A-Z]|$)')
  GROUP BY p.project_name, p.organization_name
)

SELECT
  p.project_name,
  p.organization_name,
  coalesce(bp.county, bn.county, bo.county, ov.program_county) AS lookup_program_county,
  CASE
    WHEN bp.county         IS NOT NULL THEN 'exact_project_org'
    WHEN bn.county         IS NOT NULL THEN 'explicit_name_parse'
    WHEN bo.county         IS NOT NULL THEN 'organization_history_inferred'
    WHEN ov.program_county IS NOT NULL THEN 'ohp_bvh_region_map'
    ELSE 'unresolved'
  END AS lookup_method,
  CASE
    WHEN bp.county         IS NOT NULL THEN FALSE
    WHEN bn.county         IS NOT NULL THEN FALSE
    WHEN bo.county         IS NOT NULL THEN TRUE
    WHEN ov.program_county IS NOT NULL THEN TRUE
    ELSE NULL
  END AS program_county_inferred,
  ov.program_county IS NOT NULL AS program_county_external_research,
  bn.n_counties_named
FROM pairs AS p
LEFT JOIN by_pair AS bp
  ON p.project_name = bp.project_name AND p.organization_name = bp.organization_name
LEFT JOIN by_name AS bn
  ON p.project_name = bn.project_name AND p.organization_name = bn.organization_name
LEFT JOIN by_org AS bo
  ON p.organization_name = bo.organization_name
LEFT JOIN silver.program_county_overrides AS ov
  ON p.organization_name = ov.organization_name
 AND p.project_name LIKE ov.project_name_like;


-- =====================================================================
-- SILVER: homeless cause, cleaned out of bronze. One row per enrollment.
-- Silver used to read bronze inside the dashboard query; now this
-- layer step is explicit and reusable. Rule (unchanged): latest
-- source_year wins, then the alphabetically first non-null cause.
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.enrollment_homeless_cause
COMMENT 'One homeless_cause per (personal_id, enrollment_id): latest source_year, then alphabetical.'
AS SELECT
  personal_id,
  EnrollmentID AS enrollment_id,
  homeless_cause
FROM bronze.homeless_causes
QUALIFY row_number() OVER (
  PARTITION BY personal_id, EnrollmentID
  ORDER BY source_year DESC, homeless_cause ASC NULLS LAST
) = 1;


-- =====================================================================
-- SILVER: dashboard base. One row per enrollment_id, in-scope project
-- types only, with conformed labels and sort keys.
--
-- Expectations without ON VIOLATION keep the row and record the failure,
-- so the unresolved-county rate and similar show up in the pipeline UI
-- and event log without stopping the run.
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW silver.snapshot_dashboard (
  CONSTRAINT has_entry_date        EXPECT (entry_date IS NOT NULL),
  CONSTRAINT exit_not_before_entry EXPECT (exit_date IS NULL OR exit_date >= entry_date),
  CONSTRAINT county_resolved       EXPECT (program_county IS NOT NULL),
  CONSTRAINT county_in_reference   EXPECT (program_county IS NULL OR county_population IS NOT NULL),
  CONSTRAINT known_population_type EXPECT (population_type IN ('Sheltered', 'Unsheltered')),
  -- A label that is missing from its display-order list gets a NULL sort key.
  CONSTRAINT sort_keys_present     EXPECT (race_sort IS NOT NULL AND age_group_sort IS NOT NULL AND project_type_grouped_sort IS NOT NULL)
)
COMMENT 'One row per enrollment in in-scope projects (see dashboard_project_type_map), with repaired program_county and dashboard labels.'
AS
WITH admissions AS (
  SELECT
    a.enrollment_id, a.personal_id, a.household_id,
    a.entry_date, a.exit_date,
    a.project_type_description, a.project_name, a.organization_name,
    a.has_any_disability, a.veteran_status,
    a.race_am_ind_ak_native, a.race_asian, a.race_black, a.race_hispanic_latino,
    a.race_mid_east_n_african, a.race_native_hi_pacific, a.race_white, a.race_none,
    a.age_at_entry, a.dob_data_quality,
    a.program_county, a.population_type, a.disabling_condition, a.is_veteran,
    pt.project_type_grouped, pt.project_type_grouped_sort,
    -- Count the race flags once instead of re-adding seven CASE terms in three places.
    size(filter(
      array(a.race_am_ind_ak_native, a.race_asian, a.race_black, a.race_hispanic_latino,
            a.race_mid_east_n_african, a.race_native_hi_pacific, a.race_white),
      x -> x = '1'
    )) AS n_races
  FROM silver.admissions_enriched AS a
  JOIN silver.dashboard_project_type_map AS pt      -- inner join = the scope filter
    ON a.project_type_description = pt.project_type_description
),

-- Labels are computed here and sort keys in the final SELECT. Several
-- labels reuse a source column name (population_type, disabling_condition,
-- is_veteran); an unqualified reference to that name in the same SELECT
-- would bind to the source column, not the new label.
labeled AS (
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
    coalesce(a.program_county, pcl.lookup_program_county) AS program_county,
    a.program_county                                       AS source_program_county,
    coalesce(CASE WHEN a.program_county IS NULL THEN pcl.program_county_inferred END, FALSE)          AS program_county_inferred,
    coalesce(CASE WHEN a.program_county IS NULL THEN pcl.program_county_external_research END, FALSE) AS program_county_external_research,
    CASE WHEN a.program_county IS NOT NULL THEN 'source' ELSE pcl.lookup_method END                   AS program_county_lookup_method,

    -- Race: one label per enrollment. White + Hispanic/Latino and nothing
    -- else counts as Hispanic or Latino (n_races = 2 means exactly those two).
    CASE
      WHEN a.race_hispanic_latino = '1' AND a.race_white = '1' AND a.n_races = 2 THEN 'Hispanic or Latino'
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

    -- Every flagged race, alphabetical, so Multiracial rows are readable.
    coalesce(nullif(concat_ws(', ',
      CASE WHEN a.race_am_ind_ak_native   = '1' THEN 'American Indian or Alaska Native' END,
      CASE WHEN a.race_asian              = '1' THEN 'Asian' END,
      CASE WHEN a.race_black              = '1' THEN 'Black' END,
      CASE WHEN a.race_hispanic_latino    = '1' THEN 'Hispanic or Latino' END,
      CASE WHEN a.race_mid_east_n_african = '1' THEN 'Middle Eastern or North African' END,
      CASE WHEN a.race_native_hi_pacific  = '1' THEN 'Native Hawaiian or Other Pacific Islander' END,
      CASE WHEN a.race_white              = '1' THEN 'White' END
    ), ''), 'Unknown') AS race_detail,

    -- Age at entry, banded. Implausible or low-quality ages are Unknown.
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

    a.project_type_grouped,
    a.project_type_grouped_sort,

    CASE a.population_type
      WHEN 'Sheltered Homelessness'            THEN 'Sheltered'
      WHEN 'Transitional Housing Programs'     THEN 'Sheltered'
      WHEN 'Unsheltered Homelessness Programs' THEN 'Unsheltered'
      ELSE a.population_type
    END AS population_type,
    a.population_type AS population_type_test,   -- unmodified source value

    CASE a.disabling_condition
      WHEN '0'  THEN 'No'
      WHEN '1'  THEN 'Yes'
      WHEN '8'  THEN 'Unknown'
      WHEN '9'  THEN 'Unknown'
      WHEN '99' THEN 'Unknown'
      ELSE a.disabling_condition
    END AS disabling_condition,

    CASE WHEN a.is_veteran THEN 'Veteran' ELSE 'Not a Veteran' END AS is_veteran,

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
    ON a.project_name = pcl.project_name AND a.organization_name = pcl.organization_name
  LEFT JOIN reference.county_population_mapping AS cpm
    ON coalesce(a.program_county, pcl.lookup_program_county) = cpm.County
)

-- Sort key = position in the display-order list, one list per dimension,
-- so a label and its sort key cannot drift apart. Columns are listed
-- explicitly to keep the published column order stable.
SELECT
  enrollment_id, personal_id, household_id, entry_date, exit_date,
  project_type_description, has_any_disability, veteran_status,
  project_name, organization_name, _processed_timestamp,
  program_county, source_program_county, program_county_inferred,
  program_county_external_research, program_county_lookup_method,
  race,
  CAST(array_position(array(
    'American Indian or Alaska Native', 'Asian', 'Black', 'Hispanic or Latino',
    'Middle Eastern or North African', 'Native Hawaiian or Other Pacific Islander',
    'White', 'Multiracial', 'Unknown'), race) AS INT)                          AS race_sort,
  race_detail,
  age_group,
  CAST(array_position(array(
    'Under 18', '18-24', '25-34', '35-44', '45-54', '55-61', '62+', 'Unknown'), age_group) AS BIGINT) AS age_group_sort,
  homeless_cause,
  project_type_grouped, project_type_grouped_sort,
  population_type, population_type_test,
  disabling_condition,
  CAST(coalesce(array_position(array('Yes', 'No', 'Unknown'), disabling_condition), 3) AS INT) AS disabling_condition_sort,
  is_veteran,
  CAST(array_position(array('Veteran', 'Not a Veteran'), is_veteran) AS INT)   AS is_veteran_sort,
  actual_household_member_count, household_size_category, detailed_household_category,
  is_family_with_children, is_single_parent_household, household_vulnerability_count,
  household_has_chronically_homeless, household_has_veteran, household_has_disabled_member,
  household_has_dv_survivor, income_category,
  county_population
FROM labeled;


-- =====================================================================
-- CHECKS (before gold): grain assertions. A duplicate key means a join
-- fanned out and every count downstream is inflated. FAIL UPDATE stops
-- the run instead of publishing wrong numbers quietly.
--
-- Gold reads this view (see "bounds" below), so gold is only refreshed
-- after these pass. PRIVATE = not published to the catalog.
-- =====================================================================

CREATE OR REFRESH PRIVATE MATERIALIZED VIEW dashboard_grain_checks (
  CONSTRAINT lookup_one_row_per_pair       EXPECT (lookup_dupes = 0) ON VIOLATION FAIL UPDATE,
  CONSTRAINT cause_one_row_per_enrollment  EXPECT (cause_dupes  = 0) ON VIOLATION FAIL UPDATE,
  CONSTRAINT silver_one_row_per_enrollment EXPECT (silver_dupes = 0) ON VIOLATION FAIL UPDATE,
  CONSTRAINT county_ref_one_row_per_county EXPECT (county_ref_dupes = 0) ON VIOLATION FAIL UPDATE
)
AS SELECT
  (SELECT count(*) FROM (
     SELECT 1 FROM silver.program_county_lookup
     GROUP BY project_name, organization_name HAVING count(*) > 1))   AS lookup_dupes,
  (SELECT count(*) FROM (
     SELECT 1 FROM silver.enrollment_homeless_cause
     GROUP BY personal_id, enrollment_id HAVING count(*) > 1))        AS cause_dupes,
  (SELECT count(*) FROM (
     SELECT 1 FROM silver.snapshot_dashboard
     GROUP BY enrollment_id HAVING count(*) > 1))                     AS silver_dupes,
  (SELECT count(*) FROM (
     SELECT 1 FROM reference.county_population_mapping
     GROUP BY County HAVING count(*) > 1))                            AS county_ref_dupes;


-- =====================================================================
-- GOLD: distinct people homeless per month, by demographic slice.
-- This is the table Power BI reads.
--
-- Grain: month_start x program_county x population_type x race x
--        detailed_household_category x age_group x disabling_condition x
--        is_veteran x homeless_cause x project_type_grouped
-- Window: the month 60 months ago through the current (partial) month.
--
-- Each person contributes exactly ONE row per month: their canonical
-- enrollment, chosen in this order
--   1. Sheltered beats Unsheltered
--   2. still open (exit_date IS NULL) beats closed
--   3. most recent entry_date
--   4. enrollment_id (only so ties resolve the same way on every refresh)
--
-- ADDITIVITY - read before building visuals:
--   * WITHIN ONE MONTH, homeless_count adds up correctly across any slice.
--   * ACROSS MONTHS it does not: someone homeless Jan-Mar counts three
--     times. A yearly or multi-month distinct total needs a
--     distinct-person measure over silver, not SUM over this table.
--   * A person enrolled in two counties in one month appears only under
--     their canonical county, so county totals can be lower than a DAX
--     DISTINCTCOUNT filtered by county.
-- =====================================================================

CREATE OR REFRESH MATERIALIZED VIEW gold.snapshot_dashboard
COMMENT 'Distinct people homeless per month by demographic slice. Additive within a month only. See pipeline source for details. Power BI reads this table.'
AS
WITH bounds AS (
  -- Reading dashboard_grain_checks makes gold wait for the grain checks,
  -- and skips gold this run if they fail. The view has exactly one row.
  SELECT
    date_trunc('month', add_months(current_date(), -60)) AS window_start,
    last_day(date_trunc('month', current_date()))         AS window_end
  FROM dashboard_grain_checks
),

active_records AS (
  SELECT
    d.enrollment_id,
    d.personal_id,
    d.program_county,
    d.population_type,
    d.race,
    d.race_sort,
    d.detailed_household_category,
    d.age_group,
    d.age_group_sort,
    d.disabling_condition,
    d.disabling_condition_sort,
    d.is_veteran,
    d.is_veteran_sort,
    d.homeless_cause,
    d.project_type_grouped,
    d.project_type_grouped_sort,
    d.entry_date,
    d.exit_date,
    explode(sequence(
      greatest(date_trunc('month', d.entry_date), b.window_start),
      least(date_trunc('month', coalesce(d.exit_date, current_date())), b.window_end),
      interval 1 month
    )) AS month_start
  FROM silver.snapshot_dashboard AS d
  CROSS JOIN bounds AS b
  WHERE d.entry_date IS NOT NULL
    -- sequence() fails the whole update if the start is after the stop, so
    -- a record whose exit month is before its entry month must not reach it.
    -- Such rows are counted by the exit_not_before_entry expectation in silver.
    AND (d.exit_date IS NULL OR date_trunc('month', d.exit_date) >= date_trunc('month', d.entry_date))
    AND d.entry_date <= b.window_end
    AND (d.exit_date IS NULL OR d.exit_date >= b.window_start)
),

canonical_person_month AS (
  SELECT *
  FROM active_records
  QUALIFY row_number() OVER (
    PARTITION BY personal_id, month_start
    ORDER BY CASE WHEN population_type = 'Sheltered' THEN 0 ELSE 1 END,
             CASE WHEN exit_date IS NULL THEN 0 ELSE 1 END,
             entry_date DESC,
             enrollment_id
  ) = 1
),

-- Post-dedup fallback: fill a NULL detailed_household_category from the
-- person's other active enrollments that month (most recent entry first).
hh_fallback AS (
  SELECT personal_id, month_start, detailed_household_category
  FROM active_records
  WHERE detailed_household_category IS NOT NULL
  QUALIFY row_number() OVER (
    PARTITION BY personal_id, month_start
    ORDER BY entry_date DESC, enrollment_id
  ) = 1
),

canonical_filled AS (
  SELECT
    c.* EXCEPT (detailed_household_category),
    coalesce(c.detailed_household_category, fb.detailed_household_category) AS detailed_household_category
  FROM canonical_person_month AS c
  LEFT JOIN hh_fallback AS fb
    ON fb.personal_id = c.personal_id
   AND fb.month_start = c.month_start
)

SELECT
  month_start,
  year(month_start)                    AS year,
  date_format(month_start, 'MMM yyyy') AS month_label,
  program_county,
  population_type,
  race,
  race_sort,
  detailed_household_category,
  age_group,
  age_group_sort,
  disabling_condition,
  disabling_condition_sort,
  is_veteran,
  is_veteran_sort,
  homeless_cause,
  project_type_grouped,
  project_type_grouped_sort,
  count(*)                             AS homeless_count,   -- one row per person-month, so count(*) = distinct people
  current_timestamp()                  AS _processed_timestamp
FROM canonical_filled
GROUP BY
  month_start,
  program_county,
  population_type,
  race, race_sort,
  detailed_household_category,
  age_group, age_group_sort,
  disabling_condition, disabling_condition_sort,
  is_veteran, is_veteran_sort,
  homeless_cause,
  project_type_grouped, project_type_grouped_sort;
-- No ORDER BY: row order in a table is not a contract, and a global sort
-- costs a full shuffle. Power BI orders by the *_sort columns.


-- =====================================================================
-- CHECKS (after gold): reconcile gold to an independent count from silver.
-- For three sample months, the distinct people active in silver must equal
-- SUM(homeless_count) in gold. This runs AFTER gold is refreshed, so it
-- alerts you (the job fails and emails) rather than preventing publication.
-- =====================================================================

CREATE OR REFRESH PRIVATE MATERIALIZED VIEW dashboard_reconciliation (
  CONSTRAINT gold_matches_silver EXPECT (gold_people = silver_people) ON VIOLATION FAIL UPDATE
)
AS
WITH months AS (
  SELECT explode(array(
    date_trunc('month', current_date()),
    add_months(date_trunc('month', current_date()), -1),
    add_months(date_trunc('month', current_date()), -12)
  )) AS month_start
),

silver_people AS (
  SELECT m.month_start, count(DISTINCT s.personal_id) AS silver_people
  FROM months AS m
  JOIN silver.snapshot_dashboard AS s
    ON s.entry_date <= last_day(m.month_start)
   AND (s.exit_date IS NULL OR s.exit_date >= m.month_start)
   AND (s.exit_date IS NULL OR date_trunc('month', s.exit_date) >= date_trunc('month', s.entry_date))
  GROUP BY m.month_start
),

gold_people AS (
  SELECT month_start, sum(homeless_count) AS gold_people
  FROM gold.snapshot_dashboard
  GROUP BY month_start
)

SELECT s.month_start, s.silver_people, coalesce(g.gold_people, 0) AS gold_people
FROM silver_people AS s
LEFT JOIN gold_people AS g ON g.month_start = s.month_start;
