-- =====================================================================
-- DIAGNOSTICS: turn design debates into queries.
-- Each block answers one open question about your data. Run them in dev
-- (read-only) before deciding what to change. Results are the evidence
-- for the "Decisions for you" section of PIPELINE_NOTES.md.
-- =====================================================================

-- D1. Do any in-scope enrollments have NULL project or organization names?
-- The lookup joins with "=", which never matches NULL. If this returns
-- rows, those enrollments can never get a repaired county.
SELECT count(*) AS enrollments,
       count_if(project_name IS NULL)      AS null_project_name,
       count_if(organization_name IS NULL) AS null_organization_name
FROM example_catalog.silver.admissions_enriched
WHERE project_type_description IN ('Emergency Shelter - Entry Exit','Emergency Shelter - Night-by-Night',
                                   'Street Outreach','Transitional Housing','Safe Haven');

-- D2. How are is_veteran and disabling_condition actually populated?
-- Today a NULL is_veteran is shown as "Not a Veteran", and a NULL or
-- unexpected disabling_condition passes through as blank or as-is.
SELECT is_veteran, veteran_status, count(*) AS enrollments
FROM example_catalog.silver.admissions_enriched
GROUP BY is_veteran, veteran_status ORDER BY enrollments DESC;

SELECT disabling_condition, count(*) AS enrollments
FROM example_catalog.silver.admissions_enriched
GROUP BY disabling_condition ORDER BY enrollments DESC;

-- D3. BACKTEST the county name parser against known answers.
-- For pairs where the data itself gives exactly one county (strategy 1),
-- what does the name parser say? Disagreements show where text parsing is wrong.
WITH truth AS (
  SELECT project_name, organization_name, min(program_county) AS true_county
  FROM example_catalog.silver.admissions_enriched
  WHERE program_county IS NOT NULL
  GROUP BY project_name, organization_name
  HAVING count(DISTINCT program_county) = 1
),
parsed AS (
  SELECT t.project_name, t.organization_name, t.true_county,
         min(c.County) AS parsed_county, count(DISTINCT c.County) AS n_named
  FROM truth AS t
  JOIN example_catalog.reference.county_population_mapping AS c
    ON upper(concat_ws(' ', t.project_name, t.organization_name))
       RLIKE concat('(^|[^A-Z])', upper(c.County), '([^A-Z]|$)')
  GROUP BY t.project_name, t.organization_name, t.true_county
)
SELECT count(*)                                         AS pairs_with_a_name_hit,
       count_if(parsed_county =  true_county)           AS parser_right,
       count_if(parsed_county <> true_county)           AS parser_wrong,
       count_if(n_named > 1)                            AS names_two_or_more_counties
FROM parsed;

-- D3b. The disagreements themselves, to read.
-- (Same CTEs as D3, then:)
--   SELECT * FROM parsed WHERE parsed_county <> true_county;
-- Place names that contain a county name are the usual cause, for example
-- "Union City" (Hudson County) or "Ocean City" (Cape May County).

-- D4. Every pair the parser resolved, so a person can eyeball them.
SELECT project_name, organization_name, lookup_program_county, n_counties_named
FROM example_catalog.silver.program_county_lookup
WHERE lookup_method = 'explicit_name_parse'
ORDER BY n_counties_named DESC NULLS LAST, lookup_program_county;

-- D5. How many in-scope enrollments still have no county after repair?
SELECT program_county_lookup_method, count(*) AS enrollments
FROM example_catalog.silver.snapshot_dashboard
GROUP BY program_county_lookup_method ORDER BY enrollments DESC;

-- D6. Grain: is silver really one row per enrollment?
SELECT count(*) AS duplicated_enrollment_ids FROM (
  SELECT enrollment_id FROM example_catalog.silver.snapshot_dashboard
  GROUP BY enrollment_id HAVING count(*) > 1);

-- D7. Bad dates: how many enrollments would have made sequence() fail?
SELECT count(*) AS exit_month_before_entry_month
FROM example_catalog.silver.snapshot_dashboard
WHERE exit_date IS NOT NULL
  AND date_trunc('month', exit_date) < date_trunc('month', entry_date);
