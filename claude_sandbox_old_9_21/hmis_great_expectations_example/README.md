# HMIS data quality with Great Expectations

This sample validates a HUD HMIS CSV export (`Client.csv`, `Enrollment.csv`, `Exit.csv`, `Project.csv`) with [Great Expectations](https://greatexpectations.io) (GX Core 1.x). It's tested with GX 1.23 on Python 3.12.

The checks follow the data-quality framework in HUD's APR/CAPER Q6. Every expectation is tagged with the HMIS data element it covers and the Q6 section it rolls up to.

```
python -m pip install -r requirements.txt
python generate_sample_data.py                          # synthetic export with injected defects
python run_validation.py sample_export --as-of 2026-09-01
```

To validate a real export, pass the folder that holds the CSVs: `python run_validation.py path/to/export`.

## Files

| File | Purpose |
|---|---|
| `hud_codes.py` | HUD response-category value sets (1.8, 3.12 Destination, 3.15, project types, SSN rules) |
| `hmis_suites.py` | The four expectation suites: client, enrollment, household and exit |
| `run_validation.py` | Loads the export, builds the joined and derived tables, runs the GX checkpoints and writes the reports |
| `generate_sample_data.py` | Builds a synthetic export and logs its defects to `sample_export/_injected_defects.csv` |

## What gets checked

| Suite | Examples | HUD reference |
|---|---|---|
| client | Unique PersonalID; valid Name/SSN/DOB DQ codes; name present when DQ = 1; SSN passes SSA rules and isn't a placeholder; DOB on or after 1915-01-01; race/ethnicity answered; veteran status code valid | Q6a, Q6b |
| enrollment | Links to a client and a project; start date not in the future; exit on or after start; move-in date between start and exit, and PH projects only; CoC code format; disabling condition; no child veterans; destination present and known | Q6a, Q6b, Q6c |
| enrollment | Share of project starts entered within 3 days | Q6e |
| household | Exactly one head of household; all members in the same project | Q6b |
| exit | Unique ExitID; one exit per enrollment; links to an enrollment; PersonalID matches the enrollment's | Integrity |

**Severity**

- `critical`: structural or integrity errors, such as duplicate IDs, orphan records, impossible dates and invalid codes. If any critical check fails, `run_validation.py` exits with code 1, which lets you gate a scheduled load.
- `warning`: completeness and timeliness rates below the CoC benchmarks. The benchmarks are `COMPLETENESS_TARGET` (95%) and `TIMELINESS_TARGET` (90% within 3 days), both set in `hmis_suites.py`. Warnings are reported but don't block the load.

## Outputs

- `reports/dq_summary.csv`: one row per check, with pass/fail, severity, HUD reference and unexpected count/percent.
- `reports/dq_record_errors.csv`: one row per failing record, with the record ID and the check it failed. Filter it by project to build agency correction lists. Name, SSN and DOB values are redacted.
- GX Data Docs at `gx/uncommitted/data_docs/local_site/index.html`.

## Design notes

- **Cross-file rules.** Rules that span files, such as orphan records, exit before entry, age at entry and one HoH per household, are handled with pandas joins in `prepare_tables()`. GX then asserts the rules against those frames. It's the simplest way to handle relational HMIS rules with file-based data. If the export lands in a database, the same rules can move to SQL with `UnexpectedRowsExpectation`.
- **Conditional checks.** Checks such as "SSN must be valid only when SSNDataQuality = 1" use GX row conditions (`Column("SSNDataQuality") == 1`).
- **PII in Data Docs.** Data Docs render sample failing values, including SSNs and DOBs. Keep the `gx/uncommitted` folder inside your HMIS-secure environment, or remove `UpdateDataDocsAction` in `run_validation.py`.
- **Keeping codes current.** HUD updates the HMIS Data Standards every fiscal year. Review `hud_codes.py` each October.
