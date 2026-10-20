-- ================================================================
-- HMIS Dashboard Demographic Aggregation Table
-- Source: example_catalog.silver.snapshot_dashboard
-- Grain: (month_start, program_county, population_type, race,
--         household_category, age_group, disabling_condition,
--         is_veteran)
-- Window: trailing 5 years (60 months) through the current month.
--
-- Dedup rule: each person contributes exactly ONE row per month.
-- When a person has multiple enrollments active in the same month,
-- one enrollment is chosen as that person's "canonical" record for
-- the month, in this priority order:
--   1. Sheltered beats Unsheltered   (matches DAX: Unsheltered
--      Homeless Count already excludes anyone also Sheltered)
--   2. Still-open (exit_date IS NULL) beats closed
--   3. Most recent entry_date breaks remaining ties
-- This makes COUNT(DISTINCT personal_id) safely additive across
-- every dimension in the GROUP BY -- SUM(homeless_count) sliced any
-- way will equal a true distinct-person count, matching
-- [Total Homeless Count] in the Power BI model.
-- ================================================================

CREATE OR REPLACE TABLE example_catalog.gold.snapshot_dashboard AS
WITH bounds AS (
    SELECT
        date_trunc('month', add_months(current_date(), -60)) AS window_start,
        last_day(date_trunc('month', current_date()))         AS window_end
),

active_records AS (
    SELECT
        d.personal_id,
        d.program_county,
        d.population_type,
        d.race,
        d.race_sort,
        d.household_size_category,
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
            least(date_trunc('month', COALESCE(d.exit_date, current_date())), b.window_end),
            interval 1 month
        )) AS month_start
    FROM example_catalog.silver.snapshot_dashboard d
    CROSS JOIN bounds b
    WHERE d.entry_date IS NOT NULL
      AND d.entry_date <= last_day(b.window_end)
      AND (d.exit_date IS NULL OR d.exit_date >= b.window_start)
),

canonical_person_month AS (
    SELECT *
    FROM (
        SELECT
            ar.*,
            ROW_NUMBER() OVER (
                PARTITION BY ar.personal_id, ar.month_start
                ORDER BY
                    CASE WHEN ar.population_type = 'Sheltered' THEN 0 ELSE 1 END,
                    CASE WHEN ar.exit_date IS NULL THEN 0 ELSE 1 END,
                    ar.entry_date DESC
            ) AS rn
        FROM active_records ar
    )
    WHERE rn = 1
),

-- Post-dedup fallback: fill NULL detailed_household_category from
-- other active enrollments for the same person-month (most recent
-- entry preferred). Currently affects ~65 persons whose canonical
-- enrollment's household_id is missing from the households table.
hh_fallback AS (
    SELECT personal_id, month_start, detailed_household_category
    FROM (
        SELECT
            personal_id, month_start, detailed_household_category,
            ROW_NUMBER() OVER (
                PARTITION BY personal_id, month_start
                ORDER BY entry_date DESC
            ) AS fb_rn
        FROM active_records
        WHERE detailed_household_category IS NOT NULL
    )
    WHERE fb_rn = 1
),

canonical_filled AS (
    SELECT
        cpm.* EXCEPT (detailed_household_category, rn),
        COALESCE(cpm.detailed_household_category, fb.detailed_household_category)
            AS detailed_household_category
    FROM canonical_person_month cpm
    LEFT JOIN hh_fallback fb
      ON fb.personal_id = cpm.personal_id
     AND fb.month_start = cpm.month_start
)

SELECT
    month_start,
    YEAR(month_start)                    AS year,
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
    COUNT(DISTINCT personal_id)          AS homeless_count,
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
    project_type_grouped, project_type_grouped_sort
ORDER BY month_start, program_county;

