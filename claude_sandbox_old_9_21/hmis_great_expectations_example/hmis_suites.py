"""Great Expectations suites for an HMIS CSV export.

Checks are grouped by HMIS data element. Each one carries
meta["hud_reference"] (e.g. "APR Q6a") so failures roll up the same way the
data-quality questions (Q6) in HUD's APR/CAPER report them.

Severity:
  critical - structural or integrity problems that make downstream counts wrong
             (duplicate IDs, orphan records, impossible dates, invalid codes).
             These fail the pipeline.
  warning  - completeness or timeliness rates below the CoC's data-quality
             benchmark. They're reported back to agencies but don't block the load.
"""
import great_expectations as gx
import pandas as pd
from great_expectations.expectations.metadata_types import FailureSeverity
from great_expectations.expectations.row_conditions import Column

import hud_codes as hud

E = gx.expectations
CRITICAL = FailureSeverity.CRITICAL
WARNING = FailureSeverity.WARNING

# CoC data-quality benchmarks
COMPLETENESS_TARGET = 0.95  # at most 5% of records answered 8/9/99
TIMELINESS_TARGET = 0.90    # at least 90% of project starts entered within...
TIMELINESS_DAYS = 3         # ...this many days


def valid_hud_response(column: str, value_set: list = hud.NO_YES_MISSING, **kwargs) -> E.Expectation:
    """Column contains only codes from a HUD response-category list
    (default: 1.8 No/Yes/Reasons for Missing Data). Invalid codes are critical."""
    kwargs.setdefault("description", f"{column} contains only valid HUD response codes")
    return E.ExpectColumnValuesToBeInSet(column=column, value_set=value_set, severity=CRITICAL, **kwargs)


def hud_completeness(column: str, value_set: list = hud.MISSING_CODES, **kwargs) -> E.Expectation:
    """The share of records answered 8/9/99 (doesn't know / prefers not to
    answer / not collected) stays within the CoC benchmark. Falling short is a
    warning. Blank values are covered by separate not-null checks."""
    codes = "/".join(map(str, value_set))
    kwargs.setdefault("description", f"At least {COMPLETENESS_TARGET:.0%} of {column} responses are known (not {codes})")
    return E.ExpectColumnValuesToNotBeInSet(
        column=column, value_set=value_set, mostly=COMPLETENESS_TARGET, severity=WARNING, **kwargs)


def ref(hud_reference: str, data_element: str) -> dict:
    return {"hud_reference": hud_reference, "data_element": data_element}


def _suite(name: str, expectations: list) -> gx.ExpectationSuite:
    suite = gx.ExpectationSuite(name=name)
    for expectation in expectations:
        suite.add_expectation(expectation)
    return suite


def build_client_suite(as_of: pd.Timestamp) -> gx.ExpectationSuite:
    q6a = "APR Q6a"
    full_name = Column("NameDataQuality") == 1
    full_ssn = Column("SSNDataQuality") == 1
    return _suite("hmis_client", [
        E.ExpectTableColumnsToMatchSet(
            column_set=hud.CLIENT_COLUMNS, exact_match=False, severity=CRITICAL,
            description="Client.csv has the required HMIS CSV columns"),
        E.ExpectColumnValuesToNotBeNull(
            column="PersonalID", severity=CRITICAL, description="Every client has a PersonalID"),
        E.ExpectColumnValuesToBeUnique(
            column="PersonalID", severity=CRITICAL, description="PersonalID is unique (no duplicate client rows)"),

        # 3.01 Name
        valid_hud_response(column="NameDataQuality", value_set=hud.NAME_DATA_QUALITY, meta=ref(q6a, "3.01 Name")),
        E.ExpectColumnValuesToNotBeNull(
            column="FirstName", row_condition=full_name, severity=CRITICAL,
            description="First name present when Name DQ = full name", meta=ref(q6a, "3.01 Name")),
        E.ExpectColumnValuesToNotBeNull(
            column="LastName", row_condition=full_name, severity=CRITICAL,
            description="Last name present when Name DQ = full name", meta=ref(q6a, "3.01 Name")),
        hud_completeness(column="NameDataQuality", meta=ref(q6a, "3.01 Name")),

        # 3.02 Social Security Number
        valid_hud_response(column="SSNDataQuality", value_set=hud.SSN_DATA_QUALITY, meta=ref(q6a, "3.02 SSN")),
        E.ExpectColumnValuesToMatchRegex(
            column="SSN", regex=hud.VALID_SSN_REGEX, row_condition=full_ssn, severity=CRITICAL,
            description="Full SSN follows SSA rules (9 digits; area not 000/666/9xx; group not 00; serial not 0000)",
            meta=ref(q6a, "3.02 SSN")),
        E.ExpectColumnValuesToNotBeInSet(
            column="SSN", value_set=hud.PLACEHOLDER_SSNS, row_condition=full_ssn, severity=CRITICAL,
            description="Full SSN is not a placeholder (111111111, 123456789, ...)", meta=ref(q6a, "3.02 SSN")),
        hud_completeness(column="SSNDataQuality", meta=ref(q6a, "3.02 SSN")),

        # 3.03 Date of Birth
        valid_hud_response(column="DOBDataQuality", value_set=hud.DOB_DATA_QUALITY, meta=ref(q6a, "3.03 DOB")),
        E.ExpectColumnValuesToNotBeNull(
            column="DOB", row_condition=Column("DOBDataQuality") == 1, severity=CRITICAL,
            description="DOB present when DOB DQ = full DOB", meta=ref(q6a, "3.03 DOB")),
        E.ExpectColumnValuesToBeBetween(
            column="DOB", min_value=pd.Timestamp(hud.EARLIEST_VALID_DOB).to_pydatetime(),
            max_value=as_of.to_pydatetime(), severity=CRITICAL,
            description=f"DOB on or after {hud.EARLIEST_VALID_DOB} and not in the future", meta=ref(q6a, "3.03 DOB")),
        hud_completeness(column="DOBDataQuality", meta=ref(q6a, "3.03 DOB")),

        # 3.04 Race and Ethnicity
        *[valid_hud_response(column=field, value_set=[0, 1], meta=ref(q6a, "3.04 Race and Ethnicity"))
          for field in hud.RACE_FIELDS],
        valid_hud_response(column="RaceNone", value_set=hud.MISSING_CODES, meta=ref(q6a, "3.04 Race and Ethnicity")),
        E.ExpectColumnValuesToBeBetween(
            column="RaceResponseCount", min_value=1, severity=CRITICAL,
            description="At least one race/ethnicity selected, or RaceNone = 8/9/99",
            meta=ref(q6a, "3.04 Race and Ethnicity")),

        # 3.07 Veteran Status
        valid_hud_response(column="VeteranStatus", meta=ref("APR Q6b", "3.07 Veteran Status")),
        hud_completeness(column="VeteranStatus", meta=ref("APR Q6b", "3.07 Veteran Status")),
    ])


def build_enrollment_suite(as_of: pd.Timestamp) -> gx.ExpectationSuite:
    q6b = "APR Q6b"
    hoh = Column("RelationshipToHoH") == hud.HEAD_OF_HOUSEHOLD
    return _suite("hmis_enrollment", [
        E.ExpectColumnValuesToNotBeNull(column="EnrollmentID", severity=CRITICAL, description="Every enrollment has an EnrollmentID"),
        E.ExpectColumnValuesToBeUnique(column="EnrollmentID", severity=CRITICAL, description="EnrollmentID is unique"),
        E.ExpectColumnValuesToBeInSet(
            column="HasClientRecord", value_set=[True], severity=CRITICAL,
            description="Enrollment.PersonalID exists in Client.csv", meta=ref("Integrity", "Enrollment -> Client")),
        E.ExpectColumnValuesToBeInSet(
            column="HasProjectRecord", value_set=[True], severity=CRITICAL,
            description="Enrollment.ProjectID exists in Project.csv", meta=ref("Integrity", "Enrollment -> Project")),

        # 3.10 Project Start Date / 3.11 Project Exit Date
        E.ExpectColumnValuesToNotBeNull(
            column="EntryDate", severity=CRITICAL, description="Project start date present",
            meta=ref(q6b, "3.10 Project Start Date")),
        E.ExpectColumnValuesToBeBetween(
            column="EntryDate", max_value=as_of.to_pydatetime(), severity=CRITICAL,
            description="Project start date is not in the future", meta=ref(q6b, "3.10 Project Start Date")),
        E.ExpectColumnValuesToBeBetween(
            column="AgeAtEntry", min_value=0, max_value=105, severity=CRITICAL,
            description="DOB is before project start and age at entry is plausible", meta=ref("APR Q6a", "3.03 DOB")),
        E.ExpectColumnPairValuesAToBeGreaterThanB(
            column_A="ExitDate", column_B="EntryDate", or_equal=True, ignore_row_if="either_value_is_missing",
            severity=CRITICAL, description="Exit date on or after project start",
            meta=ref(q6b, "3.11 Project Exit Date")),

        # 3.20 Housing Move-in Date
        E.ExpectColumnPairValuesAToBeGreaterThanB(
            column_A="MoveInDate", column_B="EntryDate", or_equal=True, ignore_row_if="either_value_is_missing",
            severity=CRITICAL, description="Move-in date on or after project start",
            meta=ref("APR Q6b", "3.20 Housing Move-in Date")),
        E.ExpectColumnPairValuesAToBeGreaterThanB(
            column_A="ExitDate", column_B="MoveInDate", or_equal=True, ignore_row_if="either_value_is_missing",
            severity=CRITICAL, description="Move-in date on or before exit",
            meta=ref("APR Q6b", "3.20 Housing Move-in Date")),
        E.ExpectColumnValuesToBeNull(
            column="MoveInDate", row_condition=Column("IsPHProject") == False,  # noqa: E712 (GX condition, not Python bool test)
            severity=CRITICAL, description="Move-in date is only recorded in PH projects",
            meta=ref("APR Q6b", "3.20 Housing Move-in Date")),

        # 3.15 Relationship to Head of Household, 3.16 Enrollment CoC
        valid_hud_response(
            column="RelationshipToHoH", value_set=hud.RELATIONSHIP_TO_HOH, meta=ref(q6b, "3.15 Relationship to HoH")),
        hud_completeness(
            column="RelationshipToHoH", value_set=[99], meta=ref(q6b, "3.15 Relationship to HoH")),
        E.ExpectColumnValuesToNotBeNull(
            column="EnrollmentCoC", row_condition=hoh, severity=CRITICAL,
            description="Heads of household have an Enrollment CoC", meta=ref(q6b, "3.16 Enrollment CoC")),
        E.ExpectColumnValuesToMatchRegex(
            column="EnrollmentCoC", regex=hud.COC_CODE_REGEX, severity=CRITICAL,
            description="Enrollment CoC is a valid CoC code (e.g. NJ-500)", meta=ref(q6b, "3.16 Enrollment CoC")),

        # 3.08 Disabling Condition
        E.ExpectColumnValuesToNotBeNull(
            column="DisablingCondition", severity=CRITICAL, description="Disabling condition present",
            meta=ref(q6b, "3.08 Disabling Condition")),
        valid_hud_response(column="DisablingCondition", meta=ref(q6b, "3.08 Disabling Condition")),
        hud_completeness(column="DisablingCondition", meta=ref(q6b, "3.08 Disabling Condition")),

        # 3.07 Veteran Status (needs age at entry, so it lives here rather than in the client suite)
        E.ExpectColumnValuesToNotBeInSet(
            column="VeteranStatus", value_set=[1], row_condition=Column("AgeAtEntry") < 18, severity=CRITICAL,
            description="Children are not recorded as veterans", meta=ref(q6b, "3.07 Veteran Status")),

        # 3.12 Destination
        E.ExpectColumnValuesToNotBeNull(
            column="Destination", row_condition=Column("HasExit") == True,  # noqa: E712
            severity=CRITICAL, description="Exited clients have a destination", meta=ref("APR Q6c", "3.12 Destination")),
        valid_hud_response(
            column="Destination", value_set=hud.DESTINATIONS, meta=ref("APR Q6c", "3.12 Destination")),
        hud_completeness(
            column="Destination", value_set=hud.DESTINATION_UNKNOWN, meta=ref("APR Q6c", "3.12 Destination")),

        # Timeliness
        E.ExpectColumnValuesToBeBetween(
            column="DaysToEntryRecord", max_value=TIMELINESS_DAYS, mostly=TIMELINESS_TARGET, severity=WARNING,
            description=f"At least {TIMELINESS_TARGET:.0%} of project starts entered within {TIMELINESS_DAYS} days",
            meta=ref("APR Q6e", "Timeliness")),
    ])


def build_household_suite(as_of: pd.Timestamp) -> gx.ExpectationSuite:
    return _suite("hmis_household", [
        E.ExpectColumnValuesToBeBetween(
            column="HoHCount", min_value=1, max_value=1, severity=CRITICAL,
            description="Each household has exactly one head of household",
            meta=ref("APR Q6b", "3.15 Relationship to HoH")),
        E.ExpectColumnValuesToBeBetween(
            column="ProjectCount", min_value=1, max_value=1, severity=CRITICAL,
            description="All household members are enrolled in the same project",
            meta=ref("Integrity", "Household")),
    ])


def build_exit_suite(as_of: pd.Timestamp) -> gx.ExpectationSuite:
    return _suite("hmis_exit", [
        E.ExpectColumnValuesToNotBeNull(column="ExitID", severity=CRITICAL, description="Every exit has an ExitID"),
        E.ExpectColumnValuesToBeUnique(column="ExitID", severity=CRITICAL, description="ExitID is unique"),
        E.ExpectColumnValuesToBeUnique(
            column="EnrollmentID", severity=CRITICAL, description="At most one exit per enrollment",
            meta=ref("Integrity", "Exit -> Enrollment")),
        E.ExpectColumnValuesToBeInSet(
            column="HasEnrollmentRecord", value_set=[True], severity=CRITICAL,
            description="Exit.EnrollmentID exists in Enrollment.csv", meta=ref("Integrity", "Exit -> Enrollment")),
        E.ExpectColumnPairValuesToBeEqual(
            column_A="PersonalID", column_B="EnrollmentPersonalID", ignore_row_if="either_value_is_missing",
            severity=CRITICAL, description="Exit.PersonalID matches the enrollment's PersonalID",
            meta=ref("Integrity", "Exit -> Enrollment")),
        E.ExpectColumnValuesToBeBetween(
            column="ExitDate", max_value=as_of.to_pydatetime(), severity=CRITICAL,
            description="Exit date is not in the future", meta=ref("APR Q6b", "3.11 Project Exit Date")),
    ])


SUITE_BUILDERS = {
    "client": build_client_suite,
    "enrollment": build_enrollment_suite,
    "household": build_household_suite,
    "exit": build_exit_suite,
}
