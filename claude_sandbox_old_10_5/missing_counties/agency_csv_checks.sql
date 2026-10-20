-- =====================================================================
-- CHECKS for the agency export (agency_locations.csv).
-- Run in dev in the Databricks SQL editor, all in one session, after
-- uploading the CSV to a Unity Catalog Volume. Read-only.
-- Change the path in step 0 to your Volume path.
-- =====================================================================

-- 0. Load the file as text, then reshape to one row per program per county column.
CREATE OR REPLACE TEMPORARY VIEW agency_raw AS
SELECT * FROM read_files(
  '/Volumes/example_catalog/reference/agency_files/agency_locations.csv',
  format => 'csv', header => true,
  schema => 'program_id STRING, program_name STRING, division STRING, hmis_project_type STRING, discontinued STRING, county_1 STRING, county_2 STRING, county_3 STRING, geo_code STRING, city STRING, project_city STRING, zip STRING, project_zip STRING'
);

CREATE OR REPLACE TEMPORARY VIEW agency_clean AS
SELECT
  program_id,
  upper(trim(program_name)) AS project_key,
  source_column,
  array_distinct(filter(
    transform(split(upper(coalesce(raw_county, '')), '[,/]'),
              x -> trim(regexp_replace(trim(x), ' COUNTY$', ''))),
    x -> x <> '')) AS counties
FROM (
  SELECT program_id, program_name,
         stack(3, 'county_1', county_1, 'county_2', county_2, 'county_3', county_3)
           AS (source_column, raw_county)
  FROM agency_raw
);

-- 1. Did it load? Expect 3,542 rows and 3,542 distinct names.
SELECT count(*) AS file_rows,
       count(DISTINCT upper(trim(program_name))) AS distinct_program_names
FROM agency_raw;

-- 2. Join rate: how many (project, organization) pairs in your data find a
--    program in the export by name? The strategy can only help matched pairs.
WITH pairs AS (
  SELECT DISTINCT project_name, organization_name
  FROM example_catalog.silver.admissions_enriched
),
names AS (SELECT DISTINCT upper(trim(program_name)) AS k FROM agency_raw)
SELECT count(*)                                     AS pairs,
       count_if(n.k IS NOT NULL)                    AS matched_by_name,
       round(100 * count_if(n.k IS NOT NULL) / count(*), 1) AS pct_matched
FROM pairs AS p
LEFT JOIN names AS n ON upper(trim(p.project_name)) = n.k;

-- 2b. Unmatched pairs, biggest first. Look for spelling or punctuation
--     differences you could fix, or programs missing from the export.
SELECT e.project_name, e.organization_name, count(*) AS enrollments
FROM example_catalog.silver.admissions_enriched AS e
LEFT JOIN (SELECT DISTINCT upper(trim(program_name)) AS k FROM agency_raw) AS n
  ON upper(trim(e.project_name)) = n.k
WHERE n.k IS NULL
GROUP BY e.project_name, e.organization_name
ORDER BY enrollments DESC
LIMIT 50;

-- 3. BACKTEST each county column against counties your data already reports.
--    Only programs with exactly one known county are compared.
--    The best column has the most "agrees" and the fewest "disagrees".
WITH known AS (
  SELECT upper(trim(project_name)) AS project_key, min(program_county) AS true_county
  FROM example_catalog.silver.admissions_enriched
  WHERE program_county IS NOT NULL
  GROUP BY upper(trim(project_name))
  HAVING count(DISTINCT program_county) = 1
)
SELECT c.source_column,
       count(*)                                                                  AS programs_compared,
       count_if(size(c.counties) = 1 AND try_element_at(c.counties, 1) =  upper(k.true_county)) AS agrees,
       count_if(size(c.counties) = 1 AND try_element_at(c.counties, 1) <> upper(k.true_county)) AS disagrees,
       count_if(size(c.counties) <> 1)                                           AS blank_or_multiple
FROM agency_clean AS c
JOIN known AS k ON c.project_key = k.project_key
GROUP BY c.source_column
ORDER BY c.source_column;

-- 3b. The disagreements themselves, for the column you are leaning towards.
--     Change county_1 to test another column.
WITH known AS (
  SELECT upper(trim(project_name)) AS project_key, min(program_county) AS true_county
  FROM example_catalog.silver.admissions_enriched
  WHERE program_county IS NOT NULL
  GROUP BY upper(trim(project_name))
  HAVING count(DISTINCT program_county) = 1
)
SELECT r.program_name, r.division, r.city, r.project_city,
       k.true_county AS county_in_your_data, c.counties AS county_in_export
FROM agency_clean AS c
JOIN known AS k ON c.project_key = k.project_key
JOIN agency_raw AS r ON upper(trim(r.program_name)) = c.project_key
WHERE c.source_column = 'county_1'
  AND size(c.counties) = 1
  AND try_element_at(c.counties, 1) <> upper(k.true_county);

-- 4. Impact: of the enrollments that currently have NO county in the source,
--    how many would each column resolve to a single county?
--    A NULL source_column means the program is not in the export at all.
SELECT c.source_column,
       count(*)                                 AS enrollments_missing_county,
       count_if(size(c.counties) = 1)           AS resolved_to_one_county
FROM example_catalog.silver.snapshot_dashboard AS s
LEFT JOIN agency_clean AS c ON upper(trim(s.project_name)) = c.project_key
WHERE s.source_program_county IS NULL
GROUP BY c.source_column
ORDER BY c.source_column;
