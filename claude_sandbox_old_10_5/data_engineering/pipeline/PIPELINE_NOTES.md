# HMIS dashboard pipeline: design notes

Read this once, then keep it next to the code. It explains what changed, why,
and the design ideas you can reuse on the next pipeline.

## 1. What you had

Three scripts run by hand, in order (the order lived in a comment):

| Script | Layer | What it does |
|---|---|---|
| `make_program_county_lookup.sql` | silver | Builds one county per (project, organization) using four ordered strategies |
| `make_dashboard_silver.sql` | silver | One row per enrollment: repaired county, race, age band, labels, sort keys, household attributes |
| `make_dashboard_gold.sql` | gold | One row per month x demographic slice: distinct people homeless that month. Power BI reads this |

The logic was good. The weaknesses were around the logic: nothing enforced the run
order, nothing checked the results, and judgement calls were buried in code.

## 2. What is in this folder

| File | Purpose |
|---|---|
| `hmis_dashboard_pipeline.sql` | The three scripts as one declarative pipeline, plus reference tables and checks |
| `databricks.yml` | Deploys the pipeline and a scheduled job, one config per environment |
| `parity_check.sql` | Proves the new tables equal the old ones before you switch |
| `diagnostics.sql` | Queries that answer the open questions in section 5 |

Your original scripts and `old/` are untouched.

## 3. Design ideas, each shown in your own code

**1. Declare outputs; let the platform order the work.**
Before: "Run BEFORE make_dashboard_silver.sql" in a comment. After: every table is
declared, Databricks reads the references and runs them in dependency order. A rule that
lives in a comment will eventually be broken.

**2. Refactor and behavior change are separate commits.**
The pipeline reproduces your current output exactly. Every change that would move a
number Power BI shows is listed in section 5 for you to decide. If you mix the two, you
cannot tell whether a shift in a chart is a bug or a decision.
The `old/` conversion did mix them: it dropped your White + Hispanic/Latino rule, changed
how the homeless cause is chosen, and removed the household fallback in gold.

**3. Prove equivalence, do not assume it.** `parity_check.sql` compares the new tables
to a snapshot of the old ones, row by row, in both directions, plus column types. "It
looks right" is not a test; "0 differing rows" is.

**4. One fact, one place.** The five project types appeared in a WHERE list and in two
CASE expressions. Now they live in `dashboard_project_type_map`. Race and age labels
and their sort keys were written twice each, and the race-count arithmetic three times;
now a label and its sort key come from one list, and race flags are counted once.
Rule of thumb: if changing one thing means editing two places, they will drift.

**5. Judgement belongs in data, not in CASE statements.** The Hudson and Middlesex
assignments for BVH regions were hard-coded in a query. They are now rows in
`program_county_overrides`, each with its evidence. Adding Region 3 or 5 is a one-line
pull request with an author and a date. The 21-branch county regex ladder became one
join to your existing county table.

**6. Make invalid states fail loudly.**
- Warn-only expectations (`county_resolved`, `sort_keys_present`, and others) record
  how many rows break a rule without stopping the run. They appear in the pipeline UI.
- Grain checks use `FAIL UPDATE`. A duplicated key means a join fanned out, so every count
  is inflated. Better a failed run and an email than a wrong dashboard.
- Gold reads the grain-check view, so it is not refreshed if a check fails. That is a
  *preventive* control. The reconciliation check after gold is *detective*: it alerts you
  after the fact. Know which one you are writing.

**7. Independent reconciliation.** `dashboard_reconciliation` counts distinct people in
silver for three sample months by a different route and compares with `SUM(homeless_count)`
in gold. Two paths to the same number catch bugs that neither path shows alone.

**8. Determinism.** When two rows tie in a `ROW_NUMBER`, the database picks arbitrarily and
may pick differently next run. Gold now ends its ordering with `enrollment_id`, so a tie
resolves the same way every time.

**9. Do not pay for things nobody uses.**
- The `ORDER BY` at the end of your gold `CREATE TABLE` forced a global sort. Table row
  order is not a contract; Power BI sorts with the `*_sort` columns.
- `BROADCAST` hints: measure first. Forcing a broadcast of an 880,000-row table can fail
  on memory, and the optimizer usually chooses well.
- Unused columns (`household_size_category`) were carried through the month explosion.
- `COUNT(DISTINCT personal_id)` after you have already made each person appear once per
  month is redundant work, so it is now `count(*)`, and the reconciliation check proves it.

**10. Guard against the failure you have not seen yet.** `sequence()` fails the entire
update if a start date is after the end date. One enrollment with an exit month before
its entry month would have stopped the whole gold build. The pipeline excludes those
rows from the month explosion, and a silver expectation counts them so someone can fix
the source.

**11. Environments by configuration.** `example_catalog` was hard-coded in every
statement. Now the catalog is a setting per environment in `databricks.yml`, and the SQL
uses two-part names. The same file runs in dev and prod.

## 4. Things I noticed in the scripts

- **Comment and code disagree.** The lookup header says BVH Regions 3 and 5 are flagged
  `program_county_inferred = TRUE` and `external_research = TRUE`. The code gives them
  `lookup_method = 'unresolved'`, inferred NULL, external research FALSE. The pipeline
  follows the code.
- **Additivity is narrower than the header claims.** `SUM(homeless_count)` is a true
  distinct-person count within one month only. A yearly total double-counts people
  homeless in several months. Use a distinct-person measure over silver for multi-month
  figures. Documented in the gold table comment.
- **Name parsing can be fooled by place names.** A project called "Union City ..."
  would be assigned Union County (Union City is in Hudson County). "Ocean City" would be
  assigned Ocean (it is in Cape May County). Whether this affects your data is
  measurable: run D3 in `diagnostics.sql`, which tests the parser against pairs whose
  county is already known.
- **Ambiguous names resolve silently.** If a name mentions two counties, the alphabetically
  first one wins. The lookup now records `n_counties_named` so you can count how often.
- **NULL never equals NULL.** The lookup joins use `=`. An enrollment with a NULL project
  or organization name can never receive a repaired county. Run D1.
- **`_processed_timestamp` in silver** makes the view recompute in full every run. Fine
  at this size, and kept for parity. If Power BI does not read silver, drop it.

## 5. Decisions for you (not applied)

Each is a change to what Power BI shows. Run the diagnostic, then decide.

| # | Question | Today | Alternative | Evidence |
|---|---|---|---|---|
| 1 | NULL `is_veteran` | Shown as "Not a Veteran" | Show as "Unknown" (new sort 3) | D2 |
| 2 | NULL or unexpected `disabling_condition` | Passed through (blank or raw code), sort 3 | Map to "Unknown" | D2 |
| 3 | Name mentions 2+ counties | Alphabetically first wins | Leave unresolved and let strategies 3 and 4 try | D3, D4 |
| 4 | NULL project or organization name | No lookup match | Match with `<=>` | D1 |
| 5 | Name parser wrong on known pairs | Parser outranks organization history | Reorder, or add a manual override | D3 |

To apply 1 or 2, change the label CASE and the array in the final SELECT of
`silver.snapshot_dashboard`. For 3, add `HAVING count(DISTINCT c.County) = 1` to `by_name`.
For 4, replace `=` with `<=>` in the lookup and silver joins.

## 6. How to roll it out

1. **Dev, read-only.** Run `diagnostics.sql`. Note any surprises.
2. **Dev, snapshot.** Run step 1 of `parity_check.sql` (creates `_baseline` copies).
3. **Dev, cut over.** Drop the three original tables (a pipeline cannot adopt a table
   created by `CREATE TABLE AS`). Deploy the bundle and run the pipeline. Use "Dry run" first.
4. **Dev, compare.** Run step 3 of `parity_check.sql` the same day. Every `diff_rows` must be 0,
   the type query must return nothing, and row counts must match.
5. **Fix, then repeat** until parity holds. Only then consider the decisions in section 5,
   one at a time, each with a before/after row count.
6. **Prod.** Deploy with `-t prod`. The job schedule ships paused; unpause it after the first
   manual run succeeds and Power BI shows the same numbers.

## 7. Power BI

- Connect through a Databricks SQL warehouse (Pro or Serverless) to `gold.snapshot_dashboard`.
  Materialized views are read through SQL warehouses.
- In Power BI, use "Sort by column" for each label with a `*_sort` partner.
- Refresh order matters: the semantic model must refresh after the pipeline finishes. Options,
  simplest first: (a) schedule the Power BI refresh comfortably after the job's usual finish
  time; (b) add a job task that calls the Power BI refresh REST API using a service principal;
  (c) if your workspace offers a Power BI task type in Lakeflow Jobs, use it. Check availability.
- `_processed_timestamp` gives you a "data as of" value to show on the report.
- Keep the table stable. Renaming or retyping a column breaks the report, so treat the
  gold table's columns as a contract and change them deliberately.

## 8. What I have not verified

I could not run any of this: I have no access to your Databricks workspace.
The SQL bodies parse cleanly with a Databricks-dialect parser, and I traced the logic
against your scripts by hand, but the first real run may still surface small
syntax or behavior differences (for example around `PRIVATE` views and expectations
on views). `parity_check.sql` exists to catch exactly that. `databricks.yml` needs your
workspace URLs and prod catalog name.

## 9. Next steps when you are ready

- Turn the flat gold table into a small star schema (dimension tables for race, age, county
  holding labels and sort keys). Worth it when dimensions are reused or the table grows.
- Snapshot gold monthly so a published number can be reproduced later.
- Blue/green publishing: build into a staging schema, run the checks, then promote, so failed
  checks can never touch what Power BI reads.
- Add unit tests for the county parser with a small table of known names and expected counties.
