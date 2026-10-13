-- =============================================================================
-- mv_homeless_status
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
--   project_type                normalized project type (HUD 0 and 1 both -> Emergency Shelter)
--   last_contact_date           latest non-deleted Current Living Situation record
--   current_living_situation    living situation recorded at that contact
--   last_activity_date          latest of entry, last contact and exit dates
--   is_permanently_housed       Permanent Housing enrollment with a move-in date
--   client_is_active_in_shelter / client_is_active_in_street_outreach
--                               person-level concurrency flags (used by Coordinated Entry)
--   homeless_status             'Sheltered' | 'Unsheltered' | 'Permanently Housed' |
--                               'At-Risk' | 'Unknown' | NULL (not classified)
--   homeless_status_basis       which rule produced homeless_status (for auditing)
--   is_active_ohp               open enrollment, not future-dated, inside its program's
--                               reporting window
--   is_most_recent_enrollment   the person's enrollment(s) with the latest activity, across
--                               all programs; ties are not broken, so a person can have
--                               more than one
--   is_representative_enrollment
--                               the one enrollment that represents the person, across
--                               all programs (see "Choosing the representative enrollment")
--   other_project_type / other_enrollment_id / other_project_last_activity_date /
--   days_since_other_project_activity
--                               the person's most recent enrollment in a *different*
--                               project type than this row's
--
-- Reference codes
--   HUD project types: 0/1 ES, 2 TH, 3 PSH, 4 SO, 6 Services Only, 8 Safe Haven,
--                      9 PH - Housing Only, 10 PH - Housing with Services,
--                      11 Day Shelter, 12 HP, 13 RRH, 14 CE
--   Permanent Housing (PH) types: 3, 9, 10, 13
--   Living situation:  101 ES, 118 Safe Haven, 302 TH -> Sheltered
--                      116 place not meant for habitation -> Unsheltered
--
-- Remaining differences from the old views' behaviour are marked "PARITY:".
--
-- -----------------------------------------------------------------------------
-- Choosing the representative enrollment
-- -----------------------------------------------------------------------------
-- Two person-level flags, both ranked across ALL project types (not per program):
--   is_most_recent_enrollment         latest activity only (rule 3); ties all TRUE.
--   is_representative_enrollment      rules 2-4; exactly one TRUE per person.
--
-- 1. Time window first, then rank (both flags). Only enrollments where is_active_ohp is TRUE are
--    ranked. A person counts if ANY open enrollment is inside its window, and is
--    represented by the best of those. The old Services Only and Street Outreach
--    views ranked first, which dropped a person whose newest enrollment was stale
--    even when an older open enrollment had recent contact. 
--    This mostly affects Street Outreach and Coordinated Entry enrollments, with
--    some Services Only enrollments affected as well. These are the programs where 
--    people accumulate open enrollments that are never exited.
--
-- 2. Permanent Housing move-in wins. If the person has an in-window PH
--    enrollment (PSH, PH - Housing Only, PH - Housing with Services or RRH) with
--    a move-in date, that enrollment represents them, whatever else is open.
--    Once housed, the person is counted as 'Permanently Housed', not as
--    Sheltered or Unsheltered, even if a shelter or outreach enrollment was
--    left open or is more recent.
--
-- 3. Otherwise, latest activity wins: GREATEST(entry_date, last_contact_date),
--    so the enrollment the person was most recently seen on represents them.
--
-- 4. Ties on activity date: prefer a Sheltered (or Permanently Housed)
--    enrollment over an Unsheltered one, then anything else; then
--    enrollment_id DESC so results are stable between refreshes.
--
-- is_most_recent_enrollment applies rule 3 alone, with no tie-break: every
-- enrollment sharing the person's latest activity date is TRUE.
--
-- Future-dated entries (entry_date after today) are treated as data-entry errors:
-- they are never active and never chosen.
-- =============================================================================

CREATE OR REPLACE MATERIALIZED VIEW data_center_dev.hmis_gold.mv_homeless_status
  COMMENT 'Enrollment-grain homeless status and OHP activity flags. Replaces the per-program mv_active_* views.'
  SCHEDULE CRON '0 0 6 * * ? *' AT TIME ZONE 'America/New_York'
  CLUSTER BY (project_type, entry_date) AS

-- Latest contact per enrollment. Cast to DATE
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

-- Every enrollment plus its project type, contact data and activity date.
--     Note: the old CE and Day Shelter views matched on project_type_description
--     ('Coordinated Entry', 'Day Shelter'); this maps by code.
base AS (
  SELECT
    a.*,
    CASE
      WHEN a.project_type_code IN ('0', '1') THEN 'Emergency Shelter'
      WHEN a.project_type_code = '2'  THEN 'Transitional Housing'
      WHEN a.project_type_code = '3'  THEN 'PH - Permanent Supportive Housing'
      WHEN a.project_type_code = '4'  THEN 'Street Outreach'
      WHEN a.project_type_code = '6'  THEN 'Services Only'
      WHEN a.project_type_code = '8'  THEN 'Safe Haven'
      WHEN a.project_type_code = '9'  THEN 'PH - Housing Only'
      WHEN a.project_type_code = '10' THEN 'PH - Housing with Services'
      WHEN a.project_type_code = '11' THEN 'Day Shelter'
      WHEN a.project_type_code = '12' THEN 'Homelessness Prevention'
      WHEN a.project_type_code = '13' THEN 'Rapid Re-Housing'
      WHEN a.project_type_code = '14' THEN 'Coordinated Entry'
    END AS project_type,
    lc.last_contact_date,
    lc.current_living_situation,
    -- GREATEST skips NULLs. exit_date is NULL on open enrollments, so for those
    -- this is GREATEST(entry_date, last_contact_date).
    GREATEST(a.entry_date, lc.last_contact_date, a.exit_date) AS last_activity_date,
    -- A future move-in date is treated like a future entry date: not yet housed.
    a.project_type_code IN ('3', '9', '10', '13')
      AND a.move_in_date IS NOT NULL
      AND a.move_in_date <= CURRENT_DATE() AS is_permanently_housed
  FROM data_center_dev.hmis_silver.admissions_enriched a
    LEFT JOIN last_contact lc
      ON a.enrollment_id = lc.enrollment_id
),

-- Person-level concurrency, from the old CE view's concurrent_status CTE.
-- Considers any open enrollment, regardless of its reporting window.
person_concurrent AS (
  SELECT
    personal_id,
    BOOL_OR(project_type IN ('Emergency Shelter', 'Transitional Housing', 'Safe Haven', 'Day Shelter'))
     AS client_is_active_in_shelter,
    BOOL_OR(project_type = 'Street Outreach')
     AS client_is_active_in_street_outreach
  FROM base
  WHERE is_active_enrollment = TRUE
  GROUP BY personal_id
),

-- Each person's latest enrollment per project type, open or exited, ranked by
-- activity. The top two types are enough to find, for any row, the most recent
-- enrollment in a project type other than the row's own.
-- Excludes future-dated entries and unmapped project types.
latest_per_type AS (
  SELECT
    personal_id,
    project_type,
    enrollment_id,
    last_activity_date,
    ROW_NUMBER() OVER (
      PARTITION BY personal_id
      ORDER BY last_activity_date DESC, enrollment_id DESC
    ) AS type_rank
  FROM (
    SELECT
      personal_id,
      project_type,
      enrollment_id,
      last_activity_date,
      ROW_NUMBER() OVER (
        PARTITION BY personal_id, project_type
        ORDER BY last_activity_date DESC, enrollment_id DESC
      ) AS rn
    FROM base
    WHERE project_type IS NOT NULL
      AND entry_date <= CURRENT_DATE()
  )
  WHERE rn = 1
),

top_two_types AS (
  SELECT
    personal_id,
    MAX(CASE WHEN type_rank = 1 THEN project_type END) AS type_1,
    MAX(CASE WHEN type_rank = 1 THEN enrollment_id END) AS enrollment_id_1,
    MAX(CASE WHEN type_rank = 1 THEN last_activity_date END) AS activity_date_1,
    MAX(CASE WHEN type_rank = 2 THEN project_type END) AS type_2,
    MAX(CASE WHEN type_rank = 2 THEN enrollment_id END) AS enrollment_id_2,
    MAX(CASE WHEN type_rank = 2 THEN last_activity_date END) AS activity_date_2
  FROM latest_per_type
  WHERE type_rank <= 2
  GROUP BY personal_id
),

flagged AS (
  SELECT
    b.*,
    COALESCE(pc.client_is_active_in_shelter, FALSE) AS client_is_active_in_shelter,
    COALESCE(pc.client_is_active_in_street_outreach, FALSE) AS client_is_active_in_street_outreach,

    -- Status from the latest contact, falling back to living situation at entry
    -- (Services Only and Permanent Housing before move-in).
    --
    -- Codes for living_situation_prior:
    --     Sheltered
    --     101 - Emergency shelter / hotel paid with ES voucher / Host Home shelter
    --     118 - Safe Haven
    --     302 - Transitional Housing for homeless persons
    --
    --     Unsheltered
    --     116 - Place not meant for habitation (vehicle, street, etc.)
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
    END AS entry_based_status
  FROM base b
    LEFT JOIN person_concurrent pc
      ON b.personal_id = pc.personal_id
),

statused AS (
  SELECT
    * EXCEPT (contact_based_status, entry_based_status),

    CASE
      -- Moved into Permanent Housing: not included in homeless count
      WHEN is_permanently_housed THEN 'Permanently Housed'
      -- Housing programs prove status by enrollment alone
      WHEN project_type IN ('Emergency Shelter', 'Transitional Housing', 'Safe Haven', 'Day Shelter') THEN 'Sheltered'
      WHEN project_type = 'Street Outreach' THEN 'Unsheltered'
      -- Homelessness Prevention clients not counted as homeless, 'At-Risk' instead
      WHEN project_type = 'Homelessness Prevention' THEN 'At-Risk'
      -- CE: a concurrent shelter stay wins, then concurrent Street Outreach, then entry living situation.
      -- PARITY: CE ignores contact records; use contact_based_status in the last branch to align with Services/PH.
      WHEN project_type = 'Coordinated Entry' AND client_is_active_in_shelter THEN 'Sheltered'
      WHEN project_type = 'Coordinated Entry' AND client_is_active_in_street_outreach THEN 'Unsheltered'
      WHEN project_type = 'Coordinated Entry' THEN entry_based_status
      -- Services Only, and PH before move-in.
      WHEN project_type IN ('Services Only', 'Rapid Re-Housing', 'PH - Permanent Supportive Housing',
                            'PH - Housing Only', 'PH - Housing with Services') THEN contact_based_status
      -- Unmapped project types are not classified.
    END AS homeless_status,

    CASE
      WHEN is_permanently_housed THEN 'move_in_date'
      WHEN project_type IN ('Emergency Shelter', 'Transitional Housing', 'Safe Haven', 'Day Shelter',
                            'Street Outreach', 'Homelessness Prevention') THEN 'project_type'
      WHEN project_type = 'Coordinated Entry' AND (client_is_active_in_shelter OR client_is_active_in_street_outreach) THEN 'concurrent_enrollment'
      WHEN project_type = 'Coordinated Entry' THEN 'prior_living_situation'
      WHEN project_type IN ('Services Only', 'Rapid Re-Housing', 'PH - Permanent Supportive Housing',
                            'PH - Housing Only', 'PH - Housing with Services')
           AND current_living_situation IS NOT NULL THEN 'current_living_situation'
      WHEN project_type IN ('Services Only', 'Rapid Re-Housing', 'PH - Permanent Supportive Housing',
                            'PH - Housing Only', 'PH - Housing with Services') THEN 'prior_living_situation'
    END AS homeless_status_basis,

    -- Open enrollment, not future-dated, inside its program's reporting window.
    -- Windows are copied from the old views as-is.
    -- PARITY: the windows are inconsistent across programs (calendar year,
    -- rolling 365 days, 24 months, 2 and 3 years, none); consider one shared window.
    is_active_enrollment = TRUE
    AND entry_date <= CURRENT_DATE()
    AND COALESCE(
      CASE project_type
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
        -- Jan 1 of last year onward.
        WHEN 'Day Shelter' THEN
          entry_date >= MAKE_DATE(YEAR(CURRENT_DATE()) - 1, 1, 1)
        WHEN 'Emergency Shelter' THEN
          entry_date >= MAKE_DATE(YEAR(CURRENT_DATE()) - 1, 1, 1)
        -- Jan 1 two years ago onward.
        WHEN 'Rapid Re-Housing' THEN
          entry_date >= MAKE_DATE(YEAR(CURRENT_DATE()) - 2, 1, 1)
        -- No window in the old views.
        WHEN 'Transitional Housing' THEN TRUE
        WHEN 'Safe Haven' THEN TRUE
        -- New PH types had no old view; no window, like TH and Safe Haven.
        WHEN 'PH - Permanent Supportive Housing' THEN TRUE
        WHEN 'PH - Housing Only' THEN TRUE
        WHEN 'PH - Housing with Services' THEN TRUE
        ELSE FALSE
      END, FALSE) AS is_active_ohp
  FROM flagged
)

SELECT
  s.*,

  -- Enrollment(s) with the person's latest activity across all programs.
  -- RANK, not ROW_NUMBER: ties are not broken, so every enrollment sharing the
  -- latest activity date is TRUE.
  CASE
    WHEN s.is_active_ohp
    THEN RANK() OVER (
           PARTITION BY s.personal_id, s.is_active_ohp
           ORDER BY s.last_activity_date DESC
         ) = 1
    ELSE FALSE
  END AS is_most_recent_enrollment,

  -- One representative enrollment per person across all programs. See
  -- "Choosing the representative enrollment" in the header for the rules.
  CASE
    WHEN s.is_active_ohp
    THEN ROW_NUMBER() OVER (
           PARTITION BY s.personal_id, s.is_active_ohp
           ORDER BY
             -- Rule 2: a PH move-in represents the person.
             CASE WHEN s.is_permanently_housed THEN 0 ELSE 1 END,
             -- Rule 3: latest activity.
             s.last_activity_date DESC,
             -- Rule 4: ties prefer Sheltered/Permanently Housed, then Unsheltered,
             -- then anything else; then enrollment_id for a stable result.
             CASE
               WHEN s.homeless_status IN ('Sheltered', 'Permanently Housed') THEN 0
               WHEN s.homeless_status = 'Unsheltered' THEN 1
               ELSE 2
             END,
             s.enrollment_id DESC
         ) = 1
    ELSE FALSE
  END AS is_representative_enrollment,

  -- The person's most recent enrollment (open or exited) in a project type
  -- other than this row's. NULL when the person has no other project type.
  CASE WHEN s.project_type <=> t.type_1 THEN t.type_2 ELSE t.type_1 END
    AS other_project_type,
  CASE WHEN s.project_type <=> t.type_1 THEN t.enrollment_id_2 ELSE t.enrollment_id_1 END
    AS other_enrollment_id,
  CASE WHEN s.project_type <=> t.type_1 THEN t.activity_date_2 ELSE t.activity_date_1 END
    AS other_project_last_activity_date,
  -- Days since the latest entry, contact or exit on that other enrollment.
  DATEDIFF(
    CURRENT_DATE(),
    CASE WHEN s.project_type <=> t.type_1 THEN t.activity_date_2 ELSE t.activity_date_1 END
  ) AS days_since_other_project_activity
FROM statused s
  LEFT JOIN top_two_types t
    ON s.personal_id = t.personal_id;


-- =============================================================================
-- Replacing the old views
-- =============================================================================
-- Each old view becomes a filter on mv_homeless_status (as a plain view, or
-- inline in dashboards).
--
-- Homeless population, one row per person:
--   mv_active_homeless:
--     WHERE is_representative_enrollment
--       AND homeless_status IN ('Sheltered', 'Unsheltered')
--   mv_active_sheltered:
--     WHERE is_representative_enrollment AND homeless_status = 'Sheltered'
--   mv_active_unsheltered:
--     WHERE is_representative_enrollment AND homeless_status = 'Unsheltered'
--   Permanently housed (new):
--     WHERE is_representative_enrollment AND homeless_status = 'Permanently Housed'
--   Use is_representative_enrollment, not is_most_recent_enrollment, for
--   counts: is_most_recent_enrollment can be TRUE on several rows per person.
--
-- Per-program views:
--   is_representative_enrollment is chosen across all programs, so a program's
--   people are split by what represents them. Pick the question:
--   * Everyone with an active enrollment in the program (a person can appear
--     on more than one row; count people with COUNT(DISTINCT personal_id)):
--       WHERE project_type = '<type>' AND is_active_ohp
--   * People whose representative enrollment is in the program (each person
--     appears in exactly one program):
--       WHERE project_type = '<type>' AND is_representative_enrollment
--
-- Changes from the old views:
--   * Window first, then rank (see header). Some Services Only and Street
--     Outreach people the old views dropped are now counted.
--   * A person appears at most once across Sheltered, Unsheltered and Homeless.
--     The old roll-ups could count one person several times, or as both
--     Sheltered and Unsheltered.
--   * CE Unsheltered people are now in the Unsheltered count (the old view
--     left them out).
--   * RRH clients who have moved in are 'Permanently Housed', not
--     Sheltered/Unsheltered. PSH and other PH types (3, 9, 10) are new.
--   * Future-dated entries are excluded in every program, not just Day Shelter.
--   * Representative enrollment is chosen by latest activity, not latest entry.
--   * A person whose representative enrollment is HP ('At-Risk') or 'Unknown'
--     is not in the homeless count, even if they have another active shelter or
--     outreach enrollment with older activity.
--
-- Example comparison before switching a dashboard over (run both directions
-- and review the differences against the list above):
--   SELECT personal_id FROM data_center_dev.hmis_gold.mv_active_street_outreach
--   EXCEPT
--   SELECT personal_id FROM data_center_dev.hmis_gold.mv_homeless_status
--   WHERE project_type = 'Street Outreach' AND is_active_ohp;
-- =============================================================================
