# Databricks notebook source
# MAGIC %md
# MAGIC # Data engineering intro: setup and explore
# MAGIC
# MAGIC Companion to the doc *Data Engineering on Azure Databricks: 30-Minute Intro*.
# MAGIC All data here is **synthetic** HMIS-style data: no real clients.
# MAGIC
# MAGIC | Part | What you do | Time |
# MAGIC |---|---|---|
# MAGIC | 1 | Create a schema and a landing volume, drop the first batch of files | 2 min |
# MAGIC | 2 | Create and run the pipeline (`02_hmis_pipeline.sql`) | 4 min |
# MAGIC | 3 | Explore bronze, silver, gold | 2 min |
# MAGIC | 4 | Drop a second batch (updates, late data, bad rows), re-run, compare | 3 min |
# MAGIC | 5 | Delta time travel, then clean up | 1 min |
# MAGIC
# MAGIC Attach to **Serverless** compute.

# COMMAND ----------

# MAGIC %md
# MAGIC ## Part 1: where the data lands
# MAGIC Pick a catalog you can create schemas in (ask your admin if unsure; a dev catalog is ideal).

# COMMAND ----------

dbutils.widgets.text("catalog", "main")
dbutils.widgets.text("schema", "de_lesson")

catalog = dbutils.widgets.get("catalog")
schema = dbutils.widgets.get("schema")
landing = f"/Volumes/{catalog}/{schema}/landing"

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {catalog}.{schema}")
spark.sql(f"CREATE VOLUME IF NOT EXISTS {catalog}.{schema}.landing")
spark.sql(f"USE CATALOG {catalog}")
spark.sql(f"USE SCHEMA {schema}")

print(f"Pipeline setting -> landing_path = {landing}")

# COMMAND ----------

# MAGIC %md
# MAGIC A **volume** is a governed folder in Unity Catalog for raw files. Files arriving here are
# MAGIC what a nightly export, an SFTP drop, or a vendor feed would look like.
# MAGIC
# MAGIC Project types: ES emergency shelter, TH transitional housing, RRH rapid re-housing,
# MAGIC PSH permanent supportive housing, SO street outreach.

# COMMAND ----------

def drop_file(entity: str, name: str, csv: str) -> None:
    """Write one CSV 'delivery' into the landing volume."""
    dbutils.fs.put(f"{landing}/{entity}/{name}", csv.strip() + "\n", overwrite=True)

drop_file("clients", "batch_001.csv", """
client_id,birth_year,veteran_status,updated_at
C001,1971,yes,2026-07-01T09:00:00
C002,1988,no,2026-07-01T09:00:00
C003,1964,no,2026-07-01T09:00:00
C004,1959,yes,2026-07-01T09:00:00
C005,1995,no,2026-07-01T09:00:00
C006,2001,no,2026-07-01T09:00:00
C007,1979,no,2026-07-01T09:00:00
C008,1983,yes,2026-07-01T09:00:00
C009,1990,no,2026-07-01T09:00:00
C010,1968,no,2026-07-01T09:00:00
""")

drop_file("enrollments", "batch_001.csv", """
enrollment_id,client_id,project_type,entry_date,exit_date,exit_destination,updated_at
E001,C001,ES,2026-06-02,2026-07-15,permanent,2026-07-15T17:00:00
E002,C002,ES,2026-06-05,,,2026-06-05T10:00:00
E003,C003,RRH,2026-05-20,,,2026-05-20T11:00:00
E004,C004,PSH,2026-01-10,,,2026-01-10T12:00:00
E005,C005,ES,2026-06-20,2026-07-02,temporary,2026-07-02T15:00:00
E006,C006,TH,2026-03-01,2026-06-30,permanent,2026-06-30T16:00:00
E007,C007,SO,2026-06-11,,,2026-06-11T09:30:00
E008,C008,ES,2026-07-01,,,2026-07-01T08:00:00
E009,C009,RRH,2026-04-15,2026-07-20,permanent,2026-07-20T14:00:00
E010,C010,ES,2026-07-05,2026-07-09,unknown,2026-07-09T13:00:00
""")

display(dbutils.fs.ls(f"{landing}/enrollments"))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Part 2: create and run the pipeline
# MAGIC
# MAGIC 1. Import `02_hmis_pipeline.sql` into your workspace (next to this notebook).
# MAGIC 2. Sidebar: **New → ETL pipeline**. Name it `de_lesson_hmis`.
# MAGIC 3. Default catalog and schema: the widget values above. Compute: **Serverless**.
# MAGIC 4. Add `02_hmis_pipeline.sql` as the pipeline's source code.
# MAGIC 5. Settings → **Configuration**: add key `landing_path` with the value printed in Part 1.
# MAGIC 6. Click **Run pipeline**. Watch the graph: bronze → validated → silver → gold.
# MAGIC
# MAGIC While it runs, read the SQL file top to bottom: every statement *declares a table*, none says *when* to run.

# COMMAND ----------

# MAGIC %md
# MAGIC ## Part 3: explore what it built

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Bronze keeps everything, plus where each row came from
# MAGIC SELECT enrollment_id, client_id, exit_date, source_file, ingested_at
# MAGIC FROM bronze_enrollments
# MAGIC ORDER BY enrollment_id

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Gold: the answer a program manager asks for
# MAGIC SELECT * FROM gold_active_by_project ORDER BY project_type

# COMMAND ----------

# MAGIC %md
# MAGIC ## Part 4: a messier second delivery
# MAGIC
# MAGIC Real feeds send *new versions* of records, late data, and bad rows. This batch contains:
# MAGIC
# MAGIC | Row | What it tests | Expected result |
# MAGIC |---|---|---|
# MAGIC | E002, E008 with exit dates | Updates to open enrollments | Silver shows them exited |
# MAGIC | E001 dated 2026-07-01, no exit | An **older** version arriving late | Ignored: silver keeps the 07-15 exit |
# MAGIC | E011, E012 | New enrollments | Added |
# MAGIC | E013 with no client_id | Broken record | Dropped by `has_client` |
# MAGIC | E014 exit before entry | Impossible dates | Dropped by `valid_dates` |
# MAGIC | C003 veteran_status → yes | A corrected attribute | New version in `silver_clients_history` |

# COMMAND ----------

drop_file("clients", "batch_002.csv", """
client_id,birth_year,veteran_status,updated_at
C003,1964,yes,2026-08-03T10:00:00
C011,1986,no,2026-08-05T09:00:00
C012,1974,yes,2026-08-06T09:00:00
""")

drop_file("enrollments", "batch_002.csv", """
enrollment_id,client_id,project_type,entry_date,exit_date,exit_destination,updated_at
E002,C002,ES,2026-06-05,2026-08-01,permanent,2026-08-01T16:00:00
E008,C008,ES,2026-07-01,2026-08-10,institutional,2026-08-10T12:00:00
E001,C001,ES,2026-06-02,,,2026-07-01T09:00:00
E011,C011,ES,2026-08-05,,,2026-08-05T09:00:00
E012,C012,SO,2026-08-06,,,2026-08-06T10:00:00
E013,,ES,2026-08-07,,,2026-08-07T11:00:00
E014,C005,ES,2026-08-09,2026-08-01,unknown,2026-08-09T12:00:00
""")

# COMMAND ----------

# MAGIC %md
# MAGIC Now **run the pipeline again**. In the graph, note the bronze tables read only `batch_002.csv`
# MAGIC (Auto Loader remembers what it loaded). Open `enrollments_validated` → **Data quality** to see the 2 dropped rows.

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Silver: one row per enrollment, latest version wins (E001 keeps its exit; E013, E014 absent)
# MAGIC SELECT * FROM silver_enrollments ORDER BY enrollment_id

# COMMAND ----------

# MAGIC %sql
# MAGIC -- SCD Type 2 history: C003 now has two rows; the current one has __END_AT IS NULL
# MAGIC SELECT client_id, veteran_status, __START_AT, __END_AT
# MAGIC FROM silver_clients_history
# MAGIC WHERE client_id = 'C003'

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Gold updated itself
# MAGIC SELECT * FROM gold_exits_by_month ORDER BY exit_month, project_type

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Expectation metrics, from the pipeline's event log
# MAGIC SELECT timestamp, details:flow_progress:data_quality:expectations AS expectations
# MAGIC FROM event_log(TABLE(enrollments_validated))
# MAGIC WHERE event_type = 'flow_progress'
# MAGIC   AND details:flow_progress:data_quality IS NOT NULL
# MAGIC ORDER BY timestamp DESC

# COMMAND ----------

# MAGIC %md
# MAGIC ## Part 5: Delta time travel
# MAGIC Every write is a new table version. You can see, query, and restore old versions.

# COMMAND ----------

# MAGIC %sql
# MAGIC DESCRIBE HISTORY bronze_enrollments

# COMMAND ----------

# MAGIC %sql
# MAGIC -- The table as of an earlier version (pick a version number from the history above)
# MAGIC SELECT count(*) AS rows_after_first_run FROM bronze_enrollments VERSION AS OF 1

# COMMAND ----------

# MAGIC %md
# MAGIC ### Clean up
# MAGIC Delete the pipeline in the UI first (that removes its tables), then run the cell below.

# COMMAND ----------

# spark.sql(f"DROP SCHEMA IF EXISTS {catalog}.{schema} CASCADE")
