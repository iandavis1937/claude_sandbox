-- =============================================================================
-- Missingness rate per column, by project_type_description
-- =============================================================================
-- Two outputs:
--
-- 1. Long: one row per (project_type_description, column): how many rows the
--    group has, how many are NULL in that column, the share that is NULL, the
--    number of distinct non-NULL values, and those values sorted ascending
--    (sorted in the column's native type, so numbers/dates sort correctly,
--    then cast to STRING so every column fits in one ARRAY<STRING> output
--    column). `missing` flags the column for that project type:
--      'Yes'     no non-NULL values at all (n_unique = 0)
--      'Likely'  more than 97% NULL
--      'No'      otherwise
--
-- 2. Wide: one row per column, one `<project_type>_missing` column per project
--    type holding that flag, and n_project_types_missing = how many project
--    types are 'Yes' or 'Likely'. Project type names are turned into column
--    names the way janitor::clean_names() does it ('PH - Rapid Re-Housing' ->
--    ph_rapid_re_housing_missing; a NULL project type -> na_missing). Rows are
--    sorted by n_project_types_missing (most first), then column_name.
--
-- Note: high-cardinality columns (IDs, dates, timestamps) produce very large
-- unique_values arrays. Use n_unique to spot them, or exclude them in the
-- WHERE clause of the column list.
--
-- Set the table once in source_table below. The column list is read from the
-- table itself (not information_schema), so it works for Unity Catalog,
-- hive_metastore and views alike, and new columns are picked up automatically.
-- Needs EXECUTE IMMEDIATE, SQL variables and IDENTIFIER() (Databricks SQL
-- warehouses, or DBR 14.3+).
--
-- missingness_long is a temporary view, not a table, so each output re-scans
-- source_table.
--
-- Rows with a NULL project_type_description form their own group.
-- Only NULL counts as missing; to also count blank strings, change the
-- COUNT_IF to: COUNT_IF(`%s` IS NULL OR TRIM(CAST(`%s` AS STRING)) = '')
-- and pass col to format_string once more.
-- =============================================================================

DECLARE OR REPLACE VARIABLE source_table    STRING DEFAULT 'data_center_dev.hmis_silver.admissions_enriched';
DECLARE OR REPLACE VARIABLE missingness_sql STRING;
DECLARE OR REPLACE VARIABLE wide_sql        STRING;

SET VAR missingness_sql = (
  SELECT
    CASE WHEN COUNT(*) = 0
      THEN raise_error('No columns found: ' || source_table || ' is empty or does not exist')
      ELSE ''
    END
    || 'CREATE OR REPLACE TEMPORARY VIEW missingness_long AS '
    || 'SELECT *, '
    || '  CASE WHEN n_unique = 0 THEN \'Yes\' WHEN missing_rate > 0.97 THEN \'Likely\' ELSE \'No\' END AS missing '
    || 'FROM ('
    || 'SELECT project_type_description, column_name, __n_rows AS n_rows, n_missing, '
    || 'ROUND(n_missing / __n_rows, 4) AS missing_rate, '
    || 'size(unique_values) AS n_unique, slice(unique_values, 1, 30) AS unique_values '
    || 'FROM ('
    || '  SELECT project_type_description, COUNT(*) AS __n_rows, '
    ||      array_join(collect_list(format_string(
              'COUNT_IF(`%s` IS NULL) AS `__m_%s`, '
              || 'transform(array_sort(collect_set(`%s`)), x -> CAST(x AS STRING)) AS `__v_%s`',
              col, col, col, col)), ', ')
    || '  FROM ' || source_table
    || '  GROUP BY project_type_description'
    || ') AS t '
    || 'UNPIVOT INCLUDE NULLS ((n_missing, unique_values) FOR column_name IN ('
    ||      array_join(collect_list(format_string(
              '(`__m_%s`, `__v_%s`) AS `%s`', col, col, col)), ', ')
    || ')))'
  FROM (
    -- Column names from one row of the table; ignoreNullFields=false keeps
    -- columns that are NULL in that row.
    SELECT replace(column_name, '`', '``') AS col      -- escape backticks in names
    FROM (
      SELECT explode(json_object_keys(
               to_json(struct(*), map('ignoreNullFields', 'false')))) AS column_name
      FROM (SELECT * FROM IDENTIFIER(source_table) LIMIT 1)
    )
    WHERE column_name <> 'project_type_description'
  )
);

EXECUTE IMMEDIATE missingness_sql;

-- Output 1: long
SELECT *
FROM missingness_long
ORDER BY project_type_description NULLS FIRST, missing_rate DESC, column_name;

-- Output 2: wide. One CASE per project type, NULL project type first.
SET VAR wide_sql = (
  SELECT
    'SELECT column_name, '
    || array_join(transform(array_sort(collect_list(struct(sort_key, pivot_col))), x -> x.pivot_col), ', ')
    || ', COUNT_IF(missing IN (\'Yes\', \'Likely\')) AS n_project_types_missing '
    || 'FROM missingness_long '
    || 'GROUP BY column_name '
    || 'ORDER BY n_project_types_missing DESC, column_name'
  FROM (
    SELECT
      struct(project_type_description IS NOT NULL, project_type_description) AS sort_key,
      format_string(
        'MAX(CASE WHEN %s THEN missing END) AS `%s_missing`',
        CASE WHEN project_type_description IS NULL
          THEN 'project_type_description IS NULL'
          -- escape backslashes and single quotes for the string literal
          ELSE 'project_type_description = \''
               || replace(replace(project_type_description, '\\', '\\\\'), '\'', '\\\'')
               || '\''
        END,
        -- janitor::clean_names() defaults: drop quotes, % -> percent,
        -- # -> number, split camelCase, other non-alphanumerics -> _,
        -- lower case, leading digit -> x prefix
        regexp_replace(
          regexp_replace(
            lower(regexp_replace(
              regexp_replace(
                regexp_replace(
                  replace(replace(regexp_replace(coalesce(project_type_description, 'NA'),
                                                 '[\'"]', ''),
                                  '%', '_percent_'), '#', '_number_'),
                  '([a-z0-9])([A-Z])', '$1_$2'),
                '([A-Z])([A-Z][a-z])', '$1_$2'),
              '[^A-Za-z0-9]+', '_')),
            '^_+|_+$', ''),
          '^([0-9])', 'x$1')
      ) AS pivot_col
    FROM (SELECT DISTINCT project_type_description FROM IDENTIFIER(source_table))
  )
);

EXECUTE IMMEDIATE wide_sql;
