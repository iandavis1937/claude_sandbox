"""HUD HMIS response-category value sets used by the expectation suites.

Codes follow the HMIS CSV Specifications (FY2024 and later, including the
3-digit Destination codes). HUD revises these each fiscal year, so check them
against the current HMIS Data Standards Manual before relying on them.
"""

# 1.8 "No / Yes / Reasons for Missing Data"
NO_YES_MISSING = [0, 1, 8, 9, 99]
# 8 = Client doesn't know, 9 = Client prefers not to answer, 99 = Data not collected
MISSING_CODES = [8, 9, 99]

NAME_DATA_QUALITY = [1, 2, 8, 9, 99]  # 3.01  1 = full name, 2 = partial/street/code name
SSN_DATA_QUALITY = [1, 2, 8, 9, 99]  # 3.02  1 = full SSN, 2 = approximate/partial
DOB_DATA_QUALITY = [1, 2, 8, 9, 99]  # 3.03  1 = full DOB, 2 = approximate/partial

# 3.04 Race and Ethnicity: each is a 0/1 flag; RaceNone holds 8/9/99 when none selected
RACE_FIELDS = [
    "AmIndAKNative",
    "Asian",
    "BlackAfAmerican",
    "HispanicLatinaeo",
    "MidEastNAfrican",
    "NativeHIPacific",
    "White",
]

# 3.15 Relationship to Head of Household
RELATIONSHIP_TO_HOH = [1, 2, 3, 4, 5, 99]  # 1 = self (HoH), 2 = child, 3 = spouse/partner, ...
HEAD_OF_HOUSEHOLD = 1

# 2.02.6 Project Type
PROJECT_TYPES = {
    0: "Emergency Shelter - Entry/Exit",
    1: "Emergency Shelter - Night-by-Night",
    2: "Transitional Housing",
    3: "PH - Permanent Supportive Housing",
    4: "Street Outreach",
    6: "Services Only",
    7: "Other",
    8: "Safe Haven",
    9: "PH - Housing Only",
    10: "PH - Housing with Services",
    11: "Day Shelter",
    12: "Homelessness Prevention",
    13: "PH - Rapid Re-Housing",
    14: "Coordinated Entry",
}
# Project types that collect 3.20 Housing Move-in Date
PH_PROJECT_TYPES = [3, 9, 10, 13]

# 3.12 Destination
DESTINATIONS = [
    116, 101, 118,                          # homeless situations
    215, 206, 207, 225, 204, 205,           # institutional situations
    302, 312, 313, 314, 327, 329, 332,      # temporary housing situations
    410, 411, 421, 422, 423, 426, 435,      # permanent housing situations
    17, 24, 30, 37, 8, 9, 99,               # other
]
# Counted as destination errors in APR/CAPER Q6c (30 = no exit interview completed)
DESTINATION_UNKNOWN = [8, 9, 30, 99]

# 3.16 Enrollment CoC, e.g. "NJ-500". Swap in an explicit list of your CoCs to be stricter.
COC_CODE_REGEX = r"^[A-Z]{2}-\d{3}$"

# SSA structural rules HUD uses to flag "data issues" on full SSNs:
# 9 digits, area not 000/666/9xx, group not 00, serial not 0000.
VALID_SSN_REGEX = r"^(?!000|666|9)\d{3}(?!00)\d{2}(?!0000)\d{4}$"
PLACEHOLDER_SSNS = [d * 9 for d in "0123456789"] + ["123456789", "987654321"]

# APR Q6a treats DOBs before this date as a data issue
EARLIEST_VALID_DOB = "1915-01-01"

CLIENT_COLUMNS = [
    "PersonalID", "FirstName", "LastName", "NameDataQuality", "SSN", "SSNDataQuality",
    "DOB", "DOBDataQuality", *RACE_FIELDS, "RaceNone", "VeteranStatus", "DateCreated",
]
