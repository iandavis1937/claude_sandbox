"""Generate a synthetic HMIS CSV export (Client, Project, Enrollment, Exit).

The export gets a known set of injected data-quality defects so the Great
Expectations suites have something to catch. The defect list is written to
sample_export/_injected_defects.csv so you can compare it with the validation
report. Contains no real client data.
"""
from pathlib import Path

import numpy as np
import pandas as pd

import hud_codes as hud

SEED = 2026
N_HOUSEHOLDS = 450
EXPORT_DATE = pd.Timestamp("2026-09-01")
OUT_DIR = Path(__file__).parent / "sample_export"

FIRST_NAMES = ["Alex", "Jordan", "Maria", "James", "Aisha", "Luis", "Mei", "Darnell",
               "Priya", "Sam", "Olga", "Kwame", "Rosa", "Tyler", "Fatima", "Chris"]
LAST_NAMES = ["Smith", "Garcia", "Johnson", "Nguyen", "Patel", "Williams", "Brown",
              "Rodriguez", "Lee", "Okafor", "Kowalski", "Rivera", "Davis", "Chen"]
NJ_COCS = ["NJ-500", "NJ-501", "NJ-503", "NJ-504", "NJ-506", "NJ-507", "NJ-508", "NJ-511"]

PROJECTS = pd.DataFrame(
    [
        ("P001", "Hope Emergency Shelter", 0),
        ("P002", "Bridge Transitional Housing", 2),
        ("P003", "Harbor Permanent Supportive Housing", 3),
        ("P004", "Next Step Rapid Re-Housing", 13),
        ("P005", "Street Outreach Team", 4),
    ],
    columns=["ProjectID", "ProjectName", "ProjectType"],
).assign(OperatingStartDate="2015-01-01", ContinuumProject=1)

DESTINATION_WEIGHTS = {410: .2, 435: .2, 422: .1, 312: .1, 313: .05, 101: .1, 116: .06,
                       207: .03, 17: .03, 24: .01, 8: .02, 9: .01, 30: .03, 99: .02}

INT_COLUMNS = ["NameDataQuality", "SSNDataQuality", "DOBDataQuality", *hud.RACE_FIELDS,
               "RaceNone", "VeteranStatus", "RelationshipToHoH", "DisablingCondition",
               "Destination", "ProjectType", "ContinuumProject"]

rng = np.random.default_rng(SEED)


def weighted(weights: dict):
    keys = list(weights)
    p = np.array(list(weights.values()), dtype=float)
    return keys[rng.choice(len(keys), p=p / p.sum())]


def iso(ts) -> str | None:
    return None if ts is None or pd.isna(ts) else pd.Timestamp(ts).strftime("%Y-%m-%d")


def days(n) -> pd.Timedelta:
    return pd.Timedelta(days=int(n))


def random_ssn() -> str:
    # Structurally valid: area 001-665, group 01-99, serial 0001-9999
    return f"{rng.integers(1, 666):03d}{rng.integers(1, 100):02d}{rng.integers(1, 10000):04d}"


def make_client(pid: str, age: int, entry: pd.Timestamp, created: pd.Timestamp) -> dict:
    """`age` is the client's age at project start."""
    name_dq = weighted({1: .95, 2: .03, 8: .005, 9: .005, 99: .01})
    ssn_dq = weighted({1: .88, 2: .03, 8: .03, 9: .02, 99: .04})
    dob_dq = weighted({1: .95, 2: .03, 8: .005, 9: .005, 99: .01})
    dob = entry - days(age * 365.25 + rng.integers(0, 365))

    race = dict.fromkeys(hud.RACE_FIELDS, 0)
    race_none = None
    if rng.random() < 0.97:
        race[str(rng.choice(hud.RACE_FIELDS))] = 1
    else:
        race_none = weighted({8: .3, 9: .3, 99: .4})

    ssn = None
    if ssn_dq == 1:
        ssn = random_ssn()
    elif ssn_dq == 2:
        ssn = f"xxxxx{rng.integers(0, 10000):04d}"

    return {
        "PersonalID": pid,
        "FirstName": str(rng.choice(FIRST_NAMES)) if name_dq in (1, 2) else None,
        "LastName": str(rng.choice(LAST_NAMES)) if name_dq in (1, 2) else None,
        "NameDataQuality": name_dq,
        "SSN": ssn,
        "SSNDataQuality": ssn_dq,
        "DOB": iso(dob) if dob_dq in (1, 2) else None,
        "DOBDataQuality": dob_dq,
        **race,
        "RaceNone": race_none,
        "VeteranStatus": weighted({0: .9, 1: .07, 8: .01, 99: .02}) if age >= 18 else 0,
        "DateCreated": iso(created),
        "DateUpdated": iso(created),
    }


def build_clean_export():
    clients, enrollments, exits = [], [], []
    n_client = n_enrollment = n_exit = 0

    for h in range(1, N_HOUSEHOLDS + 1):
        # Household composition: HoH adult, maybe a partner, maybe children
        size = weighted({1: .72, 2: .12, 3: .09, 4: .07})
        members = [(1, int(rng.integers(18, 76)))]
        for i in range(1, size):
            if i == 1 and rng.random() < 0.4:
                members.append((3, int(rng.integers(18, 70))))
            else:
                members.append((2, int(rng.integers(0, 18))))

        project = PROJECTS.iloc[rng.integers(len(PROJECTS))]
        entry = pd.Timestamp("2024-01-01") + days(rng.integers(0, 960))
        # Most records are entered within 3 days; some are entered late
        lag = rng.integers(0, 4) if rng.random() < 0.82 else rng.integers(4, 31)
        created = entry + days(lag)

        exit_date = None
        if rng.random() < 0.7:
            exit_date = min(entry + days(rng.integers(1, 365)), EXPORT_DATE - days(1))

        move_in = None
        if project.ProjectType in hud.PH_PROJECT_TYPES and rng.random() < 0.8:
            move_in = entry + days(rng.integers(0, 61))
            if exit_date is not None:
                move_in = min(move_in, exit_date)
            if move_in > EXPORT_DATE:
                move_in = None

        for relationship, age in members:
            n_client += 1
            n_enrollment += 1
            pid, eid = f"C{n_client:05d}", f"E{n_enrollment:05d}"
            is_hoh = relationship == hud.HEAD_OF_HOUSEHOLD
            clients.append(make_client(pid, age, entry, created))
            enrollments.append({
                "EnrollmentID": eid,
                "PersonalID": pid,
                "ProjectID": project.ProjectID,
                "EntryDate": iso(entry),
                "HouseholdID": f"H{h:05d}",
                "RelationshipToHoH": relationship,
                "EnrollmentCoC": str(rng.choice(NJ_COCS)) if is_hoh else None,
                "DisablingCondition": weighted({0: .56, 1: .40, 8: .01, 9: .01, 99: .02}),
                "MoveInDate": iso(move_in) if is_hoh else None,
                "DateCreated": iso(created),
            })
            if exit_date is not None:
                n_exit += 1
                exits.append({
                    "ExitID": f"X{n_exit:05d}",
                    "EnrollmentID": eid,
                    "PersonalID": pid,
                    "ExitDate": iso(exit_date),
                    "Destination": weighted(DESTINATION_WEIGHTS),
                    "DateCreated": iso(exit_date + days(rng.integers(0, 5))),
                })

    return pd.DataFrame(clients), pd.DataFrame(enrollments), pd.DataFrame(exits)


def inject_defects(client: pd.DataFrame, enrollment: pd.DataFrame, exit_: pd.DataFrame):
    log = []

    def pick(df, mask, n, table, defect):
        idx = df[mask].sample(n, random_state=int(rng.integers(1_000_000))).index
        log.append({"table": table, "defect": defect, "rows": n})
        return idx

    # --- Client.csv ---
    full_ssn = client.SSNDataQuality == 1
    idx = pick(client, full_ssn, 4, "Client", "Full SSN breaks SSA format rules")
    client.loc[idx, "SSN"] = ["000123456", "666451234", "912345678", "12345"]
    idx = pick(client, full_ssn & ~client.index.isin(idx), 2, "Client", "Full SSN is a placeholder")
    client.loc[idx, "SSN"] = ["123456789", "111111111"]

    idx = pick(client, client.DOBDataQuality == 1, 3, "Client", "DOB before 1915-01-01")
    client.loc[idx, "DOB"] = "1900-01-01"
    idx = pick(client, client.NameDataQuality == 1, 3, "Client", "Name DQ = full but FirstName blank")
    client.loc[idx, "FirstName"] = None
    idx = pick(client, client.RaceNone.isna(), 4, "Client", "No race/ethnicity and RaceNone blank")
    client.loc[idx, hud.RACE_FIELDS] = 0
    idx = pick(client, client.DOB > iso(EXPORT_DATE - days(20 * 365)), 2, "Client", "Invalid VeteranStatus code (7)")
    client.loc[idx, "VeteranStatus"] = 7
    kids = client.DOB > iso(EXPORT_DATE - days(15 * 365))
    idx = pick(client, kids, 2, "Client", "Child recorded as veteran")
    client.loc[idx, "VeteranStatus"] = 1

    dupes = client.sample(2, random_state=SEED)
    client = pd.concat([client, dupes], ignore_index=True)
    log.append({"table": "Client", "defect": "Duplicate PersonalID (2 IDs x 2 rows)", "rows": 4})

    # --- Enrollment.csv ---
    exited = enrollment.EnrollmentID.isin(exit_.EnrollmentID)
    idx = pick(enrollment, ~exited, 3, "Enrollment", "PersonalID not in Client.csv")
    enrollment.loc[idx, "PersonalID"] = ["C99997", "C99998", "C99999"]
    idx = pick(enrollment, enrollment.ProjectID != "P999", 2, "Enrollment", "ProjectID not in Project.csv")
    enrollment.loc[idx, "ProjectID"] = "P999"

    moved_in = enrollment.MoveInDate.notna() & (enrollment.MoveInDate > enrollment.EntryDate)
    idx = pick(enrollment, moved_in, 3, "Enrollment", "Move-in date before project start")
    enrollment.loc[idx, "MoveInDate"] = (pd.to_datetime(enrollment.loc[idx, "EntryDate"]) - days(5)).map(iso)

    hoh = enrollment.RelationshipToHoH == hud.HEAD_OF_HOUSEHOLD
    idx = pick(enrollment, hoh, 3, "Enrollment", "Household with no head of household")
    enrollment.loc[idx, "RelationshipToHoH"] = 2
    # One non-HoH member from households that weren't just stripped of their HoH
    members = ~hoh & ~enrollment.HouseholdID.isin(enrollment.loc[idx, "HouseholdID"])
    first_member = members & ~enrollment.HouseholdID.where(members).duplicated()
    idx = pick(enrollment, first_member, 2, "Enrollment", "Household with two heads of household")
    enrollment.loc[idx, ["RelationshipToHoH", "EnrollmentCoC"]] = [1, "NJ-500"]

    idx = pick(enrollment, hoh & enrollment.EnrollmentCoC.notna(), 3, "Enrollment", "Malformed EnrollmentCoC")
    enrollment.loc[idx, "EnrollmentCoC"] = ["NJ500", "New Jersey", "nj-500"]

    candidates = ~exited & (enrollment.RelationshipToHoH != 1) & enrollment.PersonalID.str.startswith("C0")
    idx = pick(enrollment, candidates, 2, "Enrollment", "Project start date in the future")
    enrollment.loc[idx, "EntryDate"] = "2026-12-01"

    # --- Exit.csv ---
    entry_by_eid = enrollment.set_index("EnrollmentID").EntryDate
    idx = pick(exit_, exit_.index >= 0, 4, "Exit", "Exit date before project start")
    exit_.loc[idx, "ExitDate"] = (pd.to_datetime(exit_.loc[idx, "EnrollmentID"].map(entry_by_eid)) - days(10)).map(iso)
    idx = pick(exit_, ~exit_.index.isin(idx), 2, "Exit", "PersonalID doesn't match the enrollment")
    exit_.loc[idx, "PersonalID"] = exit_.loc[idx, "PersonalID"].iloc[::-1].to_numpy()

    extra = pd.DataFrame([
        {**exit_.iloc[0].to_dict(), "ExitID": "X90001"},  # second exit for one enrollment
        {**exit_.iloc[1].to_dict(), "ExitID": "X90002", "EnrollmentID": "E99998"},
        {**exit_.iloc[2].to_dict(), "ExitID": "X90003", "EnrollmentID": "E99999"},
    ])
    exit_ = pd.concat([exit_, extra], ignore_index=True)
    log.append({"table": "Exit", "defect": "Duplicate exit for one enrollment (1 ID x 2 rows)", "rows": 2})
    log.append({"table": "Exit", "defect": "EnrollmentID not in Enrollment.csv", "rows": 2})

    return client, enrollment, exit_, pd.DataFrame(log)


def write_csv(df: pd.DataFrame, name: str):
    df = df.copy()
    for col in INT_COLUMNS:
        if col in df:
            df[col] = pd.to_numeric(df[col]).astype("Int64")
    df.to_csv(OUT_DIR / name, index=False)


def main():
    OUT_DIR.mkdir(exist_ok=True)
    client, enrollment, exit_ = build_clean_export()
    client, enrollment, exit_, defects = inject_defects(client, enrollment, exit_)

    write_csv(PROJECTS, "Project.csv")
    write_csv(client, "Client.csv")
    write_csv(enrollment, "Enrollment.csv")
    write_csv(exit_, "Exit.csv")
    defects.to_csv(OUT_DIR / "_injected_defects.csv", index=False)

    print(f"Wrote {len(client)} clients, {len(enrollment)} enrollments, {len(exit_)} exits to {OUT_DIR}")
    print("\nInjected defects:")
    print(defects.to_string(index=False))


if __name__ == "__main__":
    main()
