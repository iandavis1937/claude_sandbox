-- ================================================================
-- Program County Lookup Table
-- Resolves missing program_county values from project_name and
-- organization_name.  Run BEFORE make_dashboard_silver.sql.
-- Source: example_catalog.silver.admissions_enriched
-- Target: example_catalog.silver.program_county_lookup
-- ================================================================
--
-- PROBLEM
-- -------
-- Many rows in admissions_enriched have a NULL program_county even
-- though the county is recoverable from the text of the
-- project_name and organization_name fields.  Without a county,
-- those rows are invisible to every county-level dashboard filter
-- and map, silently undercounting metrics for the affected
-- programs.
--
-- APPROACH
-- --------
-- Build a one-row-per-(project_name, organization_name) lookup
-- table that assigns a program_county using three strategies
-- applied in priority order via COALESCE:
--
--   1. exact_project_org  (lookup_method = 'exact_project_org')
--      If the SAME (project_name, organization_name) pair already
--      appears elsewhere in admissions_enriched with exactly ONE
--      distinct non-null program_county, adopt that county.  This
--      is the highest-confidence match — the data itself tells us
--      the answer unambiguously.
--
--   2. county_name_parse  (lookup_method = 'explicit_name_parse')
--      Regex-extract a New Jersey county name from the combined
--      project_name + organization_name text.  The pattern uses
--      word-boundary guards ([^A-Z] / $ / ^) so that partial
--      matches inside longer words are rejected.  Only the 21 NJ
--      county names are searched for.  The CASE short-circuits on
--      the first match, so if a name contains two counties the
--      first one wins (rare; typically the project_name suffix is
--      the operative county and appears first in the concatenation).
--
--   3. exact_org  (lookup_method = 'organization_history_inferred')
--      If the organization_name (ignoring project_name) maps to
--      exactly ONE distinct county across all its non-null rows,
--      use that.  This is weaker than strategy 1 because some orgs
--      operate across multiple counties, so it is only reached when
--      neither strategy 1 nor 2 produced a result.  The
--      program_county_inferred flag is set to TRUE for these rows.
--
--   4. ohp_bvh_region_map  (lookup_method = 'ohp_bvh_region_map')
--      The OHP Bringing Veterans Home (BVH) program names projects
--      by region number (Region 1–6) rather than county.  Each
--      region covers multiple counties with a single lead agency.
--      Regions 2 and 6 are already resolved by strategy 2 because
--      their org names contain county names ("Essex", "Burlington").
--      This strategy handles Regions 1, 3, 4, 5 by mapping each
--      lead agency to its dominant county from other county-tagged
--      OHP program entries in the data.
--
--      Region 1 (cspnj)           → Hudson    (1,083 OHP rows)
--      Region 3 (Community Hope)  → NULL      (no county-tagged OHP data)
--      Region 4 (Garden State Home) → Middlesex (870 OHP rows)
--      Region 5 (Soldier On)      → NULL      (no county data at all)
--
--      Regions 3 and 5 are left NULL pending manual assignment.
--      Both are flagged program_county_inferred = TRUE and
--      program_county_external_research = TRUE.
--
-- Rows that remain unresolved after all four strategies get
-- lookup_method = 'unresolved' and lookup_program_county = NULL.
--
-- AUDIT COLUMNS
-- -------------
-- * lookup_method               – which strategy resolved the county
-- * program_county_inferred     – TRUE when the county was inferred
--                                 from org history rather than
--                                 directly observed or parsed
-- * program_county_external_research
--                               – reserved for future manual
--                                 overrides sourced via external
--                                 research (currently always FALSE)
--
-- DOWNSTREAM USAGE
-- ----------------
-- make_dashboard_silver.sql joins this table on
-- (project_name, organization_name) and uses
--   COALESCE(a.program_county, pcl.lookup_program_county)
-- so the original value is always preferred; the lookup only fills
-- NULLs.  The audit columns propagate into snapshot_dashboard for
-- transparency.
-- ================================================================

CREATE OR REPLACE TABLE example_catalog.silver.program_county_lookup AS
WITH base_pairs AS (
    -- Every distinct (project_name, organization_name) combination in the
    -- source table.  This is the grain of the lookup — one row per pair.
    SELECT DISTINCT project_name, organization_name
    FROM example_catalog.silver.admissions_enriched
),

exact_project_org_counts AS (
    -- Strategy 1 prep: for each (project, org) pair, count how many
    -- distinct non-null counties it has.  MIN() is arbitrary — it only
    -- matters when county_count = 1 (where MIN = MAX = the sole value).
    SELECT project_name,
           organization_name,
           COUNT(DISTINCT program_county) AS county_count,
           MIN(program_county) AS program_county
    FROM example_catalog.silver.admissions_enriched
    WHERE program_county IS NOT NULL
    GROUP BY project_name, organization_name
),

exact_project_org AS (
    -- Strategy 1: keep only pairs that map to exactly one county.
    -- Pairs that map to multiple counties are ambiguous and skipped.
    SELECT project_name, organization_name, program_county
    FROM exact_project_org_counts
    WHERE county_count = 1
),

exact_org_counts AS (
    -- Strategy 3 prep: same idea as exact_project_org_counts but at
    -- the organization level only (ignoring project_name).  An org
    -- that always reports the same county is a safe bet.
    SELECT organization_name,
           COUNT(DISTINCT program_county) AS county_count,
           MIN(program_county) AS program_county
    FROM example_catalog.silver.admissions_enriched
    WHERE program_county IS NOT NULL
    GROUP BY organization_name
),

exact_org AS (
    -- Strategy 3: keep only orgs that map to exactly one county.
    -- Multi-county orgs (e.g. "NJ - 211 Passaic" serves all 21
    -- counties) are excluded — the county must come from elsewhere.
    SELECT organization_name, program_county
    FROM exact_org_counts
    WHERE county_count = 1
),

county_name_parse AS (
    -- Strategy 2: regex-extract an NJ county name from the combined
    -- text.  Word-boundary guards ensure we match whole words only
    -- (e.g. "ESSEX" but not "WESSEX").  The CASE short-circuits on
    -- the first hit; if both project_name and organization_name
    -- contain different county names, the first alphabetical county
    -- in the CASE ladder wins.  In practice, nearly all HMIS names
    -- contain at most one county.
    SELECT project_name,
           organization_name,
           CASE
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])ATLANTIC([^A-Z]|$)' THEN 'Atlantic'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])BERGEN([^A-Z]|$)' THEN 'Bergen'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])BURLINGTON([^A-Z]|$)' THEN 'Burlington'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])CAMDEN([^A-Z]|$)' THEN 'Camden'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])CAPE MAY([^A-Z]|$)' THEN 'Cape May'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])CUMBERLAND([^A-Z]|$)' THEN 'Cumberland'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])ESSEX([^A-Z]|$)' THEN 'Essex'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])GLOUCESTER([^A-Z]|$)' THEN 'Gloucester'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])HUDSON([^A-Z]|$)' THEN 'Hudson'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])HUNTERDON([^A-Z]|$)' THEN 'Hunterdon'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])MERCER([^A-Z]|$)' THEN 'Mercer'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])MIDDLESEX([^A-Z]|$)' THEN 'Middlesex'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])MONMOUTH([^A-Z]|$)' THEN 'Monmouth'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])MORRIS([^A-Z]|$)' THEN 'Morris'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])OCEAN([^A-Z]|$)' THEN 'Ocean'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])PASSAIC([^A-Z]|$)' THEN 'Passaic'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])SALEM([^A-Z]|$)' THEN 'Salem'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])SOMERSET([^A-Z]|$)' THEN 'Somerset'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])SUSSEX([^A-Z]|$)' THEN 'Sussex'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])UNION([^A-Z]|$)' THEN 'Union'
               WHEN UPPER(CONCAT_WS(' ', project_name, organization_name)) RLIKE '(^|[^A-Z])WARREN([^A-Z]|$)' THEN 'Warren'
           END AS parsed_program_county
    FROM base_pairs
),

ohp_bvh_region_map AS (
    -- Strategy 4: map OHP BVH regional projects to their lead county.
    -- The BVH (Bringing Veterans Home) program divides NJ into 6
    -- regions, each served by a lead agency.  Regions 2 and 6 are
    -- already resolved by the name-parse strategy (org names contain
    -- "Essex" and "Burlington" respectively).  This CTE handles the
    -- remaining regions whose org names carry no county.
    --
    -- The county assignment comes from analysing which county is most
    -- frequent for each lead agency's OTHER (non-BVH, county-tagged)
    -- OHP program entries.  Regions 3 and 5 have no such data; add
    -- their counties here once confirmed.
    SELECT project_name,
           organization_name,
           CASE
               WHEN organization_name = 'cspnj'            THEN 'Hudson'     -- Region 1: 1,083 county-tagged OHP rows
               WHEN organization_name = 'Community Hope'    THEN NULL         -- Region 3: TODO — no county evidence
               WHEN organization_name = 'Garden State Home' THEN 'Middlesex'  -- Region 4: 870 county-tagged OHP rows
               WHEN organization_name = 'Soldier On'        THEN NULL         -- Region 5: TODO — no county data at all
           END AS ohp_program_county
    FROM base_pairs
    WHERE project_name LIKE 'OHP - BVH%'
)

-- Assemble the final lookup: one row per (project_name, organization_name).
-- COALESCE priority: Strategy 1 > Strategy 2 > Strategy 3 > Strategy 4.
-- Strategy 1 is preferred because it is an exact historical match.
-- Strategy 2 is next because the county name is explicitly stated.
-- Strategy 3 is the fallback and is flagged as inferred.
SELECT
    bp.project_name,
    bp.organization_name,
    COALESCE(epo.program_county, cnp.parsed_program_county, eo.program_county, ohp.ohp_program_county) AS lookup_program_county,
    CASE
        WHEN epo.program_county IS NOT NULL THEN 'exact_project_org'
        WHEN cnp.parsed_program_county IS NOT NULL THEN 'explicit_name_parse'
        WHEN eo.program_county IS NOT NULL THEN 'organization_history_inferred'
        WHEN ohp.ohp_program_county IS NOT NULL THEN 'ohp_bvh_region_map'
        ELSE 'unresolved'
    END AS lookup_method,
    CASE
        WHEN epo.program_county IS NOT NULL THEN FALSE
        WHEN cnp.parsed_program_county IS NOT NULL THEN FALSE
        WHEN eo.program_county IS NOT NULL THEN TRUE
        WHEN ohp.ohp_program_county IS NOT NULL THEN TRUE
        ELSE NULL
    END AS program_county_inferred,
    CASE
        WHEN ohp.ohp_program_county IS NOT NULL THEN TRUE
        ELSE FALSE
    END AS program_county_external_research
FROM base_pairs bp
LEFT JOIN exact_project_org epo
       ON bp.project_name = epo.project_name
      AND bp.organization_name = epo.organization_name
LEFT JOIN county_name_parse cnp
       ON bp.project_name = cnp.project_name
      AND bp.organization_name = cnp.organization_name
LEFT JOIN exact_org eo
       ON bp.organization_name = eo.organization_name
LEFT JOIN ohp_bvh_region_map ohp
       ON bp.project_name = ohp.project_name
      AND bp.organization_name = ohp.organization_name;