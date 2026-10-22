"""
Run the full HMIS Data Dictionary <-> CSV Format Specifications pipeline.

Usage:
    python scripts/hmis_crosswalk/run_pipeline.py
    python scripts/hmis_crosswalk/run_pipeline.py --dd-pdf HMIS-Data-Dictionary.pdf \\
        --csv-pdf HMIS-CSV-Format-Specifications.pdf -o out/
    python scripts/hmis_crosswalk/run_pipeline.py --dd-union HUD_field_reqs_by_project_type.xlsx \\
        --csv-pdf HMIS-CSV-Format-Specifications.pdf

Steps (each writes one workbook into the output folder):
    1. pdf_tables_to_excel.py  Data Dictionary PDF -> HMIS_DD_tables.xlsx
                               (skipped with --dd-union, which supplies this file)
    2. union_to_fields.py      -> HMIS_DD_fields.xlsx      one row per DD field
    3. pdf_tables_to_excel.py  CSV spec PDF -> HMIS_CSV_fields.xlsx  one row per CSV column
    4. csv_spec_crosswalk.py   -> HMIS_CSV_crosswalk.xlsx  text-derived links
    5. join_dd_csv.py          -> HMIS_DD_CSV_join.xlsx    the joined table

PDFs may be local paths or URLs (the HUD Exchange copies are the defaults).
"""
import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pdf_tables_to_excel import fetch_pdf  # noqa: E402

DD_URL = "https://files.hudexchange.info/resources/documents/HMIS-Data-Dictionary.pdf"
CSV_URL = "https://files.hudexchange.info/resources/documents/HMIS-CSV-Format-Specifications.pdf"


def run(step, script, *args):
    cmd = [sys.executable, str(HERE / script), *map(str, args)]
    print(f"\n[{step}] {' '.join(cmd[1:])}", flush=True)
    subprocess.run(cmd, check=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dd-pdf", default=DD_URL, help="HMIS Data Dictionary PDF path or URL")
    ap.add_argument("--dd-union", help="existing step-1 workbook (its first sheet is the union); skips step 1")
    ap.add_argument("--csv-pdf", default=CSV_URL, help="HMIS CSV Format Specifications PDF path or URL")
    ap.add_argument("-o", "--out-dir", default=HERE / "output", type=Path)
    args = ap.parse_args(argv)

    out = args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    dd_tables = out / "HMIS_DD_tables.xlsx"
    dd_fields = out / "HMIS_DD_fields.xlsx"
    csv_fields = out / "HMIS_CSV_fields.xlsx"
    crosswalk = out / "HMIS_CSV_crosswalk.xlsx"
    joined = out / "HMIS_DD_CSV_join.xlsx"

    try:
        csv_pdf = fetch_pdf(args.csv_pdf)  # steps 3 and 4 both read it; download once
        if args.dd_union:
            dd_tables = Path(args.dd_union)
            print(f"\n[1/5] skipped: using {dd_tables}")
        else:
            run("1/5", "pdf_tables_to_excel.py", args.dd_pdf, "-o", dd_tables)
        run("2/5", "union_to_fields.py", dd_tables, "-o", dd_fields)
        run("3/5", "pdf_tables_to_excel.py", csv_pdf, "-o", csv_fields,
            "--heading-regex", r"^[\w*]+\.csv$", "--union-header", "Name", "--compact")
        run("4/5", "csv_spec_crosswalk.py", csv_pdf, csv_fields, "-o", crosswalk)
        run("5/5", "join_dd_csv.py", dd_fields, csv_fields, "--crosswalk", crosswalk, "-o", joined)
    except subprocess.CalledProcessError as e:
        sys.exit(f"\nPipeline stopped: step failed with exit code {e.returncode}")
    print(f"\nDone. Outputs in {out}")


if __name__ == "__main__":
    main()
