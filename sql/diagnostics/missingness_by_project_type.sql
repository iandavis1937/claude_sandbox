-- =============================================================================
-- Missingness rate per column, by project_type_description
-- =============================================================================
-- One row per (project_type_description, column): how many rows the group has,
-- how many are NULL in that column, and the share that is NULL.
--
-- The column list is read from information_schema, so new columns are picked
-- up automatically. Needs EXECUTE IMMEDIATE and SQL variables (Databricks SQL
-- warehouses, or DBR 14.3+). To run it against another table, change the
-- three names in the WHERE clause and the FROM inside the generated query.
--
-- Rows with a NULL project_type_description form their own group.
-- Only NULL counts as missing; to also count blank strings, change the
-- COUNT_IF to: COUNT_IF(`col` IS NULL OR TRIM(CAST(`col` AS STRING)) = '')
-- =============================================================================

DECLARE OR REPLACE VARIABLE missingness_sql STRING;

SET VAR missingness_sql = (
  SELECT
    'SELECT project_type_description, column_name, __n_rows AS n_rows, n_missing, '
    || 'ROUND(n_missing / __n_rows, 4) AS missing_rate '
    || 'FROM ('
    || '  SELECT project_type_description, COUNT(*) AS __n_rows, '
    ||      array_join(collect_list(format_string('COUNT_IF(`%s` IS NULL) AS `%s`', col, col)), ', ')
    || '  FROM example_catalog.silver.admissions_enriched'
    || '  GROUP BY project_type_description'
    || ') AS t '
    || 'UNPIVOT (n_missing FOR column_name IN ('
    ||      array_join(collect_list(format_string('`%s`', col)), ', ')
    || ')) '
    || 'ORDER BY project_type_description NULLS FIRST, missing_rate DESC, column_name'
  FROM (
    SELECT replace(column_name, '`', '``') AS col      -- escape backticks in names
    FROM example_catalog.information_schema.columns
    WHERE table_catalog = 'example_catalog'
      AND table_schema  = 'silver'
      AND table_name    = 'admissions_enriched'
      AND column_name <> 'project_type_description'
  )
);

EXECUTE IMMEDIATE missingness_sql;
