-- =============================================================================
-- mv_enrollment_homeless_status
-- =============================================================================
-- Enrollment-grain replacement for the per-program "active" gold views:
--   mv_active_services, mv_active_ce_individuals, mv_active_hp_enrollment,
--   mv_active_street_outreach, mv_active_day_shelter_individuals,
--   mv_active_es_enrollment_by_year, mv_active_rapid_rehousing,
--   mv_active_transitional_housing_enrollments, mv_active_safe_haven_enrollments
-- and the roll-ups built on them:
--   mv_active_sheltered, mv_active_unsheltered, mv_active_homeless
--
-- Instead of one view per program, every enrollment in admissions_enriched gets
-- the flags those views computed implicitly:
--   program_group              normalized program (HUD 0 and 1 both -> Emergency Shelter)
--   last_contact_date          latest non-deleted Current Living Situation record
--   current_living_situation   living situation recorded at that contact
--   has_active_shelter_enrollment / has_active_so_enrollment
--                              person-level concurrency flags (used by Coordinated Entry)
--   homeless_status            'Sheltered' | 'Unsheltered' | 'Unknown' | NULL (not classified)
--   homeless_status_basis      which rule produced homeless_status (for auditing)
--   is_active_ohp              open enrollment AND inside its program's reporting window
--   is_most_recent_enrollment  person's latest *active* enrollment within program_group
--   is_primary_homeless_record one counted row per person across all programs (optional)
--
-- Reference codes
--   HUD project types: 0/1 ES, 2 TH, 4 SO, 6 Services Only, 8 Safe Haven,
--                      11 Day Shelter, 12 HP, 13 RRH, 14 CE
--   Living situation:  101 ES, 118 Safe Haven, 302 TH -> Sheltered
--                      116 place not meant for habitation -> Unsheltered
--
-- The logic below reproduces the existing views, quirks included; each quirk is
-- marked "PARITY:" with the one-line change that would fix it.
-- =============================================================================

CREATE OR REPLACE MATERIALIZED VIEW data_center_dev.hmis_gold.mv_enrollment_homeless_status
  COMMENT 'Enrollment-grain homeless status and OHP activity flags. Replaces the per-program mv_active_* views.'
  SCHEDULE CRON '0 0 6 * * ? *' AT TIME ZONE 'America/New_York'
  CLUSTER BY (program_group, entry_date) AS

-- Latest contact per enrollment. Cast to DATE so every consumer sees one type
-- (the old views mixed STRING and DATE for last_contact_date).
WITH last_contact AS (
  SELECT
    EnrollmentID AS enrollment_id,
    MAX(CAST(InformationDate AS DATE)) AS last_contact_date,
    MAX_BY(CurrentLivingSituation, InformationDate) AS current_living_situation
  FROM data_center_dev.hmis_bronze.current_living_situation
  WHERE DateDeleted IS NULL
  GROUP BY EnrollmentID
),

-- Every enrollment plus its program group and contact data.
-- Note: the old CE and Day Shelter views matched on project_type_description
-- ('Coordinated Entry', 'Day Shelter'); this maps by code. Verify they agree.
base AS (
  SELECT
    a.*,
    CASE
      WHEN a.project_type_code IN ('0', '1') THEN 'Emergency Shelter'
      WHEN a.project_type_code = '2'  THEN 'Transitional Housing'
      WHEN a.project_type_code = '4'  THEN 'Street Outreach'
      WHEN a.project_type_code = '6'  THEN 'Services Only'
      WHEN a.project_type_code = '8'  THEN 'Safe Haven'
      WHEN a.project_type_code = '11' THEN 'Day Shelter'
      WHEN a.project_type_code = '12' THEN 'Homelessness Prevention'
      WHEN a.project_type_code = '13' THEN 'Rapid Re-Housing'
      WHEN a.project_type_code = '14' THEN 'Coordinated Entry'
    END AS program_group,
    lc.last_contact_date,
    lc.current_living_situation
  FROM data_center_dev.hmis_silver.admissions_enriched a
    LEFT JOIN last_contact lc
      ON a.enrollment_id = lc.enrollment_id
),

-- Person-level concurrency, from the old CE view's concurrent_status CTE.
-- Considers any open enrollment, regardless of its reporting window.
person_concurrent AS (
  SELECT
    personal_id,
    BOOL_OR(project_type_code IN ('0', '1', '2', '8', '11')) AS has_active_shelter_enrollment,
    BOOL_OR(project_type_code = '4') AS has_active_so_enrollment
  FROM base
  WHERE is_active_enrollment = TRUE
  GROUP BY personal_id
),

flagged AS (
  SELECT
    b.*,
    COALESCE(pc.has_active_shelter_enrollment, FALSE) AS has_active_shelter_enrollment,
    COALESCE(pc.has_active_so_enrollment, FALSE) AS has_active_so_enrollment,

    -- Status from the latest contact, falling back to living situation at entry
    -- (Services Only and RRH rule).
    CASE
      WHEN COALESCE(b.current_living_situation, b.living_situation_prior) IN ('101', '118', '302') THEN 'Sheltered'
      WHEN COALESCE(b.current_living_situation, b.living_situation_prior) = '116' THEN 'Unsheltered'
      ELSE 'Unknown'
    END AS contact_based_status,

    -- Status from living situation at entry only (CE fallback rule).
    CASE
      WHEN b.living_situation_prior IN ('101', '118', '302') THEN 'Sheltered'
      WHEN b.living_situation_prior = '116' THEN 'Unsheltered'
      ELSE 'Unknown'
    END AS entry_based_status,

    -- Latest open enrollment per person within the program group. Ranking all
    -- open enrollments (not just in-window ones) matches every old view:
    --   * Services Only and SO ranked first, then applied their window.
    --   * ES, HP, RRH and Day Shelter windowed first, but their windows only set
    --     a lower bound on entry_date, so if any enrollment is in window the
    --     latest one is too.
    -- Exception: Day Shelter also capped entry_date at today; a future-dated
    -- latest entry now drops the person instead of falling back to an older one.
    -- enrollment_id DESC is a new deterministic tie-break (several old views had none).
    CASE
      WHEN b.is_active_enrollment = TRUE
      THEN ROW_NUMBER() OVER (
             PARTITION BY b.personal_id, b.program_group, b.is_active_enrollment
             ORDER BY b.entry_date DESC, b.enrollment_id DESC
           ) = 1
      ELSE FALSE
    END AS is_most_recent_enrollment
  FROM base b
    LEFT JOIN person_concurrent pc
      ON b.personal_id = pc.personal_id
),

statused AS (
  SELECT
    * EXCEPT (contact_based_status, entry_based_status),

    CASE
      -- Housing programs prove status by enrollment alone.
      WHEN program_group IN ('Emergency Shelter', 'Transitional Housing', 'Safe Haven', 'Day Shelter') THEN 'Sheltered'
      WHEN program_group = 'Street Outreach' THEN 'Unsheltered'
      -- CE: a concurrent shelter stay wins, then concurrent SO, then entry living situation.
      -- PARITY: CE ignores contact records; use contact_based_status in the last branch to align with Services/RRH.
      WHEN program_group = 'Coordinated Entry' AND has_active_shelter_enrollment THEN 'Sheltered'
      WHEN program_group = 'Coordinated Entry' AND has_active_so_enrollment THEN 'Unsheltered'
      WHEN program_group = 'Coordinated Entry' THEN entry_based_status
      -- PARITY: RRH status ignores move_in_date; HUD treats RRH clients as homeless only until move-in.
      WHEN program_group IN ('Services Only', 'Rapid Re-Housing') THEN contact_based_status
      -- HP (at risk, not homeless) and unmapped project types are not classified.
    END AS homeless_status,

    CASE
      WHEN program_group IN ('Emergency Shelter', 'Transitional Housing', 'Safe Haven', 'Day Shelter', 'Street Outreach') THEN 'project_type'
      WHEN program_group = 'Coordinated Entry' AND (has_active_shelter_enrollment OR has_active_so_enrollment) THEN 'concurrent_enrollment'
      WHEN program_group = 'Coordinated Entry' THEN 'prior_living_situation'
      WHEN program_group IN ('Services Only', 'Rapid Re-Housing') AND current_living_situation IS NOT NULL THEN 'current_living_situation'
      WHEN program_group IN ('Services Only', 'Rapid Re-Housing') THEN 'prior_living_situation'
    END AS homeless_status_basis,

    -- Open enrollment inside its program's reporting window. Windows are copied
    -- from the old views as-is.
    -- PARITY: the windows are inconsistent across programs (calendar year,
    -- rolling 365 days, 24 months, 2 and 3 years, none); consider one shared window.
    is_active_enrollment = TRUE AND COALESCE(
      CASE program_group
        -- Entry or last contact in the current calendar year.
        WHEN 'Services Only' THEN
          YEAR(entry_date) = YEAR(CURRENT_DATE()) OR YEAR(last_contact_date) = YEAR(CURRENT_DATE())
        -- Entry in the current calendar year, or contact in the last 365 days.
        WHEN 'Street Outreach' THEN
          YEAR(entry_date) = YEAR(CURRENT_DATE()) OR last_contact_date >= DATE_SUB(CURRENT_DATE(), 365)
        WHEN 'Coordinated Entry' THEN
          entry_date >= ADD_MONTHS(CURRENT_DATE(), -24)
        WHEN 'Homelessness Prevention' THEN
          entry_date >= DATEADD(YEAR, -3, CURRENT_DATE())
        -- Jan 1 of last year through today.
        WHEN 'Day Shelter' THEN
          entry_date BETWEEN MAKE_DATE(YEAR(CURRENT_DATE()) - 1, 1, 1) AND CURRENT_DATE()
        -- Jan 1 of last year onward.
        WHEN 'Emergency Shelter' THEN
          entry_date >= MAKE_DATE(YEAR(CURRENT_DATE()) - 1, 1, 1)
        -- Jan 1 two years ago onward.
        WHEN 'Rapid Re-Housing' THEN
          entry_date >= MAKE_DATE(YEAR(CURRENT_DATE()) - 2, 1, 1)
        -- No window in the old views.
        WHEN 'Transitional Housing' THEN TRUE
        WHEN 'Safe Haven' THEN TRUE
        ELSE FALSE
      END, FALSE) AS is_active_ohp
  FROM flagged
)

SELECT
  *,
  -- One row per person across all programs. The old roll-ups never removed
  -- cross-program duplicates, so a person could be counted several times, or as
  -- both Sheltered and Unsheltered. Sheltered wins (HUD PIT precedence), then a
  -- status proven by project type, then the latest entry.
  CASE
    WHEN is_active_ohp AND is_most_recent_enrollment
         AND homeless_status IN ('Sheltered', 'Unsheltered')
    THEN ROW_NUMBER() OVER (
           PARTITION BY personal_id,
             (is_active_ohp AND is_most_recent_enrollment AND homeless_status IN ('Sheltered', 'Unsheltered'))
           ORDER BY
             CASE homeless_status WHEN 'Sheltered' THEN 0 ELSE 1 END,
             CASE WHEN homeless_status_basis = 'project_type' THEN 0 ELSE 1 END,
             entry_date DESC,
             enrollment_id DESC
         ) = 1
    ELSE FALSE
  END AS is_primary_homeless_record
FROM statused;


-- =============================================================================
-- Replacing the old views
-- =============================================================================
-- Each old view becomes a filter on mv_enrollment_homeless_status (as a plain
-- view, or inline in dashboards). Filters below give row-for-row parity, apart
-- from the Day Shelter and tie-break notes above.
--
-- Per-program (deduplicated in the old views):
--   Services Only, Street Outreach, HP, Day Shelter, Emergency Shelter, RRH
--     WHERE program_group = '<group>' AND is_active_ohp AND is_most_recent_enrollment
--
-- Per-program (NOT deduplicated in the old views):
--   Coordinated Entry, Transitional Housing, Safe Haven
--     WHERE program_group = '<group>' AND is_active_ohp
--   PARITY: add AND is_most_recent_enrollment to deduplicate these too.
--
-- mv_active_sheltered:
--     WHERE is_active_ohp
--       AND homeless_status = 'Sheltered'
--       AND (is_most_recent_enrollment
--            OR program_group IN ('Coordinated Entry', 'Transitional Housing', 'Safe Haven'))
--
-- mv_active_unsheltered:
--     WHERE is_active_ohp
--       AND homeless_status = 'Unsheltered'
--       AND is_most_recent_enrollment
--       AND program_group <> 'Coordinated Entry'
--   PARITY: the old view left out CE Unsheltered people; drop the last condition to include them.
--
-- mv_active_homeless (old behaviour, with duplicates):
--     WHERE is_active_ohp
--       AND homeless_status IN ('Sheltered', 'Unsheltered')
--       AND (is_most_recent_enrollment
--            OR program_group IN ('Coordinated Entry', 'Transitional Housing', 'Safe Haven'))
--       AND NOT (program_group = 'Coordinated Entry' AND homeless_status = 'Unsheltered')
--
-- mv_active_homeless (one row per person):
--     WHERE is_primary_homeless_record
--
-- Example parity check before switching a dashboard over (run both directions):
--   SELECT personal_id, enrollment_id FROM data_center_dev.hmis_gold.mv_active_street_outreach
--   EXCEPT
--   SELECT personal_id, enrollment_id FROM data_center_dev.hmis_gold.mv_enrollment_homeless_status
--   WHERE program_group = 'Street Outreach' AND is_active_ohp AND is_most_recent_enrollment;
-- =============================================================================
