# Databricks notebook source
# MAGIC %md
# MAGIC # Client Timeline Sankey
# MAGIC Visualizes transitions between `project_type_description` values across a client's
# MAGIC enrollment history in `silver.client_timeline`.
# MAGIC
# MAGIC Two layout modes (see `LAYOUT_MODE` below):
# MAGIC - `"duration_x"` — node columns are spaced horizontally by average days-to-reach-step
# MAGIC - `"standard_gradient"` — evenly spaced columns, with link color encoding avg days (green=short, red=long)

# COMMAND ----------

# MAGIC %md ## Config

# COMMAND ----------

TABLE_NAME = "silver.client_timeline"

COL_PERSONAL_ID = "personal_id"
COL_PROJECT_TYPE = "project_type_description"
COL_ENTRY_DATE = "entry_date"
COL_DAYS_GAP = "days_since_prior_exit"  # adjust to match the actual column name from client_timeline.sql

MAX_STEPS = 5  # cap enrollment steps plotted per client; later steps folded into "Step {MAX_STEPS}+"
ENTRY_NODE_LABEL = "Program Entry"

# "duration_x": node x-position reflects avg days to reach that step
# "standard_gradient": evenly spaced columns, link color encodes avg days
LAYOUT_MODE = "duration_x"

# Only used when LAYOUT_MODE == "duration_x"
#   "log"    - compress cumulative day-gaps with log1p before normalizing (default; avoids one
#              huge gap squashing every other column into a sliver)
#   "linear" - raw proportional spacing (fine if day-gaps are already similar magnitude)
#   "rank"   - ignore day-gaps entirely, evenly space columns by step order
X_SCALE = "log"

# COMMAND ----------

# MAGIC %md ## Load + rank enrollments (PySpark)

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql.window import Window

df = spark.table(TABLE_NAME)

w = Window.partitionBy(COL_PERSONAL_ID).orderBy(COL_ENTRY_DATE)

ranked = (
    df.withColumn("step", F.row_number().over(w))
    .withColumn("prior_project_type", F.lag(COL_PROJECT_TYPE).over(w))
    .withColumn(
        "step_capped",
        F.when(F.col("step") >= MAX_STEPS, F.lit(MAX_STEPS)).otherwise(F.col("step")),
    )
)

# Once a client's step is capped, drop any further rows for them beyond the cap
# (keep exactly one row representing the "MAX_STEPS+" bucket).
ranked = ranked.filter(F.col("step") <= MAX_STEPS)

transitions_spark = ranked.select(
    F.col("step_capped").alias("step"),
    F.col(COL_PERSONAL_ID).alias("personal_id"),
    F.col("prior_project_type"),
    F.col(COL_PROJECT_TYPE).alias("project_type"),
    F.col(COL_DAYS_GAP).alias("days_gap"),
)

# COMMAND ----------

# MAGIC %md ## Build transitions DataFrame (Polars)

# COMMAND ----------

import polars as pl

# Hand off Spark -> Polars via Arrow (no pandas in the path).
arrow_table = transitions_spark.toArrow()
raw = pl.from_arrow(arrow_table)

step1 = raw.filter(pl.col("step") == 1).select(
    pl.lit(1).alias("step"),
    pl.lit(ENTRY_NODE_LABEL).alias("source_label"),
    pl.col("project_type").alias("target_label"),
    pl.lit(None, dtype=pl.Float64).alias("days"),
)

later = raw.filter(pl.col("step") > 1).select(
    pl.col("step"),
    pl.col("prior_project_type").alias("source_label"),
    pl.col("project_type").alias("target_label"),
    pl.col("days_gap").cast(pl.Float64).alias("days"),
)

transitions = pl.concat([step1, later])

# COMMAND ----------

# MAGIC %md ## Aggregate links

# COMMAND ----------

links = (
    transitions.group_by(["step", "source_label", "target_label"])
    .agg(
        pl.len().alias("count"),
        pl.col("days").mean().alias("avg_days"),
    )
    .sort(["step", "source_label", "target_label"])
)

# COMMAND ----------

# MAGIC %md ## Compute node x-positions (duration_x mode)

# COMMAND ----------

import math

step_avg_days = (
    links.filter(pl.col("step") > 1)
    .group_by("step")
    .agg(pl.col("avg_days").mean().alias("step_avg_days"))
    .sort("step")
)

steps_present = sorted(links["step"].unique().to_list())
step_x = {1: 0.0}

if X_SCALE == "rank":
    n = len(steps_present)
    for i, s in enumerate(steps_present):
        step_x[s] = i / max(n - 1, 1)
else:
    cumulative = {1: 0.0}
    day_lookup = dict(zip(step_avg_days["step"].to_list(), step_avg_days["step_avg_days"].to_list()))
    running = 0.0
    for s in steps_present:
        if s == 1:
            continue
        gap = day_lookup.get(s, 0.0) or 0.0
        running += gap
        cumulative[s] = running

    if X_SCALE == "log":
        cumulative = {s: math.log1p(max(v, 0.0)) for s, v in cumulative.items()}

    lo, hi = min(cumulative.values()), max(cumulative.values())
    span = hi - lo if hi > lo else 1.0
    for s in steps_present:
        step_x[s] = 0.05 + 0.9 * (cumulative[s] - lo) / span

# COMMAND ----------

# MAGIC %md ## Build node table

# COMMAND ----------

node_key_set = set()
for row in links.iter_rows(named=True):
    node_key_set.add((row["step"] - 1 if row["step"] > 1 else 1, row["source_label"]) if row["step"] > 1 else (1, ENTRY_NODE_LABEL))
    node_key_set.add((row["step"], row["target_label"]))
node_keys = sorted(node_key_set)

node_index = {key: i for i, key in enumerate(node_keys)}
node_labels = [key[1] for key in node_keys]

if LAYOUT_MODE == "duration_x":
    node_x = [step_x.get(key[0], 0.0) for key in node_keys]
else:
    n_steps = max(k[0] for k in node_keys)
    node_x = [k[0] / max(n_steps, 1) for k in node_keys]

# Evenly space nodes within each column for y.
node_y = [0.0] * len(node_keys)
by_step: dict = {}
for key in node_keys:
    by_step.setdefault(key[0], []).append(key)
for step, keys_in_step in by_step.items():
    n = len(keys_in_step)
    for i, key in enumerate(keys_in_step):
        node_y[node_index[key]] = 0.05 + 0.9 * (i / max(n - 1, 1)) if n > 1 else 0.5

# COMMAND ----------

# MAGIC %md ## Map links to node indices + build link colors

# COMMAND ----------

def source_key(row):
    return (1, ENTRY_NODE_LABEL) if row["step"] == 1 else (row["step"] - 1, row["source_label"])


def target_key(row):
    return (row["step"], row["target_label"])


link_source = []
link_target = []
link_value = []
link_avg_days = []

for row in links.iter_rows(named=True):
    link_source.append(node_index[source_key(row)])
    link_target.append(node_index[target_key(row)])
    link_value.append(row["count"])
    link_avg_days.append(row["avg_days"])


def days_to_color(days, lo, hi):
    if days is None:
        return "rgba(160,160,160,0.4)"
    t = 0.0 if hi <= lo else (days - lo) / (hi - lo)
    t = min(max(t, 0.0), 1.0)
    # green -> yellow -> red
    if t < 0.5:
        r, g, b = int(2 * t * 255), 200, 60
    else:
        r, g, b = 220, int(200 * (1 - (t - 0.5) * 2)), 60
    return f"rgba({r},{g},{b},0.55)"


if LAYOUT_MODE == "standard_gradient":
    valid_days = [d for d in link_avg_days if d is not None]
    lo, hi = (min(valid_days), max(valid_days)) if valid_days else (0.0, 1.0)
    link_colors = [days_to_color(d, lo, hi) for d in link_avg_days]
else:
    link_colors = ["rgba(100,100,100,0.35)" for _ in link_avg_days]

# COMMAND ----------

# MAGIC %md ## Plot

# COMMAND ----------

import plotly.graph_objects as go

fig = go.Figure(
    data=[
        go.Sankey(
            arrangement="fixed",
            node=dict(
                pad=15,
                thickness=18,
                label=node_labels,
                x=node_x,
                y=node_y,
            ),
            link=dict(
                source=link_source,
                target=link_target,
                value=link_value,
                color=link_colors,
                customdata=[d if d is not None else float("nan") for d in link_avg_days],
                hovertemplate="%{source.label} -> %{target.label}<br>clients: %{value}<br>avg days: %{customdata:.1f}<extra></extra>",
            ),
        )
    ]
)
fig.update_layout(title_text=f"Client project-type transitions (LAYOUT_MODE={LAYOUT_MODE})", font_size=11)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Render with a full-screen option
# MAGIC `fig.show()` only ever renders inline at the cell's fixed size. This renders via
# MAGIC `displayHTML` instead, with two ways to see it larger:
# MAGIC - **Fullscreen (in-cell)** — uses the browser's native Fullscreen API on the plot's
# MAGIC   container. Works when Databricks' output iframe allows it (`allowfullscreen`); if your
# MAGIC   workspace's iframe blocks it, the button falls back to the alert below.
# MAGIC - **Save as HTML file** — writes the figure as a standalone HTML file to DBFS FileStore
# MAGIC   and prints a link to it. Opening that link loads the plot as its own page (no
# MAGIC   Databricks notebook iframe involved at all), so it can be freely fullscreened with F11
# MAGIC   or your browser's own fullscreen control — this sidesteps the iframe/data-URL
# MAGIC   restrictions that blocked the "open in new tab" button entirely.

# COMMAND ----------

import uuid


def display_sankey_fullscreen(fig, height_px=650):
    div_id = f"sankey-{uuid.uuid4().hex}"
    inline_html = fig.to_html(full_html=False, include_plotlyjs="cdn", div_id=div_id)

    html = f"""
    <div id="{div_id}-wrapper" style="background:white;">
      <div style="margin-bottom:8px;">
        <button onclick="
          var el = document.getElementById('{div_id}-wrapper');
          if (el.requestFullscreen) {{ el.requestFullscreen().catch(function(e) {{
            alert('Fullscreen blocked by this notebook frame — use the saved HTML file instead (see cell below).');
          }}); }} else {{
            alert('Fullscreen API not available here — use the saved HTML file instead (see cell below).');
          }}
        ">Fullscreen (in-cell)</button>
      </div>
      <div style="height:{height_px}px;">
        {inline_html}
      </div>
    </div>
    """
    displayHTML(html)


display_sankey_fullscreen(fig)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Save as a standalone HTML file
# MAGIC Writes the figure to DBFS FileStore as its own HTML page (Plotly.js pulled from CDN,
# MAGIC no dependency on the notebook at all). Opening the printed link loads the plot outside
# MAGIC any Databricks iframe, so it can be freely fullscreened with F11 / your browser's
# MAGIC fullscreen control — this is the reliable path for a large/fullscreen view.

# COMMAND ----------

FILESTORE_DIR = "/FileStore/client_timeline_sankey"
FILESTORE_FILENAME = "client_timeline_sankey.html"

dbutils.fs.mkdirs(FILESTORE_DIR)
local_path = f"/dbfs{FILESTORE_DIR}/{FILESTORE_FILENAME}"
fig.write_html(local_path, full_html=True, include_plotlyjs="cdn")

workspace_url = spark.conf.get("spark.databricks.workspaceUrl", None)
if workspace_url:
    print(f"Open: https://{workspace_url}/files/client_timeline_sankey/{FILESTORE_FILENAME}")
else:
    print(f"Saved to DBFS: {FILESTORE_DIR}/{FILESTORE_FILENAME}")
    print("Open via your workspace's Data > DBFS > FileStore browser, or your <workspace-url>/files/... URL pattern.")

# COMMAND ----------

# MAGIC %md ## Verification checks

# COMMAND ----------

total_clients = df.select(COL_PERSONAL_ID).distinct().count()
entry_flow = links.filter(pl.col("step") == 1)["count"].sum()
print(f"Distinct personal_id: {total_clients}")
print(f"Total flow out of '{ENTRY_NODE_LABEL}': {entry_flow}")

flow_by_step = links.group_by("step").agg(pl.col("count").sum().alias("total_flow")).sort("step")
print(flow_by_step)
