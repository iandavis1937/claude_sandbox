# Databricks notebook source
# /// script
# [tool.databricks.environment]
# environment_version = "5"
# ///
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

# Source table and column names.
TABLE_NAME = "silver.client_timeline"

COL_PERSONAL_ID = "personal_id"
COL_PROJECT_TYPE = "project_type_description"
COL_DAYS_GAP = "days_since_last_entry_date"  
COL_TIMELINE_STEPS = "timeline_order"

MAX_STEPS = 5  # cap enrollment steps plotted per client; later steps are dropped
ENTRY_NODE_LABEL = "Program Entry"
NOT_ENROLLED_LABEL = "Not Enrolled"        # pinned to column bottoms; its links are grey
FINAL_DISCHARGE_LABEL = "Final Discharge"  # pinned below Not Enrolled; its links start hidden

# Set to None to render one combined diagram.
# Use None as a catch-all cohort to include any first-step project type not claimed above.
FIRST_STEP_COHORTS = {
    "Services Only": ["Services Only"],
    "Permanent Housing and Other": [
        "PH - Rapid Re-Housing",
        "PH - Permanent Supportive Housing",
        "PH - Housing Only",
        "PH - Housing with Services",
        "Other"
        ],
    "All Others": None,
}

# Layout:
# "duration_x": node x-position reflects avg days to reach that step
# "standard_gradient": evenly spaced columns, link color encodes avg days
LAYOUT_MODE = "standard_gradient"

# Only used when LAYOUT_MODE == "duration_x"
#   "log"    - compress cumulative day-gaps with log1p before normalizing (default; avoids one
#              huge gap squashing every other column into a sliver)
#   "linear" - raw proportional spacing (fine if day-gaps are already similar magnitude)
#   "rank"   - ignore day-gaps entirely, evenly space columns by step order
X_SCALE = "log"

# Gamma exponent applied after the log-transform when mapping avg days to
# the green→yellow→red color gradient.  Values > 1 push more links toward
# green (short durations); values < 1 push more toward red.  1.0 = no change.
COLOR_GAMMA = 1.8

# Opacity scaling: larger flows (more clients) are more opaque; thin flows
# fade out.  opacity = OPACITY_MIN + (MAX-MIN) * (normalized_count ** OPACITY_EXPONENT)
OPACITY_MIN = 0.05
OPACITY_MAX = 0.98
OPACITY_EXPONENT = 1.0

# Plot height
PLOT_HEIGHT = 1000

# Sankey node padding (px) and figure margins; also used to estimate the
# pixel heights Plotly assigns to nodes when laying out node columns.
SANKEY_NODE_PAD_PX = 15
SANKEY_MARGIN = dict(t=36, b=16, l=8, r=8)

# Minimum vertical offset (px) between a link's two ends, so none is drawn
# perfectly straight.  Enforced only where Plotly's link placement is predictable.
MIN_LINK_OFFSET_PX = 5

# COMMAND ----------

# DBTITLE 1,Install polars
# MAGIC %pip install polars --quiet

# COMMAND ----------

# MAGIC %md ## Load + rank enrollments (PySpark)

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql.window import Window

df = spark.table(TABLE_NAME)

# Each client's enrollments in step (timeline_order) order.
w = Window.partitionBy(COL_PERSONAL_ID).orderBy("step")

ranked = (
    df.withColumnRenamed(COL_TIMELINE_STEPS, "step")
    .withColumn("prior_project_type", F.lag(COL_PROJECT_TYPE).over(w))  # previous enrollment = transition source
)

# Drop steps past the cap; the lag above already saw the full history.
ranked = ranked.filter(F.col("step") <= MAX_STEPS)

# Each row carries the client's first project type, which defines its cohort.
first_project_types = (
    ranked.filter(F.col("step") == 1)
    .select(
        F.col(COL_PERSONAL_ID).alias("personal_id"),
        F.col(COL_PROJECT_TYPE).alias("first_project_type"),
    )
)

ranked = ranked.join(first_project_types, on="personal_id", how="left")

transitions_spark = ranked.select(
    F.col("step"),
    F.col("personal_id"),
    F.col("first_project_type"),
    F.col("prior_project_type"),
    F.col(COL_PROJECT_TYPE).alias("project_type"),
    F.col(COL_DAYS_GAP).alias("days_gap"),
)

# COMMAND ----------

# MAGIC %md ## Build transitions DataFrame (Polars)

# COMMAND ----------

import polars as pl
import re


# Filename-safe slug for per-cohort output files.
def slugify_name(value: str) -> str:
    slug = re.sub(r"[^0-9a-zA-Z]+", "_", value.strip().lower()).strip("_")
    return slug or "cohort"


# Spark → Polars via Arrow; no pandas intermediary.
arrow_table = transitions_spark.toArrow()
raw = pl.from_arrow(arrow_table)

# Step 1: synthetic entry source. Steps 2+: prior enrollment is source.
step1 = raw.filter(pl.col("step") == 1).select(
    pl.lit(1).alias("step"),
    pl.col("personal_id"),
    pl.col("first_project_type"),
    pl.lit(ENTRY_NODE_LABEL).alias("source_label"),
    pl.col("project_type").alias("target_label"),
    pl.lit(None, dtype=pl.Float64).alias("days"),
)

steps2_n = raw.filter(pl.col("step") > 1).select(
    pl.col("step"),
    pl.col("personal_id"),
    pl.col("first_project_type"),
    pl.col("prior_project_type").alias("source_label"),
    pl.col("project_type").alias("target_label"),
    pl.col("days_gap").cast(pl.Float64).alias("days"),
)

# One row per client transition: step, source → target, gap-days.
transitions = pl.concat([step1, steps2_n])

# COMMAND ----------

# MAGIC %md ## Aggregate links

# COMMAND ----------

ALL_CLIENTS_LABEL = "All Clients"


# Cohort name → allowed first project types; the catch-all cohort excludes
# every type claimed by another cohort.
def normalize_cohort_filters(raw_cohorts):
    if raw_cohorts is None:
        return {ALL_CLIENTS_LABEL: None}

    normalized = {}
    claimed_first_types = set()
    catch_all_name = None

    for cohort_name, allowed_first_types in raw_cohorts.items():
        if allowed_first_types is None:
            catch_all_name = cohort_name
            normalized[cohort_name] = None
        else:
            allowed_list = [str(value) for value in allowed_first_types]
            normalized[cohort_name] = allowed_list
            claimed_first_types.update(allowed_list)

    if catch_all_name is not None:
        normalized[catch_all_name] = {"exclude": sorted(claimed_first_types)}

    return normalized



# Transitions of clients whose first project type matches the cohort filter.
def filter_transitions_for_cohort(transitions_df, cohort_filter):
    if cohort_filter is None:
        return transitions_df

    if isinstance(cohort_filter, dict):
        excluded = cohort_filter.get("exclude", [])
        if excluded:
            return transitions_df.filter(~pl.col("first_project_type").is_in(excluded))
        return transitions_df

    return transitions_df.filter(pl.col("first_project_type").is_in(cohort_filter))



# One link per (step, source, target) with client count and mean gap-days.
def aggregate_links(transitions_df):
    return (
        transitions_df.group_by(["step", "source_label", "target_label"])
        .agg(
            pl.len().alias("count"),
            pl.col("days").mean().alias("avg_days"),
        )
        .sort(["step", "source_label", "target_label"])
    )


# Transitions split by cohort; empty cohorts are dropped.
cohort_filters = normalize_cohort_filters(FIRST_STEP_COHORTS)
cohort_transitions = {}

for cohort_name, cohort_filter in cohort_filters.items():
    cohort_df = filter_transitions_for_cohort(transitions, cohort_filter)
    if cohort_df.height > 0:
        cohort_transitions[cohort_name] = cohort_df

if not cohort_transitions:
    raise ValueError("No transitions matched FIRST_STEP_COHORTS. Update the cohort config or disable splitting.")

# COMMAND ----------

# MAGIC %md ## Compute node x-positions (duration_x mode)

# COMMAND ----------

import math


# Cumulative gap-days → x-coordinate per step, scaled per X_SCALE.
def compute_step_x(links):
    step_avg_days = links.group_by("step").agg(pl.col("avg_days").mean().alias("step_avg_days"))
    day_lookup = dict(zip(step_avg_days["step"].to_list(), step_avg_days["step_avg_days"].to_list()))

    # Columns: every link's target step, plus the source step of the earliest links.
    link_steps = sorted(day_lookup)
    steps_present = [link_steps[0] - 1] + link_steps

    if X_SCALE == "rank":
        n = len(steps_present)
        return {s: i / max(n - 1, 1) for i, s in enumerate(steps_present)}

    cumulative = {}
    running = 0.0
    for s in steps_present:
        running += day_lookup.get(s) or 0.0
        cumulative[s] = running

    if X_SCALE == "log":
        cumulative = {s: math.log1p(max(v, 0.0)) for s, v in cumulative.items()}

    lo, hi = min(cumulative.values()), max(cumulative.values())
    span = hi - lo if hi > lo else 1.0
    return {s: 0.05 + 0.9 * (cumulative[s] - lo) / span for s in steps_present}

# COMMAND ----------

# MAGIC %md ## Build node table

# COMMAND ----------

# Link endpoints as (step, label) node keys; a step-s link runs from column s-1 to s.
def source_key(row):
    return (row["step"] - 1, row["source_label"])


def target_key(row):
    return (row["step"], row["target_label"])


# Plotly only honors a fixed node position when both x and y are truthy, so a
# node at x == 0 or y == 0 is silently re-laid-out by d3-sankey.  Keep every
# coordinate at least this far from zero.
NODE_COORD_MIN = 1e-3


def estimate_plotly_node_scale(node_keys, node_flow, node_outflow, plot_area_px, pad_px):
    """Fraction of plot height per unit of flow, mirroring d3-sankey's ky.

    Plotly sizes every node as value * ky (value = max(inflow, outflow)), with
    ky = min over columns of (H - (n - 1) * pad) / sum(values).  Columns follow
    d3's "justify" alignment: nodes with no outgoing links move to the last column.
    """
    max_step = max(key[0] for key in node_keys)
    columns = {}
    for key in node_keys:
        column = key[0] if node_outflow.get(key, 0.0) > 0 else max_step
        columns.setdefault(column, []).append(node_flow[key])

    max_nodes = max(len(values) for values in columns.values())
    pad = pad_px if max_nodes <= 1 else min(pad_px, 2 / 3 * plot_area_px / (max_nodes - 1))
    ky = min(
        (plot_area_px - (len(values) - 1) * pad) / sum(values)
        for values in columns.values()
        if sum(values) > 0
    )
    return ky / plot_area_px


def target_barycenters(links, step, node_y, node_index):
    """Client-weighted mean y of the targets of each node in column `step`."""
    weighted_y = {}
    weight = {}
    for row in links.iter_rows(named=True):
        sk = source_key(row)
        if sk[0] != step:
            continue
        weighted_y[sk] = weighted_y.get(sk, 0.0) + row["count"] * node_y[node_index[target_key(row)]]
        weight[sk] = weight.get(sk, 0.0) + row["count"]
    return {key: weighted_y[key] / weight[key] for key in weight if weight[key] > 0}


def stack_within_bounds(ordered, desired, half_height, top_bound, bottom_bound, gap):
    """Centers for `ordered` nodes, each near its desired y, without overlaps.

    The gap shrinks if needed so the stack fits between the bounds; if it
    still cannot fit, the bottom bound takes priority over the top bound.
    """
    if len(ordered) > 1:
        slack = bottom_bound - top_bound - sum(2 * half_height(k) for k in ordered)
        gap = max(0.0, min(gap, slack / (len(ordered) - 1)))

    # Top-down pass: resolve overlaps and keep the stack below the top bound.
    centers = []
    cursor = top_bound
    for key in ordered:
        center = max(desired[key], cursor + half_height(key))
        centers.append(center)
        cursor = center + half_height(key) + gap

    # Bottom-up pass: pull the stack up so nothing extends past the bottom bound.
    cursor = bottom_bound
    for i in range(len(ordered) - 1, -1, -1):
        centers[i] = min(centers[i], cursor - half_height(ordered[i]))
        cursor = centers[i] - half_height(ordered[i]) - gap
    return centers


def align_column_to_targets(
    links, step, keys_in_step, node_y, node_index, node_flow, node_scale, gap, pin_order, bound_keys=None
):
    """Place a column's nodes next to the nodes they flow into.

    Each node starts at the client-weighted mean y of its targets in the next
    column (nodes without targets keep their current y), then overlaps are
    pushed apart within the vertical extent of `bound_keys` (default: this
    column's current extent).  Labels in `pin_order` stay below all other
    nodes, in pin order, as close to their current slots as overlaps allow.
    Heights use Plotly's real node sizes (`node_scale` * flow).
    """
    def half_height(key):
        return node_scale * node_flow[key] / 2

    def current_y(key):
        return node_y[node_index[key]]

    pinned = sorted((k for k in keys_in_step if k[1] in pin_order), key=lambda k: pin_order[k[1]])
    free = [k for k in keys_in_step if k[1] not in pin_order]
    barycenters = target_barycenters(links, step, node_y, node_index)
    desired = {key: barycenters.get(key, current_y(key)) for key in free}
    desired.update({key: current_y(key) for key in pinned})
    ordered = sorted(free, key=lambda k: (desired[k], -node_flow[k], k[1])) + pinned

    bounded_by_other_column = bound_keys is not None
    bound_keys = bound_keys or keys_in_step
    top_bound = min(current_y(k) - half_height(k) for k in bound_keys)
    bottom_bound = max(current_y(k) + half_height(k) for k in bound_keys)

    # Grow upward (never past the plot top) if the nodes cannot otherwise fit,
    # e.g. when the current positions came from smaller heights than Plotly draws.
    # A column bounded by its own extent that cannot fit even with its top at the
    # plot edge also grows downward, to fit its nodes and gaps within the plot.
    total_height = sum(2 * half_height(k) for k in keys_in_step)
    if not bounded_by_other_column and total_height > bottom_bound:
        bottom_bound = min(1.0, total_height + gap * (len(keys_in_step) - 1))
    top_bound = max(0.0, min(top_bound, bottom_bound - total_height))

    centers = stack_within_bounds(ordered, desired, half_height, top_bound, bottom_bound, gap)
    for key, center in zip(ordered, centers):
        node_y[node_index[key]] = max(center, NODE_COORD_MIN)


def offset_straight_links(links, by_step, node_y, node_index, node_flow, node_scale, min_offset, gap):
    """Nudge nodes so no predictably placed link is drawn perfectly straight.

    Plotly stacks each node's links from the node's top, in an order taken from
    its own internal layout, so a link's end is predictable only when it is the
    node's sole link on that side.  For a link that is its source's sole
    outgoing link and its target's sole incoming link, the two ends differ by
    exactly the difference between the nodes' tops.  Where that is below
    `min_offset`, the source (or, failing that, the target) is moved by the
    smallest amount that fixes it.  A move is rejected if it leaves the plot,
    reorders a column, narrows a gap below `gap`, lets the first column extend
    below the second, or worsens another predictable link.
    """
    def y(key):
        return node_y[node_index[key]]

    def half_height(key):
        return node_scale * node_flow[key] / 2

    out_links, in_links = {}, {}
    for row in links.iter_rows(named=True):
        sk, tk = source_key(row), target_key(row)
        out_links.setdefault(sk, []).append(tk)
        in_links.setdefault(tk, []).append(sk)

    predictable = [
        (sk, targets[0]) for sk, targets in out_links.items()
        if len(targets) == 1 and len(in_links[targets[0]]) == 1
    ]
    touching = {}
    for link in predictable:
        for key in link:
            touching.setdefault(key, []).append(link)

    def end_offset(link, moved=None, moved_y=None):
        sk, tk = link
        top = lambda k: (moved_y if k == moved else y(k)) - half_height(k)
        return top(tk) - top(sk)

    first_step, second_step = sorted(by_step)[:2]

    def column_bottom(step, moved, moved_y):
        return max((moved_y if k == moved else y(k)) + half_height(k) for k in by_step[step])

    def can_place(key, new_y):
        top, bottom = new_y - half_height(key), new_y + half_height(key)
        if top < 0 or bottom > 1 or new_y < NODE_COORD_MIN:
            return False
        column = sorted(by_step[key[0]], key=y)
        i = column.index(key)
        if i > 0:
            above_bottom = y(column[i - 1]) + half_height(column[i - 1])
            if top - above_bottom < min(gap, y(key) - half_height(key) - above_bottom) - 1e-12:
                return False
        if i < len(column) - 1:
            below_top = y(column[i + 1]) - half_height(column[i + 1])
            if below_top - bottom < min(gap, below_top - y(key) - half_height(key)) - 1e-12:
                return False
        if key[0] in (first_step, second_step):
            if column_bottom(first_step, key, new_y) > column_bottom(second_step, key, new_y) + 1e-12:
                return False
        return all(
            abs(end_offset(link, key, new_y)) >= min(min_offset, abs(end_offset(link))) - 1e-12
            for link in touching[key]
        )

    # Each accepted move fixes one link without breaking another, so this ends.
    changed = True
    while changed:
        changed = False
        for link in sorted(predictable, key=lambda l: -l[0][0]):  # right to left
            delta = end_offset(link)
            if abs(delta) >= min_offset - 1e-12:
                continue
            sk, tk = link
            to_plus, to_minus = min_offset - delta, min_offset + delta  # shift sizes
            candidates = sorted([(to_plus, sk, -to_plus), (to_minus, sk, to_minus)]) + sorted(
                [(to_plus, tk, to_plus), (to_minus, tk, -to_minus)]
            )
            for _, key, shift in candidates:
                if can_place(key, y(key) + shift):
                    node_y[node_index[key]] = y(key) + shift
                    changed = True
                    break


# Node keys, labels and x/y positions from the links' (step, label) endpoints.
def build_node_layout(links, plot_height):
    # Flow through each node (max of inflow, outflow) determines visual height.
    node_inflow = {}
    node_outflow = {}
    for row in links.iter_rows(named=True):
        sk, tk = source_key(row), target_key(row)
        node_outflow[sk] = node_outflow.get(sk, 0.0) + row["count"]
        node_inflow[tk] = node_inflow.get(tk, 0.0) + row["count"]
    node_keys = sorted(node_inflow.keys() | node_outflow.keys())
    node_flow = {key: max(node_inflow.get(key, 0.0), node_outflow.get(key, 0.0)) for key in node_keys}

    node_index = {key: i for i, key in enumerate(node_keys)}
    node_labels = [key[1] for key in node_keys]

    if LAYOUT_MODE == "duration_x":
        step_x = compute_step_x(links)
        node_x = [step_x.get(key[0], 0.0) for key in node_keys]
    else:
        min_step = min(k[0] for k in node_keys)
        max_step = max(k[0] for k in node_keys)
        step_range = max_step - min_step
        node_x = [(k[0] - min_step) / max(step_range, 1) for k in node_keys]
    node_x = [max(x, NODE_COORD_MIN) for x in node_x]  # Plotly ignores fixed positions at 0

    by_step = {}
    for key in node_keys:
        by_step.setdefault(key[0], []).append(key)

    BASE_PAD = 0.015    # minimum gap between any two adjacent nodes
    PAD_SCALE = 0.12     # additional gap proportional to each node's height

    # Labels pinned to the bottom of steps 2+, top to bottom.
    PIN_BOTTOM_ORDER = {NOT_ENROLLED_LABEL: 0, FINAL_DISCHARGE_LABEL: 1}

    def pins_for(step):
        return PIN_BOTTOM_ORDER if step >= 2 else {}

    # Initial y-placement: stack each column by flow on one shared scale sized
    # for the densest column.  These slots set each column's extent, the last
    # column's order and the pinned positions; columns are refined below.
    node_y = [0.0] * len(node_keys)
    max_n = max(len(keys) for keys in by_step.values())
    usable = (0.9 - BASE_PAD * (max_n - 1)) / (1.0 + PAD_SCALE)
    for step, keys_in_step in by_step.items():
        pins = pins_for(step)
        # Pinned labels last, then by inflow (outflow for source-only nodes).
        keys_in_step.sort(key=lambda k: (pins.get(k[1], -1), -(node_inflow.get(k) or node_flow[k]), -node_flow[k], k[1]))
        total_flow = sum(node_flow[key] for key in keys_in_step)
        cursor = 0.05
        for key in keys_in_step:
            node_height = usable * node_flow[key] / total_flow
            node_y[node_index[key]] = cursor + node_height / 2
            cursor += node_height + BASE_PAD + PAD_SCALE * node_height

    # Re-place columns right to left so each node sits near the nodes it flows
    # into, spaced by Plotly's real node heights.  The last column has no
    # targets, so it keeps the order and slots from the stacking above; the
    # first column is fitted within the second column's extent.
    ordered_steps = sorted(by_step)
    if len(ordered_steps) > 1:
        plot_area_px = plot_height - SANKEY_MARGIN["t"] - SANKEY_MARGIN["b"]
        node_scale = estimate_plotly_node_scale(
            node_keys, node_flow, node_outflow, plot_area_px, SANKEY_NODE_PAD_PX
        )
        for i in range(len(ordered_steps) - 1, -1, -1):
            step = ordered_steps[i]
            align_column_to_targets(
                links,
                step,
                by_step[step],
                node_y,
                node_index,
                node_flow,
                node_scale,
                gap=BASE_PAD,
                pin_order=pins_for(step),
                bound_keys=by_step[ordered_steps[1]] if i == 0 else None,
            )
        offset_straight_links(
            links,
            by_step,
            node_y,
            node_index,
            node_flow,
            node_scale,
            min_offset=MIN_LINK_OFFSET_PX / plot_area_px,
            gap=BASE_PAD,
        )

    return {
        "node_keys": node_keys,
        "node_index": node_index,
        "node_labels": node_labels,
        "node_x": node_x,
        "node_y": node_y,
    }

# COMMAND ----------

# MAGIC %md ## Map links to node indices + build link colors

# COMMAND ----------

# Link color: green → yellow → red by log avg days; grey when days are missing.
def days_to_color(days, lo, hi, alpha=0.55):
    if days is None:
        return f"rgba(160,160,160,{alpha:.2f})"
    # Log-transform to spread gradient more evenly across the range
    log_days = math.log1p(max(days, 0.0))
    log_lo = math.log1p(max(lo, 0.0))
    log_hi = math.log1p(max(hi, 0.0))
    t = 0.0 if log_hi <= log_lo else (log_days - log_lo) / (log_hi - log_lo)
    t = min(max(t, 0.0), 1.0)
    t = t ** COLOR_GAMMA  # gamma > 1 shifts more links toward green
    # green -> yellow -> red
    if t < 0.5:
        r, g, b = int(2 * t * 255), 200, 60
    else:
        r, g, b = 220, int(200 * (1 - (t - 0.5) * 2)), 60
    return f"rgba({r},{g},{b},{alpha:.2f})"



# The same rgb color with a new alpha; non-rgba strings pass through unchanged.
def set_rgba_alpha(color, alpha):
    if not isinstance(color, str) or "(" not in color or ")" not in color:
        return color
    parts = [part.strip() for part in color[color.find("(") + 1:color.rfind(")")].split(",")]
    if len(parts) < 3:
        return color
    return f"rgba({parts[0]},{parts[1]},{parts[2]},{alpha:.2f})"



# Plotly link arrays (source, target, value) plus per-link colors and flags
# used by the HTML highlight controls.
def build_link_components(links, node_index):
    link_source = []
    link_target = []
    link_value = []
    link_avg_days = []

    link_source_labels = []
    link_target_labels = []

    for row in links.iter_rows(named=True):
        link_source.append(node_index[source_key(row)])
        link_target.append(node_index[target_key(row)])
        link_value.append(row["count"])
        link_avg_days.append(row["avg_days"])
        link_source_labels.append(row["source_label"])
        link_target_labels.append(row["target_label"])

    is_not_enrolled = [lbl == NOT_ENROLLED_LABEL for lbl in link_source_labels]
    is_final_discharge = [lbl == FINAL_DISCHARGE_LABEL for lbl in link_target_labels]

    # Per-link opacity, normalized independently for three edge groups so
    # the large Final Discharge / Not Enrolled flows don't crowd out others.
    def _group_opacities(counts):
        if not counts:
            return []
        lo, hi = min(counts), max(counts)
        span = hi - lo
        out = []
        for c in counts:
            if span <= 0:
                out.append(OPACITY_MAX)
            else:
                norm = (c - lo) / span
                out.append(OPACITY_MIN + (OPACITY_MAX - OPACITY_MIN) * (norm ** OPACITY_EXPONENT))
        return out

    group_indices = {"normal": [], "not_enrolled": [], "final_discharge": []}
    for i, (ne, fd) in enumerate(zip(is_not_enrolled, is_final_discharge)):
        if fd:
            group_indices["final_discharge"].append(i)
        elif ne:
            group_indices["not_enrolled"].append(i)
        else:
            group_indices["normal"].append(i)

    SPECIAL_OPACITY_SCALE = 0.5  # halve opacity for Final Discharge / Not Enrolled edges

    link_opacities = [0.0] * len(link_value)
    for group_name, indices in group_indices.items():
        counts = [link_value[i] for i in indices]
        opacities = _group_opacities(counts)
        scale = SPECIAL_OPACITY_SCALE if group_name in ("not_enrolled", "final_discharge") else 1.0
        for idx, op in zip(indices, opacities):
            link_opacities[idx] = op * scale

    # Color-scale and legend range; excludes "Not Enrolled"-sourced links.
    valid_days = [
        days for days, ne in zip(link_avg_days, is_not_enrolled)
        if days is not None and not ne
    ]
    lo, hi = (min(valid_days), max(valid_days)) if valid_days else (None, None)

    if LAYOUT_MODE == "standard_gradient":
        base_link_colors = []
        for d, op, ne in zip(link_avg_days, link_opacities, is_not_enrolled):
            if ne:
                base_link_colors.append(f"rgba(150,150,150,{op:.2f})")
            else:
                base_link_colors.append(days_to_color(d, lo, hi, alpha=op))
    else:
        base_link_colors = [f"rgba(100,100,100,{op:.2f})" for op in link_opacities]

    # Final Discharge links start hidden; the HTML toggle restores their base colors.
    link_colors = [
        set_rgba_alpha(color, 0.0) if is_fd else color
        for color, is_fd in zip(base_link_colors, is_final_discharge)
    ]

    return {
        "link_source": link_source,
        "link_target": link_target,
        "link_value": link_value,
        "link_avg_days": link_avg_days,
        "link_colors": link_colors,
        "link_base_colors": base_link_colors,
        "link_is_final_discharge": is_final_discharge,
        "days_lo": lo,
        "days_hi": hi,
    }

# COMMAND ----------

# MAGIC %md ## Plot

# COMMAND ----------

import plotly.graph_objects as go


# Fixed-arrangement Sankey plus its color-scale range (lo, hi) in avg days;
# hover shows client count and avg gap-days.
def build_sankey_figure(links, cohort_name):
    node_layout = build_node_layout(links, PLOT_HEIGHT)
    link_parts = build_link_components(links, node_layout["node_index"])

    # Assign a consistent color per project-type label so the same type
    # keeps the same color across every step column.
    _D3_HEX = [
        "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
        "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf",
    ]
    unique_labels = sorted(set(node_layout["node_labels"]))
    _label_color = {}
    for i, label in enumerate(unique_labels):
        h = _D3_HEX[i % len(_D3_HEX)].lstrip("#")
        r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
        _label_color[label] = f"rgba({r},{g},{b},0.82)"
    node_colors = [_label_color[lbl] for lbl in node_layout["node_labels"]]

    fig = go.Figure(
        data=[
            go.Sankey(
                arrangement="fixed",
                node=dict(
                    pad=SANKEY_NODE_PAD_PX,
                    thickness=18,
                    label=node_layout["node_labels"],
                    color=node_colors,
                    x=node_layout["node_x"],
                    y=node_layout["node_y"],
                ),
                link=dict(
                    source=link_parts["link_source"],
                    target=link_parts["link_target"],
                    value=link_parts["link_value"],
                    color=link_parts["link_colors"],
                    customdata=[days if days is not None else float("nan") for days in link_parts["link_avg_days"]],
                    hovertemplate="%{source.label} -> %{target.label}<br>clients: %{value}<br>Mean Days: %{customdata:.1f}<extra></extra>",
                ),
            )
        ]
    )

    title_suffix = "" if cohort_name == ALL_CLIENTS_LABEL else f" — {cohort_name}"
    fig.update_layout(
        title_text=f"Client project-type transitions{title_suffix}",
        font_size=11,
        height=PLOT_HEIGHT,
        margin=SANKEY_MARGIN,
        meta=dict(
            link_base_colors=link_parts["link_base_colors"],
            link_default_colors=link_parts["link_colors"],
            link_is_final_discharge=link_parts["link_is_final_discharge"],
        ),
    )
    return fig, (link_parts["days_lo"], link_parts["days_hi"])


figures_by_cohort = {}
days_range_by_cohort = {}

for cohort_name, cohort_df in cohort_transitions.items():
    cohort_links = aggregate_links(cohort_df)
    cohort_links = cohort_links.filter(pl.col("step") > 1)  # hide Program Entry node & edges
    if cohort_links.height == 0:
        continue
    figures_by_cohort[cohort_name], days_range_by_cohort[cohort_name] = build_sankey_figure(
        cohort_links, cohort_name
    )

if not figures_by_cohort:
    raise ValueError("No Sankey figures were created for the configured cohorts.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Render
# MAGIC Renders each figure via `displayHTML` with highlight controls and a **Fullscreen** button.
# MAGIC Fullscreen uses the browser's Fullscreen API and works only if the Databricks output
# MAGIC iframe allows it; otherwise open the standalone HTML files saved in the next section.

# COMMAND ----------

import uuid


def _color_legend_html(lo, hi, width=400, height=18):
    """Return an HTML color-bar legend for the avg-days gradient."""
    if lo is None or hi is None or hi <= lo:
        return ""
    log_lo = math.log1p(max(lo, 0.0))
    log_hi = math.log1p(max(hi, 0.0))
    n_ticks = 5
    # Ticks are evenly spaced in log-days and placed with the same gamma as link colors.
    ticks = []
    for i in range(n_ticks):
        t = i / (n_ticks - 1)
        days = math.expm1(log_lo + t * (log_hi - log_lo))
        ticks.append((t ** COLOR_GAMMA, days))
    gradient = "linear-gradient(to right, rgb(0,200,60), rgb(255,200,60), rgb(220,0,60))"
    tick_html = ""
    for t, days in ticks:
        left_pct = t * 100
        label = f"{days:.0f}" if days >= 1 else f"{days:.1f}"
        tick_html += (
            f'<div style="position:absolute; left:{left_pct}%; transform:translateX(-50%);'
            f' text-align:center;">'
            f'<div style="width:1px; height:6px; background:#666; margin:0 auto;"></div>'
            f'<div style="font-size:10px; color:#444; white-space:nowrap;">{label}</div>'
            f'</div>'
        )
    return (
        f'<div style="margin:28px 0 16px 0; display:inline-block;">'
        f'<div style="font-size:11px; color:#555; margin-bottom:3px;">'
        f'Mean days between enrollments (log-scaled)</div>'
        f'<div style="width:{width}px; height:{height}px; background:{gradient};'
        f' border-radius:3px; border:1px solid #ccc;"></div>'
        f'<div style="position:relative; width:{width}px; height:24px;">{tick_html}</div>'
        f'</div>'
    )


# Client-side JS: clicking a node highlights its downstream path; a button
# toggles Final Discharge edges.  Colors are restyled in place.
def _sankey_highlight_script(div_id):
    return f"""
    <script>
    (function() {{
      const gd = document.getElementById('{div_id}');
      const clearBtn = document.getElementById('{div_id}-clear');
      const finalBtn = document.getElementById('{div_id}-final-discharge');
      const DIMMED_NODE_ALPHA = 0.12;
      const DIMMED_LINK_ALPHA = 0.04;

      function withAlpha(color, alpha, fallback) {{
        const value = color || fallback;
        if (typeof value !== 'string') {{
          return value;
        }}
        const match = value.match(/rgba?\\(([^)]+)\\)/i);
        if (!match) {{
          return value;
        }}
        const parts = match[1].split(',').map(part => part.trim());
        const r = parts[0] || '120';
        const g = parts[1] || '120';
        const b = parts[2] || '120';
        return `rgba(${{r}},${{g}},${{b}},${{alpha}})`;
      }}

      function asArray(value, length, fallback) {{
        if (Array.isArray(value)) {{
          return value.slice();
        }}
        return Array.from({{ length }}, () => value || fallback);
      }}

      function asBoolArray(value, length) {{
        return asArray(value, length, false).map(item => item === true || item === 1 || item === 'true');
      }}

      // Retries until Plotly has rendered the figure into the div.
      function attach() {{
        if (!gd || !gd.data || !gd.data.length || !gd.data[0].node || !gd.data[0].link) {{
          window.setTimeout(attach, 120);
          return;
        }}

        const trace = gd.data[0];
        const meta = (gd.layout && gd.layout.meta) || {{}};
        const nodeCount = (trace.node.label || []).length;
        const linkCount = (trace.link.source || []).length;
        const baseNodeColors = asArray(trace.node.color, nodeCount, 'rgba(110,110,110,0.82)');
        const baseLinkColors = asArray(meta.link_base_colors || trace.link.color, linkCount, 'rgba(100,100,100,0.35)');
        const defaultLinkColors = asArray(meta.link_default_colors || trace.link.color, linkCount, 'rgba(100,100,100,0.35)');
        const finalDischargeFlags = asBoolArray(meta.link_is_final_discharge, linkCount);
        let activeNode = null;
        let finalDischargeMode = false;

        // Breadth-first walk over outgoing links from the clicked node.
        function downstreamFrom(startNode) {{
          const reachableNodes = new Set([startNode]);
          const reachableEdges = new Set();
          const queue = [startNode];

          while (queue.length) {{
            const current = queue.shift();
            for (let i = 0; i < trace.link.source.length; i += 1) {{
              const source = Number(trace.link.source[i]);
              const target = Number(trace.link.target[i]);
              if (source !== current) {{
                continue;
              }}
              reachableEdges.add(i);
              if (!reachableNodes.has(target)) {{
                reachableNodes.add(target);
                queue.push(target);
              }}
            }}
          }}

          return {{ reachableNodes, reachableEdges }};
        }}

        function finalDischargeNodes() {{
          const nodes = new Set();
          for (let i = 0; i < linkCount; i += 1) {{
            if (!finalDischargeFlags[i]) {{
              continue;
            }}
            nodes.add(Number(trace.link.source[i]));
            nodes.add(Number(trace.link.target[i]));
          }}
          return nodes;
        }}

        function render() {{
          let nodeColors = baseNodeColors.slice();
          let linkColors = finalDischargeMode
            ? baseLinkColors.map((color, index) =>
                finalDischargeFlags[index]
                  ? color
                  : withAlpha(color, DIMMED_LINK_ALPHA, 'rgba(100,100,100,0.35)')
              )
            : defaultLinkColors.slice();

          if (finalDischargeMode) {{
            const focusNodes = finalDischargeNodes();
            nodeColors = baseNodeColors.map((color, index) =>
              focusNodes.has(index)
                ? color
                : withAlpha(color, DIMMED_NODE_ALPHA, 'rgba(110,110,110,0.82)')
            );
          }}

          if (activeNode !== null) {{
            const downstream = downstreamFrom(activeNode);
            nodeColors = nodeColors.map((color, index) =>
              downstream.reachableNodes.has(index)
                ? color
                : withAlpha(color, DIMMED_NODE_ALPHA, 'rgba(110,110,110,0.82)')
            );
            linkColors = linkColors.map((color, index) =>
              downstream.reachableEdges.has(index)
                ? color
                : withAlpha(color, DIMMED_LINK_ALPHA, 'rgba(100,100,100,0.35)')
            );
          }}

          Plotly.restyle(
            gd,
            {{
              'node.color': [nodeColors],
              'link.color': [linkColors],
            }},
            [0]
          );

          if (clearBtn) {{
            clearBtn.disabled = activeNode === null;
          }}
          if (finalBtn) {{
            finalBtn.textContent = finalDischargeMode
              ? 'Hide Final Discharge edges'
              : 'Show Final Discharge edges';
          }}
        }}

        gd.on('plotly_click', function(eventData) {{
          const point = eventData && eventData.points && eventData.points[0];
          if (!point || typeof point.label === 'undefined') {{
            return;
          }}
          const clickedNode = Number(point.pointNumber);
          activeNode = activeNode === clickedNode ? null : clickedNode;
          render();
        }});

        if (clearBtn) {{
          clearBtn.addEventListener('click', function() {{
            activeNode = null;
            render();
          }});
        }}

        if (finalBtn) {{
          finalBtn.addEventListener('click', function() {{
            finalDischargeMode = !finalDischargeMode;
            activeNode = null;
            render();
          }});
        }}

        render();
      }}

      attach();
    }})();
    </script>
    """



# Plot, controls, legend and highlight script as an HTML fragment, or a full page.
def build_sankey_html(fig, heading=None, days_range=None, div_id=None, full_html=False):
    height_px = fig.layout.height
    div_id = div_id or f"sankey-{uuid.uuid4().hex}"
    inline_html = fig.to_html(full_html=False, include_plotlyjs="cdn", div_id=div_id)
    heading_html = (
        f'<div style="margin:18px 0 8px 0; font-weight:600; font-size:16px;">{heading}</div>'
        if heading
        else ""
    )

    body_html = f"""
    {heading_html}
    <div id="{div_id}-wrapper" style="background:white;">
      <div style="margin-bottom:8px; display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
        <button type="button" onclick="
          var el = document.getElementById('{div_id}-wrapper');
          if (el.requestFullscreen) {{ el.requestFullscreen().catch(function(e) {{
            alert('Fullscreen blocked by this notebook frame — use the saved HTML file instead (see cell below).');
          }}); }} else {{
            alert('Fullscreen API not available here — use the saved HTML file instead (see cell below).');
          }}
        ">Fullscreen</button>
        <button id="{div_id}-final-discharge" type="button">Show Final Discharge edges</button>
        <button id="{div_id}-clear" type="button">Clear highlight</button>
        <span style="font-size:12px; color:#555;">Click a node to highlight its downstream path, or isolate Final Discharge edges.</span>
      </div>
      <div style="height:{height_px}px;">
        {inline_html}
      </div>
      {_color_legend_html(days_range[0], days_range[1]) if days_range else ""}
    </div>
    {_sankey_highlight_script(div_id)}
    """

    if not full_html:
        return body_html

    return f"""
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <title>{heading or 'Client timeline sankey'}</title>
      </head>
      <body style="margin:0; padding:24px; font-family:Arial, sans-serif; background:white;">
        {body_html}
      </body>
    </html>
    """



for cohort_name, cohort_fig in figures_by_cohort.items():
    displayHTML(build_sankey_html(cohort_fig, heading=cohort_name, days_range=days_range_by_cohort[cohort_name]))

# COMMAND ----------

# MAGIC %md
# MAGIC ## Save as standalone HTML files
# MAGIC Writes the figures to DBFS FileStore as their own HTML pages (Plotly.js pulled from CDN,
# MAGIC no dependency on the notebook at all). Opening the printed link loads the plot outside
# MAGIC any Databricks iframe, so it can be freely fullscreened with F11 / your browser's
# MAGIC fullscreen control — this is the reliable path for a large/fullscreen view.

# COMMAND ----------

FILESTORE_DIR = "/FileStore/client_timeline_sankey"

dbutils.fs.mkdirs(FILESTORE_DIR)
workspace_url = spark.conf.get("spark.databricks.workspaceUrl", None)
multi_cohort = len(figures_by_cohort) > 1

for cohort_name, cohort_fig in figures_by_cohort.items():
    # A single combined diagram keeps the unsuffixed file name.
    if not multi_cohort and cohort_name == ALL_CLIENTS_LABEL:
        filename = "client_timeline_sankey.html"
    else:
        filename = f"client_timeline_sankey_{slugify_name(cohort_name)}.html"

    days_range = days_range_by_cohort.get(cohort_name)
    html_content = build_sankey_html(
        cohort_fig,
        heading=cohort_name,
        days_range=days_range,
        div_id=f"sankey-export-{slugify_name(cohort_name)}",
        full_html=True,
    )
    dbutils.fs.put(f"{FILESTORE_DIR}/{filename}", html_content, overwrite=True)

    # FileStore files are served at https://<workspace>/files/<path under /FileStore>.
    if workspace_url:
        print(f"{cohort_name}: https://{workspace_url}/files/client_timeline_sankey/{filename}")
    else:
        print(f"{cohort_name}: {FILESTORE_DIR}/{filename}")

# COMMAND ----------

# MAGIC %md ## Verification checks

# COMMAND ----------

# Entry flow should equal distinct clients within each cohort; step totals reveal attrition.
# Uses unfiltered links, since the plotted links omit the Program Entry step.
for cohort_name, cohort_df in cohort_transitions.items():
    all_links = aggregate_links(cohort_df)
    total_clients = cohort_df["personal_id"].n_unique()
    entry_flow = all_links.filter(pl.col("step") == 1)["count"].sum()
    print(f"\nCohort: {cohort_name}")
    print(f"Distinct personal_id: {total_clients}")
    print(
        f"Total flow out of '{ENTRY_NODE_LABEL}': {entry_flow}"
        f" ({'matches' if entry_flow == total_clients else 'MISMATCH'})"
    )

    flow_by_step = all_links.group_by("step").agg(pl.col("count").sum().alias("total_flow")).sort("step")
    print(flow_by_step)