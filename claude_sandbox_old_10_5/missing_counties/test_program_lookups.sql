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
