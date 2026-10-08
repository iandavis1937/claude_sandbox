"""
Test extract_county (and the project/org coalesce) against the labelled
missing_program_county spreadsheet.

Usage:
    python tests/test_extract_county.py path/to/missing_program_county_sql_338.xlsx

Expected values come from the spreadsheet:
    project_name_county_match -> extract_county("project_name")
    org_name_county_match     -> extract_county("organization_name")
    lookup_program_county     -> coalesce(project, org); NULL for 'unresolved' rows
The string "null" in the sheet means SQL NULL.
"""
import re
import sys

import pandas as pd
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, coalesce, initcap, length, regexp_extract, when

NJ_COUNTIES = [
    "Atlantic", "Bergen", "Burlington", "Camden", "Cape May",
    "Cumberland", "Essex", "Gloucester", "Hudson", "Hunterdon",
    "Mercer", "Middlesex", "Monmouth", "Morris", "Ocean",
    "Passaic", "Salem", "Somerset", "Sussex", "Union", "Warren",
]


def extract_county(column_name):
    """Copy of the function under test; replace with an import from your module."""
    county_pattern = "|".join(re.escape(c) for c in NJ_COUNTIES)
    county_regex = rf"(?i).*\b({county_pattern})\b"
    extracted = regexp_extract(col(column_name), county_regex, 1)
    return when(length(extracted) > 0, initcap(extracted)).otherwise(None)


def norm(v):
    """Sheet 'null' / NaN / '' -> None."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return None
    v = str(v).strip()
    return None if v.lower() in ("null", "") else v


def main(path):
    pdf = pd.read_excel(path, dtype=object)
    for c in ("project_name", "organization_name"):
        pdf[c] = pdf[c].map(norm)
    expected = pdf[["project_name_county_match", "org_name_county_match",
                    "lookup_program_county"]].map(norm)

    spark = SparkSession.builder.master("local[1]").appName("test_extract_county").getOrCreate()
    sdf = spark.createDataFrame(
        pdf[["project_name", "organization_name"]].assign(row_id=range(len(pdf))),
        "project_name string, organization_name string, row_id long",
    )
    out = (
        sdf.withColumn("got_project", extract_county("project_name"))
        .withColumn("got_org", extract_county("organization_name"))
        .withColumn("got_county", coalesce(col("got_project"), col("got_org")))
        .orderBy("row_id")
        .toPandas()
    )

    checks = {
        "project_name match": (out["got_project"], expected["project_name_county_match"]),
        "organization_name match": (out["got_org"], expected["org_name_county_match"]),
        "coalesced county": (out["got_county"], expected["lookup_program_county"]),
    }
    failed = False
    for name, (got, exp) in checks.items():
        bad = [i for i in range(len(pdf)) if norm(got.iloc[i]) != exp.iloc[i]]
        print(f"{name}: {len(pdf) - len(bad)}/{len(pdf)} match")
        for i in bad[:15]:
            print(f"  FAIL row {i + 2}: project={pdf['project_name'][i]!r} "
                  f"org={pdf['organization_name'][i]!r} got={norm(got.iloc[i])!r} expected={exp.iloc[i]!r}")
        failed |= bool(bad)

    # Basic invariants: no empty strings, output always Title Case.
    for c in ("got_project", "got_org", "got_county"):
        vals = out[c].dropna()
        assert (vals != "").all(), f"{c} contains empty strings"
        assert (vals == vals.str.title()).all(), f"{c} not Title Case"

    spark.stop()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
