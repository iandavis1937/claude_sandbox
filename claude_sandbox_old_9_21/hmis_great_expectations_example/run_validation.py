"""Validate an HMIS CSV export with Great Expectations (GX Core 1.x).

    python generate_sample_data.py             # synthetic export -> ./sample_export
    python run_validation.py ./sample_export   # validate -> ./reports and GX Data Docs

The script exits non-zero if any *critical* expectation fails, so it can gate
a scheduled load (e.g. before refreshing warehouse or Power BI tables).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import great_expectations as gx
import pandas as pd
from great_expectations.data_context.types.base import ProgressBarsConfig

import hmis_suites
import hud_codes as hud

HERE = Path(__file__).parent

# Never copy these values into reports. Record IDs are enough to route a fix.
PII_COLUMNS = {"FirstName", "LastName", "SSN", "DOB"}

DATE_COLUMNS = {"DOB", "EntryDate", "ExitDate", "MoveInDate", "DateCreated", "DateUpdated", "OperatingStartDate"}
CODE_COLUMNS = {"NameDataQuality", "SSNDataQuality", "DOBDataQuality", *hud.RACE_FIELDS, "RaceNone",
                "VeteranStatus", "RelationshipToHoH", "DisablingCondition", "Destination",
                "ProjectType", "ContinuumProject"}


# ---------------------------------------------------------------------------
# 1. Load the export and build the tables GX validates
# ---------------------------------------------------------------------------

def read_hmis_csv(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, dtype=str, keep_default_na=False, na_values=[""])
    for col in df.columns:
        if col in DATE_COLUMNS:
            df[col] = pd.to_datetime(df[col], errors="coerce")
        elif col in CODE_COLUMNS:
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("Int64")
    return df


def prepare_tables(export_dir: Path) -> dict[str, tuple[pd.DataFrame, str]]:
    """Return {table_name: (dataframe, record_id_column)}.

    Cross-file rules (orphan records, exit vs. entry date, age at entry) are
    easiest to express on joined frames, so the joins and a few derived
    columns are built here and GX asserts rules over them.
    """
    client = read_hmis_csv(export_dir / "Client.csv")
    project = read_hmis_csv(export_dir / "Project.csv")
    enrollment = read_hmis_csv(export_dir / "Enrollment.csv")
    exit_ = read_hmis_csv(export_dir / "Exit.csv")

    # APR Q6a counts race/ethnicity as missing when nothing is selected and RaceNone is blank
    client["RaceResponseCount"] = (
        (client[hud.RACE_FIELDS] == 1).sum(axis=1) + client["RaceNone"].isin(hud.MISSING_CODES).astype(int)
    )

    first_exit = exit_.drop_duplicates("EnrollmentID")[["EnrollmentID", "ExitDate", "Destination"]]
    enr = (
        enrollment
        .merge(client[["PersonalID", "DOB", "VeteranStatus"]].drop_duplicates("PersonalID"),
               on="PersonalID", how="left", indicator="_client")
        .merge(project[["ProjectID", "ProjectType"]], on="ProjectID", how="left", indicator="_project")
        .merge(first_exit, on="EnrollmentID", how="left")
    )
    enr["HasClientRecord"] = enr.pop("_client").eq("both")
    enr["HasProjectRecord"] = enr.pop("_project").eq("both")
    enr["AgeAtEntry"] = (enr["EntryDate"] - enr["DOB"]).dt.days // 365.25
    enr["IsPHProject"] = enr["ProjectType"].isin(hud.PH_PROJECT_TYPES).fillna(False).astype(bool)
    enr["HasExit"] = enr["ExitDate"].notna()
    enr["DaysToEntryRecord"] = (enr["DateCreated"] - enr["EntryDate"]).dt.days

    household = (
        enr.groupby("HouseholdID")
        .agg(MemberCount=("EnrollmentID", "size"),
             HoHCount=("RelationshipToHoH", lambda s: int((s == hud.HEAD_OF_HOUSEHOLD).sum())),
             ProjectCount=("ProjectID", "nunique"))
        .reset_index()
    )

    ex = exit_.merge(
        enrollment[["EnrollmentID", "PersonalID"]].rename(columns={"PersonalID": "EnrollmentPersonalID"}),
        on="EnrollmentID", how="left", indicator="_enrollment",
    )
    ex["HasEnrollmentRecord"] = ex.pop("_enrollment").eq("both")

    return {
        "client": (client, "PersonalID"),
        "enrollment": (enr, "EnrollmentID"),
        "household": (household, "HouseholdID"),
        "exit": (ex, "ExitID"),
    }


# ---------------------------------------------------------------------------
# 2. Wire tables to GX: data source -> asset -> batch definition -> checkpoint
# ---------------------------------------------------------------------------

def register_checkpoint(context, source, table: str, suite: gx.ExpectationSuite, id_col: str) -> gx.Checkpoint:
    asset = next((a for a in source.assets if a.name == table), None) or source.add_dataframe_asset(name=table)
    batch_name = f"{table}_whole_table"
    batch_definition = (
        next((b for b in asset.batch_definitions if b.name == batch_name), None)
        or asset.add_batch_definition_whole_dataframe(batch_name)
    )
    suite = context.suites.add_or_update(suite)
    validation = context.validation_definitions.add_or_update(
        gx.ValidationDefinition(name=f"hmis_{table}_validation", data=batch_definition, suite=suite)
    )
    return context.checkpoints.add_or_update(
        gx.Checkpoint(
            name=f"hmis_{table}_checkpoint",
            validation_definitions=[validation],
            actions=[gx.checkpoint.UpdateDataDocsAction(name="update_data_docs")],
            # COMPLETE + index columns returns the record IDs of every failing row
            result_format={"result_format": "COMPLETE", "unexpected_index_column_names": [id_col]},
        )
    )


# ---------------------------------------------------------------------------
# 3. Turn GX results into a summary and a record-level fix list
# ---------------------------------------------------------------------------

def _fmt(value):
    return value.strftime("%Y-%m-%d") if isinstance(value, pd.Timestamp) else value


def collect_results(table: str, checkpoint_result, id_col: str) -> tuple[list[dict], list[dict]]:
    summary, records = [], []
    for validation_result in checkpoint_result.run_results.values():
        for r in validation_result.results:
            cfg = r.expectation_config
            kwargs = cfg.kwargs
            res = r.result or {}
            column = kwargs.get("column") or " vs ".join(
                c for c in (kwargs.get("column_A"), kwargs.get("column_B")) if c) or "(table)"
            check = cfg.description or cfg.type
            severity = getattr(cfg.severity, "value", cfg.severity)
            error = (r.exception_info or {}).get("exception_message") if not r.success else None

            summary.append({
                "table": table,
                "severity": severity,
                "success": r.success,
                "hud_reference": cfg.meta.get("hud_reference", "") if cfg.meta else "",
                "data_element": cfg.meta.get("data_element", "") if cfg.meta else "",
                "column": column,
                "check": check,
                "expectation": cfg.type,
                "element_count": res.get("element_count"),
                "unexpected_count": res.get("unexpected_count"),
                "unexpected_percent": round(res["unexpected_percent"], 2) if res.get("unexpected_percent") is not None else None,
                "error": error,
            })

            for item in res.get("unexpected_index_list") or []:
                item = item if isinstance(item, dict) else {"row_index": item}
                values = {k: ("<redacted>" if k in PII_COLUMNS else _fmt(v)) for k, v in item.items() if k != id_col}
                records.append({
                    "table": table,
                    "record_id_column": id_col,
                    "record_id": item.get(id_col),
                    "severity": severity,
                    "hud_reference": summary[-1]["hud_reference"],
                    "check": check,
                    "values": "; ".join(f"{k}={v}" for k, v in values.items()),
                })
    return summary, records


def print_summary(summary: pd.DataFrame):
    for table, rows in summary.groupby("table", sort=False):
        failed = rows[~rows.success]
        n_critical = int((failed.severity == "critical").sum())
        print(f"\n[{table}] {len(rows)} checks, {len(failed)} failed ({n_critical} critical)")
        for row in failed.itertuples():
            detail = f"{int(row.unexpected_count)} rows ({row.unexpected_percent}%)" if pd.notna(row.unexpected_count) else ""
            if row.error:
                detail = f"ERROR: {row.error}"
            print(f"  FAIL {row.severity:<8} {row.hud_reference:<10} {row.column:<22} {row.check}  {detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_dir", type=Path, nargs="?", default=HERE / "sample_export",
                        help="Folder containing the HMIS CSV export (Client.csv, Enrollment.csv, ...)")
    parser.add_argument("--as-of", help="Date the export was pulled, YYYY-MM-DD (default: today)")
    parser.add_argument("--reports-dir", type=Path, default=HERE / "reports")
    args = parser.parse_args()

    as_of = pd.Timestamp(args.as_of) if args.as_of else pd.Timestamp.today().normalize()
    tables = prepare_tables(args.export_dir)

    # File-backed context: suites, checkpoints and Data Docs persist under ./gx
    context = gx.get_context(mode="file", project_root_dir=HERE)
    context.variables.progress_bars = ProgressBarsConfig(globally=False)
    source = context.data_sources.add_or_update_pandas(name="hmis_export")

    all_summary, all_records = [], []
    for table, (df, id_col) in tables.items():
        suite = hmis_suites.SUITE_BUILDERS[table](as_of)
        checkpoint = register_checkpoint(context, source, table, suite, id_col)
        result = checkpoint.run(batch_parameters={"dataframe": df})
        summary, records = collect_results(table, result, id_col)
        all_summary += summary
        all_records += records

    summary = pd.DataFrame(all_summary)
    records = pd.DataFrame(all_records)
    args.reports_dir.mkdir(exist_ok=True)
    summary.to_csv(args.reports_dir / "dq_summary.csv", index=False)
    records.to_csv(args.reports_dir / "dq_record_errors.csv", index=False)

    print_summary(summary)
    print(f"\nSummary:        {args.reports_dir / 'dq_summary.csv'}")
    print(f"Record errors:  {args.reports_dir / 'dq_record_errors.csv'} ({len(records)} rows)")
    for site in context.get_docs_sites_urls():
        print(f"Data Docs:      {site['site_url']}")

    critical_failures = summary[(~summary.success) & (summary.severity == "critical")]
    return 1 if len(critical_failures) else 0


if __name__ == "__main__":
    sys.exit(main())
