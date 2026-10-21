-- =============================================================================
-- Missingness rate per column, by project_type_description
-- =============================================================================
-- One row per (project_type_description, column): how many rows the group has,
-- how many are NULL in that column, and the share that is NULL.
--
-- Set the table once in source_table below. The column list is read from the
-- table itself (not information_schema), so it works for Unity Catalog,
-- hive_metastore and views alike, and new columns are picked up automatically.
-- Needs EXECUTE IMMEDIATE, SQL variables and IDENTIFIER() (Databricks SQL
-- warehouses, or DBR 14.3+).
--
-- Rows with a NULL project_type_description form their own group.
-- Only NULL counts as missing; to also count blank strings, change the
-- COUNT_IF to: COUNT_IF(`%s` IS NULL OR TRIM(CAST(`%s` AS STRING)) = '')
-- and pass col to format_string once more.
-- =============================================================================

DECLARE OR REPLACE VARIABLE source_table    STRING DEFAULT 'data_center_dev.silver.admissions_enriched';
DECLARE OR REPLACE VARIABLE missingness_sql STRING;

SET VAR missingness_sql = (
  SELECT
    CASE WHEN COUNT(*) = 0
      THEN raise_error('No columns found: ' || source_table || ' is empty or does not exist')
      ELSE ''
    END
    || 'SELECT project_type_description, column_name, __n_rows AS n_rows, n_missing, '
    || 'ROUND(n_missing / __n_rows, 4) AS missing_rate '
    || 'FROM ('
    || '  SELECT project_type_description, COUNT(*) AS __n_rows, '
    ||      array_join(collect_list(format_string('COUNT_IF(`%s` IS NULL) AS `%s`', col, col)), ', ')
    || '  FROM ' || source_table
    || '  GROUP BY project_type_description'
    || ') AS t '
    || 'UNPIVOT (n_missing FOR column_name IN ('
    ||      array_join(collect_list(format_string('`%s`', col)), ', ')
    || ')) '
    || 'ORDER BY project_type_description NULLS FIRST, missing_rate DESC, column_name'
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
