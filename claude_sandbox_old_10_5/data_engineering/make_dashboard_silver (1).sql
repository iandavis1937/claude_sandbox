-- ================================================================
-- HMIS Dashboard Table
-- Requires: example_catalog.silver.program_county_lookup
--           (built by make_program_county_lookup.sql — run first)
-- Source:   example_catalog.silver.admissions_enriched
-- ================================================================

CREATE OR REPLACE TABLE example_catalog.silver.snapshot_dashboard AS
WITH admissions AS (
    SELECT
        -- Join keys
        enrollment_id,
        personal_id,
        household_id,
        project_name,
        organization_name,

        -- Passthrough to snapshot_dashboard
        entry_date,
        exit_date,
        project_type_description,
        has_any_disability,
        veteran_status,
        
        -- Fed into outer-SELECT CASE expressions
        race_am_ind_ak_native,
        race_asian,
        race_black,
        race_hispanic_latino,
        race_mid_east_n_african,
        race_native_hi_pacific,
        race_white,
        race_none,
        age_at_entry,
        dob_data_quality,
        program_county,
        population_type,
        disabling_condition,
        is_veteran
    FROM example_catalog.silver.admissions_enriched
    -- Restrict to the 5 project types the report actually uses
    WHERE project_type_description IN (
        'Emergency Shelter - Entry Exit',
        'Emergency Shelter - Night-by-Night',
        'Street Outreach',
        'Transitional Housing',
        'Safe Haven'
    )
),

homeless_causes AS (
    -- Guard against join fan-out: keep one row per (personal_id,
    -- EnrollmentID). The ORDER BY tiebreakers prefer the most recent
    -- source_year, then alphabetically first non-null cause.
    --
    -- TESTED 2026-09-28: the grain is already naturally unique —
    -- 886,709 groups, max 1 row each (across source_years 2022-2026).
    -- The ROW_NUMBER + ORDER BY are purely defensive; none of the
    -- tiebreakers currently fire. Retained as a safety net in case
    -- future data loads introduce duplicates.
    SELECT personal_id, EnrollmentID, homeless_cause
    FROM (
        SELECT personal_id, EnrollmentID, homeless_cause, source_year,
               ROW_NUMBER() OVER (
                   PARTITION BY personal_id, EnrollmentID
                   ORDER BY personal_id, source_year DESC, homeless_cause ASC NULLS LAST
               ) AS rn
        FROM example_catalog.bronze.homeless_causes
    )
    WHERE rn = 1
),

households AS (
    -- Pre-filter households to only the household_ids that survive
    -- the admissions project-type filter
    SELECT *
    FROM example_catalog.silver.households
    WHERE household_id IN (SELECT DISTINCT household_id FROM admissions)
)

SELECT /*+ BROADCAST(hc), BROADCAST(cpm), BROADCAST(pcl) */
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

    -- ------------------------------------------------------------
    -- Repair missing program_county values using program names
    -- mapped to counties in a lookup table
    --     - Audit columns in the lookup table show whether the 
    --       county was inferred from the project name or 
    --       externally researched (i.e. via web search).
    -- ------------------------------------------------------------
    COALESCE(a.program_county, pcl.lookup_program_county) AS program_county,
    a.program_county AS source_program_county,
    COALESCE(
        CASE WHEN a.program_county IS NULL THEN pcl.program_county_inferred END,
        FALSE
    ) AS program_county_inferred,
    COALESCE(
        CASE WHEN a.program_county IS NULL THEN pcl.program_county_external_research END,
        FALSE
    ) AS program_county_external_research,
    CASE
        WHEN a.program_county IS NOT NULL THEN 'source'
        ELSE pcl.lookup_method
    END AS program_county_lookup_method,

    -- ------------------------------------------------------------
    -- Recode race: collapse the one-hot race_* flag columns into a
    -- single label and make fixed display-order sort key.
    -- ------------------------------------------------------------
    CASE
        -- White + Hispanic/Latino only → classify as Hispanic or Latino
        WHEN a.race_hispanic_latino = '1'
         AND a.race_white           = '1'
         AND (
                (CASE WHEN a.race_am_ind_ak_native  = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_asian              = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_black              = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_mid_east_n_african = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_native_hi_pacific  = '1' THEN 1 ELSE 0 END)
             ) = 0
        THEN 'Hispanic or Latino'
        WHEN (
            (CASE WHEN a.race_am_ind_ak_native = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_asian             = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_black             = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_hispanic_latino   = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_mid_east_n_african = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_native_hi_pacific = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_white             = '1' THEN 1 ELSE 0 END)
        ) > 1 THEN 'Multiracial'
        WHEN a.race_am_ind_ak_native   = '1' THEN 'American Indian or Alaska Native'
        WHEN a.race_asian              = '1' THEN 'Asian'
        WHEN a.race_black              = '1' THEN 'Black'
        WHEN a.race_hispanic_latino    = '1' THEN 'Hispanic or Latino'
        WHEN a.race_mid_east_n_african = '1' THEN 'Middle Eastern or North African'
        WHEN a.race_native_hi_pacific  = '1' THEN 'Native Hawaiian or Other Pacific Islander'
        WHEN a.race_white              = '1' THEN 'White'
        ELSE 'Unknown'
    END AS race,

    CASE
        -- White + Hispanic/Latino only → sort as Hispanic or Latino
        WHEN a.race_hispanic_latino = '1'
         AND a.race_white           = '1'
         AND (
                (CASE WHEN a.race_am_ind_ak_native  = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_asian              = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_black              = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_mid_east_n_african = '1' THEN 1 ELSE 0 END)
              + (CASE WHEN a.race_native_hi_pacific  = '1' THEN 1 ELSE 0 END)
             ) = 0
        THEN 4
        WHEN (
            (CASE WHEN a.race_am_ind_ak_native = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_asian             = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_black             = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_hispanic_latino   = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_mid_east_n_african = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_native_hi_pacific = '1' THEN 1 ELSE 0 END)
          + (CASE WHEN a.race_white             = '1' THEN 1 ELSE 0 END)
        ) > 1 THEN 8
        WHEN a.race_am_ind_ak_native   = '1' THEN 1
        WHEN a.race_asian              = '1' THEN 2
        WHEN a.race_black              = '1' THEN 3
        WHEN a.race_hispanic_latino    = '1' THEN 4
        WHEN a.race_mid_east_n_african = '1' THEN 5
        WHEN a.race_native_hi_pacific  = '1' THEN 6
        WHEN a.race_white              = '1' THEN 7
        ELSE 9
    END AS race_sort,

    -- race_detail: spells out every flagged race in alphabetical
    -- order so "Multiracial" rows are human-readable.
    COALESCE(NULLIF(CONCAT_WS(', ',
        CASE WHEN a.race_am_ind_ak_native  = '1' THEN 'American Indian or Alaska Native' END,
        CASE WHEN a.race_asian             = '1' THEN 'Asian' END,
        CASE WHEN a.race_black             = '1' THEN 'Black' END,
        CASE WHEN a.race_hispanic_latino   = '1' THEN 'Hispanic or Latino' END,
        CASE WHEN a.race_mid_east_n_african = '1' THEN 'Middle Eastern or North African' END,
        CASE WHEN a.race_native_hi_pacific = '1' THEN 'Native Hawaiian or Other Pacific Islander' END,
        CASE WHEN a.race_white             = '1' THEN 'White' END
    ), ''), 'Unknown') AS race_detail,

    -- ------------------------------------------------------------
    -- Recompute age_group: bucket age_at_entry into bands
    -- (replaces the source age_group column entirely), and make
    -- sort key.
    -- ------------------------------------------------------------
    CASE
        WHEN a.age_at_entry IS NULL 
            OR a.dob_data_quality > 2
            OR a.age_at_entry < 0
            OR a.age_at_entry > 100
            THEN 'Unknown'
        WHEN a.age_at_entry < 18  THEN 'Under 18'
        WHEN a.age_at_entry <= 24 THEN '18-24'
        WHEN a.age_at_entry <= 34 THEN '25-34'
        WHEN a.age_at_entry <= 44 THEN '35-44'
        WHEN a.age_at_entry <= 54 THEN '45-54'
        WHEN a.age_at_entry <= 61 THEN '55-61'
        WHEN a.age_at_entry <= 100 THEN '62+'
        ELSE 'NA'
    END AS age_group,

    CAST(
    CASE
        WHEN a.age_at_entry IS NULL 
            OR a.dob_data_quality > 2
            OR a.age_at_entry < 0
            OR a.age_at_entry > 100
            THEN 8  -- Unknown
        WHEN a.age_at_entry < 18  THEN 1
        WHEN a.age_at_entry <= 24 THEN 2
        WHEN a.age_at_entry <= 34 THEN 3
        WHEN a.age_at_entry <= 44 THEN 4
        WHEN a.age_at_entry <= 54 THEN 5
        WHEN a.age_at_entry <= 61 THEN 6
        WHEN a.age_at_entry <= 100 THEN 7
        ELSE 9  -- NA
      END AS BIGINT
    ) AS age_group_sort,

    -- ------------------------------------------------------------
    -- Attach homeless_cause: left-join the dedup'd cause lookup,
    -- default to 'No Match' where no cause record exists.
    -- ------------------------------------------------------------
    COALESCE(hc.homeless_cause, 'No Match') AS homeless_cause,

    -- ------------------------------------------------------------
    -- Group project_type_description into report-level buckets
    -- (Shelter / Permanent Housing / pass-through), plus sort key.
    -- ------------------------------------------------------------
    CASE
        WHEN a.project_type_description IN (
            'Day Shelter',
            'Emergency Shelter - Entry Exit',
            'Emergency Shelter - Night-by-Night',
            'Safe Haven'
        ) THEN 'Shelter'
        WHEN a.project_type_description LIKE 'PH - %' THEN 'Permanent Housing'
        ELSE a.project_type_description
    END AS project_type_grouped,

    CASE
        WHEN a.project_type_description IN (
            'Day Shelter',
            'Emergency Shelter - Entry Exit',
            'Emergency Shelter - Night-by-Night',
            'Safe Haven'
        ) THEN 1
        WHEN a.project_type_description = 'Homelessness Prevention' THEN 2
        WHEN a.project_type_description LIKE 'PH - %' THEN 3
        WHEN a.project_type_description = 'Transitional Housing' THEN 4
        ELSE 5
    END AS project_type_grouped_sort,

    -- ------------------------------------------------------------
    -- Recode population_type: collapse source categories into
    -- Sheltered / Unsheltered, while preserving the original raw
    -- value alongside it as population_type_test.
    -- ------------------------------------------------------------
    CASE a.population_type
        WHEN 'Sheltered Homelessness'            THEN 'Sheltered'
        WHEN 'Transitional Housing Programs'     THEN 'Sheltered'
        WHEN 'Unsheltered Homelessness Programs' THEN 'Unsheltered'
        ELSE a.population_type
    END AS population_type,
    a.population_type AS population_type_test,   -- unmodified copy of the source value

    -- ------------------------------------------------------------
    -- Recode disabling_condition: map coded values to labels
    -- and make sort key.
    -- ------------------------------------------------------------
    CASE a.disabling_condition
        WHEN '0'  THEN 'No'
        WHEN '1'  THEN 'Yes'
        WHEN '8'  THEN 'Unknown'
        WHEN '99' THEN 'Unknown'
        WHEN '9'  THEN 'Unknown'
        ELSE a.disabling_condition
    END AS disabling_condition,

    CASE
        WHEN a.disabling_condition = '1' THEN 1   -- 'Yes'
        WHEN a.disabling_condition = '0' THEN 2   -- 'No'
        ELSE 3
    END AS disabling_condition_sort,

    -- ------------------------------------------------------------
    -- Recode is_veteran into a display label with sort order.
    -- ------------------------------------------------------------
    CASE WHEN a.is_veteran
        THEN 'Veteran' 
        ELSE 'Not a Veteran' 
    END AS is_veteran,

    CASE WHEN a.is_veteran
        THEN 1 
        ELSE 2 
    END AS is_veteran_sort,

    -- ------------------------------------------------------------
    -- Household-level attributes (many-to-one via household_id)
    -- ------------------------------------------------------------
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

    -- ------------------------------------------------------------
    -- County population (via repaired program_county -> County)
    -- ------------------------------------------------------------
    cpm.Population AS county_population

    -- ------------------------------------------------------------
    -- Date-part breakdown:
    -- Reproduce Power BI auto-generated Year/MonthNo/Month/QuarterNo/
    -- Quarter/Day hierarchy off [Date] for entry_date and exit_date
    -- (Power BI makes for every date column in the visual)
    -- ------------------------------------------------------------
    -- YEAR(a.entry_date)                                AS entry_date_year,
    -- MONTH(a.entry_date)                               AS entry_date_month_no,
    -- DATE_FORMAT(a.entry_date, 'MMMM')                 AS entry_date_month,
    -- CAST(FLOOR((MONTH(a.entry_date) + 2) / 3) AS INT) AS entry_date_quarter_no,
    -- CONCAT('Qtr ', CAST(FLOOR((MONTH(a.entry_date) + 2) / 3) AS INT)) AS entry_date_quarter,
    -- DAY(a.entry_date)                                 AS entry_date_day,

    -- YEAR(a.exit_date)                                 AS exit_date_year,
    -- MONTH(a.exit_date)                                AS exit_date_month_no,
    -- DATE_FORMAT(a.exit_date, 'MMMM')                  AS exit_date_month,
    -- CAST(FLOOR((MONTH(a.exit_date) + 2) / 3) AS INT)  AS exit_date_quarter_no,
    -- CONCAT('Qtr ', CAST(FLOOR((MONTH(a.exit_date) + 2) / 3) AS INT)) AS exit_date_quarter,
    -- DAY(a.exit_date)                                  AS exit_date_day

FROM admissions a
LEFT JOIN homeless_causes hc
       ON a.personal_id   = hc.personal_id
      AND a.enrollment_id = hc.EnrollmentID
LEFT JOIN households h
       ON a.household_id  = h.household_id
LEFT JOIN example_catalog.silver.program_county_lookup pcl
       ON a.project_name = pcl.project_name
      AND a.organization_name = pcl.organization_name
LEFT JOIN example_catalog.reference.county_population_mapping cpm
       ON COALESCE(a.program_county, pcl.lookup_program_county) = cpm.County;
    
-- BROADCAST hints applied above for hc (dedup'd homeless_causes),
-- pcl (program_county_lookup), and cpm (county_population_mapping — ~21 rows).
-- The households join (h) is left to the optimizer since that table is larger.
-- Run ANALYZE TABLE on each source if you want cost-based optimization
-- for the remaining joins as well.