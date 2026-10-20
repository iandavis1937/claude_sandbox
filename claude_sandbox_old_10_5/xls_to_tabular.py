#!/usr/bin/env python3
"""
xls_to_tabular.py -- stream Excel 97-2003 (.xls) worksheets out to CSV or Parquet.

Two engines, same CLI:

  calamine  (default when fastexcel is installed) -- parses the BIFF stream in
            Rust and hands back Arrow. ~4-5x faster end to end, at ~2x the peak
            memory: it loads a sheet whole, which is bounded anyway, since .xls
            caps at 65,536 rows x 256 columns.
  xlrd      -- pure Python, streams a sheet row by row with on_demand loading
            and unload_sheet() between sheets. Slower, but it reads a real type
            code per CELL, so "is this number actually a date" is answered by the
            file rather than by column-level inference. Used automatically for
            any sheet calamine cannot convert exactly.

Requires:  pip install xlrd==2.0.1                     (always)
           pip install pyarrow                         (Parquet output)
           pip install fastexcel polars                (calamine engine)

Note: xlrd 2.x reads .xls ONLY, which is what you want here. If a file turns out
to be .xlsx, convert it with openpyxl in read_only mode -- see --help epilog.

Examples:
    python xls_to_tabular.py big.xls -o out
    python xls_to_tabular.py big.xls -o out --format parquet --compression zstd
    python xls_to_tabular.py data_dir -o out --sheet "Sales*" --engine xlrd
    python xls_to_tabular.py big.xls -o out --header-row 3
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import datetime as dt
import glob
import gzip
import os
import re
import shutil
import sys
import tempfile
from fnmatch import fnmatch
from pathlib import Path

import xlrd
from xlrd import (
    XL_CELL_BLANK,
    XL_CELL_BOOLEAN,
    XL_CELL_DATE,
    XL_CELL_EMPTY,
    XL_CELL_ERROR,
    XL_CELL_NUMBER,
    XL_CELL_TEXT,
)

EMPTYISH = (XL_CELL_EMPTY, XL_CELL_BLANK)
UNNAMED = "__UNNAMED__"  # what fastexcel calls a column with no header text


# --------------------------------------------------------------------------- #
# shared helpers
# --------------------------------------------------------------------------- #
def safe_name(name):
    """Turn a sheet name into something safe for a filename on any OS."""
    cleaned = re.sub(r"[^\w.\- ]+", "_", name).strip().rstrip(".")
    cleaned = re.sub(r"\s+", "_", cleaned)
    return cleaned or "sheet"


def dedupe(names):
    """col, col -> col, col_1. Blank/unnamed -> col_N by position."""
    out, seen = [], {}
    for i, raw in enumerate(names):
        name = (raw or "").strip()
        if not name or name.startswith(UNNAMED):
            name = "col_%d" % (i + 1)
        if name in seen:
            seen[name] += 1
            name = "%s_%d" % (name, seen[name])
        else:
            seen[name] = 0
        out.append(name)
    return out


def fmt_csv(v):
    """Render a Python value for CSV."""
    if v is None:
        return ""
    if isinstance(v, dt.datetime):
        # Excel stores plain dates at midnight; "2019-04-01" reads better than
        # "2019-04-01 00:00:00".
        if (v.hour, v.minute, v.second, v.microsecond) == (0, 0, 0, 0):
            return v.date().isoformat()
        return v.isoformat(sep=" ")
    if isinstance(v, dt.date):
        return v.isoformat()
    if isinstance(v, float) and v.is_integer() and abs(v) < 2 ** 53:
        return str(int(v))
    return v


def open_csv_text(path, compress, encoding):
    if compress == "gzip":
        return gzip.open(str(path) + ".gz", "wt", newline="", encoding=encoding)
    return open(path, "w", newline="", encoding=encoding)


def open_csv_binary(path, compress):
    if compress == "gzip":
        return gzip.open(str(path) + ".gz", "wb")
    return open(path, "wb")


def progress(done, total, args):
    if not args.quiet:
        print("     ... %s / ~%s rows" % (format(done, ","), format(total, ",")),
              file=sys.stderr, flush=True)


def first_data_row(args, header_row):
    """Absolute 0-based index of the first data row."""
    if args.skip_rows is not None:
        return args.skip_rows
    return 0 if header_row is None else header_row + 1


# --------------------------------------------------------------------------- #
# xlrd engine -- per-cell types, row-by-row streaming
# --------------------------------------------------------------------------- #
def to_py(value, ctype, datemode):
    """Convert one xlrd cell to a plain Python value."""
    if ctype in EMPTYISH:
        return None
    if ctype == XL_CELL_TEXT:
        return value
    if ctype == XL_CELL_NUMBER:
        return value
    if ctype == XL_CELL_BOOLEAN:
        return bool(value)
    if ctype == XL_CELL_DATE:
        # Pure times come back with a zero date part; xldate_as_datetime handles
        # that. Serials Excel itself considers invalid raise, so keep the number.
        try:
            return xlrd.xldate.xldate_as_datetime(value, datemode)
        except (ValueError, OverflowError, xlrd.XLDateError):
            return value
    if ctype == XL_CELL_ERROR:
        return xlrd.error_text_from_code.get(value, "#ERR")
    return value


def xlrd_headers(sheet, header_row, ncols, datemode):
    if header_row is None:
        return ["col_%d" % (i + 1) for i in range(ncols)]
    values = sheet.row_values(header_row)
    types = sheet.row_types(header_row)
    raw = []
    for i in range(ncols):
        cell = to_py(values[i], types[i], datemode) if i < len(values) else None
        raw.append("" if cell is None else str(fmt_csv(cell)))
    return dedupe(raw)


def xlrd_column_types(sheet, first_row, ncols, sample_rows):
    """
    Decide a Parquet type per column by sampling xlrd's per-cell type codes --
    far more reliable than guessing from rendered strings. Mixed or all-empty
    columns become string.
    """
    import pyarrow as pa

    last = sheet.nrows if not sample_rows else min(sheet.nrows,
                                                   first_row + sample_rows)
    kinds = [set() for _ in range(ncols)]
    all_int = [True] * ncols

    for r in range(first_row, last):
        types = sheet.row_types(r)
        values = sheet.row_values(r)
        for c in range(min(ncols, len(types))):
            t = types[c]
            if t in EMPTYISH:
                continue
            if t == XL_CELL_NUMBER:
                kinds[c].add("num")
                v = values[c]
                if all_int[c] and (v != int(v) or abs(v) >= 2 ** 63):
                    all_int[c] = False
            elif t == XL_CELL_DATE:
                kinds[c].add("date")
            elif t == XL_CELL_BOOLEAN:
                kinds[c].add("bool")
            else:
                kinds[c].add("str")

    out = []
    for c in range(ncols):
        k = kinds[c]
        if len(k) != 1:
            out.append(pa.string())  # empty or mixed -> string
        elif "num" in k:
            out.append(pa.int64() if all_int[c] else pa.float64())
        elif "date" in k:
            out.append(pa.timestamp("us"))
        elif "bool" in k:
            out.append(pa.bool_())
        else:
            out.append(pa.string())
    return out


def coerce(v, arrow_type):
    """Last-mile coercion so a stray off-type cell below the sample window
    cannot kill the write."""
    import pyarrow as pa

    if v is None:
        return None
    if pa.types.is_string(arrow_type):
        return str(fmt_csv(v))
    if pa.types.is_integer(arrow_type):
        try:
            return int(v)
        except (TypeError, ValueError):
            return None
    if pa.types.is_floating(arrow_type):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None
    if pa.types.is_boolean(arrow_type):
        return bool(v)
    if pa.types.is_timestamp(arrow_type):
        return v if isinstance(v, dt.datetime) else None
    return v


def xlrd_to_csv(sheet, out_path, headers, first_row, ncols, datemode, args):
    written = 0
    total = sheet.nrows - first_row
    with open_csv_text(out_path, args.compression, args.encoding) as fh:
        writer = csv.writer(fh, delimiter=args.delimiter,
                            quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
        if headers is not None:
            writer.writerow(headers)

        buf = []
        for r in range(first_row, sheet.nrows):
            values, types = sheet.row_values(r), sheet.row_types(r)
            row = [fmt_csv(to_py(values[c], types[c], datemode)) if c < len(values)
                   else "" for c in range(ncols)]
            if args.skip_blank_rows and not any(x != "" for x in row):
                continue
            buf.append(row)
            if len(buf) >= args.chunk_rows:
                writer.writerows(buf)
                written += len(buf)
                buf = []
                progress(written, total, args)
        if buf:
            writer.writerows(buf)
            written += len(buf)
    return written


def xlrd_to_parquet(sheet, out_path, headers, first_row, ncols, datemode, args):
    import pyarrow as pa
    import pyarrow.parquet as pq

    types = xlrd_column_types(sheet, first_row, ncols, args.sample_rows)
    schema = pa.schema([pa.field(h, t) for h, t in zip(headers, types)])
    total = sheet.nrows - first_row

    def flush(writer, cols):
        writer.write_table(pa.Table.from_arrays(
            [pa.array(col, type=t) for col, t in zip(cols, types)], schema=schema))

    written = 0
    writer = pq.ParquetWriter(out_path, schema,
                              compression=args.compression or "snappy")
    try:
        cols = [[] for _ in range(ncols)]
        n = 0
        for r in range(first_row, sheet.nrows):
            rv, rt = sheet.row_values(r), sheet.row_types(r)
            row = [to_py(rv[c], rt[c], datemode) if c < len(rv) else None
                   for c in range(ncols)]
            if args.skip_blank_rows and all(x is None or x == "" for x in row):
                continue
            for c in range(ncols):
                cols[c].append(coerce(row[c], types[c]))
            n += 1
            if n >= args.chunk_rows:
                flush(writer, cols)
                written += n
                cols = [[] for _ in range(ncols)]
                n = 0
                progress(written, total, args)
        if n:
            flush(writer, cols)
            written += n
    finally:
        writer.close()
    return written


def xlrd_convert_sheet(sheet, out_path, datemode, args):
    """Convert one already-loaded xlrd sheet. Returns rows written."""
    ncols = sheet.ncols
    header_row = None if args.no_header else args.header_row
    if header_row is not None and header_row >= sheet.nrows:
        header_row = None
    headers = xlrd_headers(sheet, header_row, ncols, datemode)
    start = min(first_data_row(args, header_row), sheet.nrows)

    if args.format == "csv":
        return xlrd_to_csv(sheet, out_path, None if args.no_header else headers,
                           start, ncols, datemode, args)
    return xlrd_to_parquet(sheet, out_path, headers, start, ncols, datemode, args)


class XlrdBook:
    """Lazily-opened xlrd workbook, used as the engine or as the fallback."""

    def __init__(self, path, ignore_corruption=False):
        self.path = str(path)
        self.ignore_corruption = ignore_corruption
        self._book = None

    @property
    def book(self):
        # on_demand=True keeps sheet bodies unparsed until asked for;
        # formatting_info stays off -- we only want values and it roughly
        # doubles parse cost.
        if self._book is None:
            self._book = xlrd.open_workbook(
                self.path, on_demand=True, formatting_info=False,
                ignore_workbook_corruption=self.ignore_corruption)
        return self._book

    def sheet_names(self):
        return self.book.sheet_names()

    def convert(self, name, out_path, args):
        idx = self.book.sheet_names().index(name)
        sheet = self.book.sheet_by_index(idx)
        try:
            if sheet.nrows == 0 or sheet.ncols == 0:
                return None
            return xlrd_convert_sheet(sheet, out_path, self.book.datemode, args)
        finally:
            # The whole point: drop this sheet before touching the next one.
            self.book.unload_sheet(idx)

    def close(self):
        if self._book is not None:
            self._book.release_resources()
            self._book = None


# --------------------------------------------------------------------------- #
# calamine engine -- Rust parser via fastexcel, Arrow in, Arrow/Polars out
# --------------------------------------------------------------------------- #
def drop_blank_rows(table):
    """Filter out rows where every cell is null or an empty string."""
    import pyarrow as pa
    import pyarrow.compute as pc

    mask = None
    for col in table.columns:
        blank = pc.is_null(col)
        if pa.types.is_string(col.type) or pa.types.is_large_string(col.type):
            blank = pc.or_(blank, pc.equal(col, ""))
        mask = blank if mask is None else pc.and_(mask, blank)
    if mask is None:
        return table
    return table.filter(pc.invert(pc.fill_null(mask, False)))


def match_xlrd_schema(table):
    """Make the calamine table's schema match what the xlrd engine emits, so the
    two engines produce interchangeable Parquet: microsecond timestamps (calamine
    hands back ms), and every column nullable (calamine marks a column not null
    when the sheet happens to have no gaps in it)."""
    import pyarrow as pa

    fields = []
    for f in table.schema:
        ftype = f.type
        if pa.types.is_timestamp(ftype) and ftype.unit != "us":
            ftype = pa.timestamp("us")
        fields.append(pa.field(f.name, ftype, nullable=True))
    return table.cast(pa.schema(fields))


def calamine_load(reader, name, args):
    """Load one sheet as an Arrow table, honouring the header/skip options."""
    import pyarrow as pa

    header_row = None if args.no_header else args.header_row
    # fastexcel's skip_rows counts from AFTER the header row; ours is absolute.
    base = 0 if header_row is None else header_row + 1
    extra = max(0, first_data_row(args, header_row) - base)

    def load(**kw):
        sheet = reader.load_sheet(name, header_row=header_row, skip_rows=extra,
                                  schema_sample_rows=args.sample_rows or None, **kw)
        out = sheet.to_arrow()
        if isinstance(out, pa.RecordBatch):  # fastexcel >=0.21 returns a batch
            out = pa.Table.from_batches([out])
        return out

    table = load()

    # Guard the one case where calamine silently loses data: a column mixing
    # text with numbers gets stringified, and it renders floats to 9 decimal
    # places, so 1/7 would land as "0.142857143". Re-read just the string
    # columns under strict coercion -- cheap, since it materialises only those.
    # If they are genuinely all text nothing was coerced and we are safe; if one
    # is mixed this raises, and the driver hands the sheet to xlrd.
    #
    # Note strict coercion is useless as a blanket setting: it also rejects the
    # entirely benign {Float, Int} combination that any numeric column with a
    # whole-numbered value in it produces.
    str_idx = [i for i, f in enumerate(table.schema)
               if pa.types.is_string(f.type) or pa.types.is_large_string(f.type)]
    if str_idx:
        load(dtype_coercion="strict", use_columns=str_idx)

    table = table.rename_columns(dedupe(table.column_names))
    if args.skip_blank_rows:
        table = drop_blank_rows(table)
    return table


def polars_can_write_csv(args):
    """The Polars fast path only handles UTF-8; anything else goes the slow,
    fully-controlled route."""
    if args.encoding.lower().replace("_", "-") not in ("utf-8", "utf8", "utf-8-sig"):
        return False
    try:
        import polars  # noqa: F401
    except ImportError:
        return False
    return True


def arrow_to_csv_polars(table, out_path, args):
    import polars as pl

    df = pl.from_arrow(table)

    # Normalise the places where Polars' own rendering differs from the xlrd
    # engine's, so switching engines does not change the bytes.
    exprs = []
    for c, t in zip(df.columns, df.dtypes):
        if t == pl.Boolean:
            # Polars writes true/false; we want True/False.
            exprs.append(pl.col(c).cast(pl.String).str.to_titlecase().alias(c))
        elif t == pl.Datetime:
            # Excel stores plain dates at midnight. If no row in the column
            # carries a time, drop it -- "2019-04-01", not "2019-04-01 00:00:00".
            if not df.height or (df[c].dt.time() == dt.time(0)).all():
                exprs.append(pl.col(c).cast(pl.Date).alias(c))
        elif t == pl.Float64:
            # Whole numbers stored as floats print as 3, not 3.0.
            exprs.append(
                pl.when(pl.col(c).is_finite()
                        & (pl.col(c) == pl.col(c).round(0))
                        & (pl.col(c).abs() < 2 ** 53))
                .then(pl.col(c).cast(pl.Int64).cast(pl.String))
                .otherwise(pl.col(c).cast(pl.String))
                .alias(c))
    if exprs:
        df = df.with_columns(exprs)

    with open_csv_binary(out_path, args.compression) as fh:
        if args.encoding.lower().replace("_", "-") == "utf-8-sig":
            fh.write(b"\xef\xbb\xbf")
        df.write_csv(fh, separator=args.delimiter, include_header=not args.no_header,
                     date_format="%Y-%m-%d", datetime_format="%Y-%m-%d %H:%M:%S",
                     null_value="", quote_style="necessary")
    return df.height


def arrow_to_csv_python(table, out_path, args):
    """Slower, but byte-identical to the xlrd engine's formatting."""
    written = 0
    ncols = table.num_columns
    with open_csv_text(out_path, args.compression, args.encoding) as fh:
        writer = csv.writer(fh, delimiter=args.delimiter,
                            quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
        if not args.no_header:
            writer.writerow(table.column_names)
        for batch in table.to_batches(max_chunksize=args.chunk_rows):
            rows = [[fmt_csv(v) for v in row.values()]
                    for row in batch.to_pylist()]
            writer.writerows(rows)
            written += len(rows)
            progress(written, table.num_rows, args)
    return written


def calamine_convert_sheet(reader, name, out_path, args):
    table = calamine_load(reader, name, args)
    if table.num_rows == 0 or table.num_columns == 0:
        return None

    if args.format == "csv":
        if polars_can_write_csv(args):
            return arrow_to_csv_polars(table, out_path, args)
        return arrow_to_csv_python(table, out_path, args)

    import pyarrow.parquet as pq

    table = match_xlrd_schema(table)
    pq.write_table(table, out_path, compression=args.compression or "snappy",
                   row_group_size=args.chunk_rows)
    return table.num_rows


# --------------------------------------------------------------------------- #
# format sniffing -- a lot of files named .xls are not .xls
# --------------------------------------------------------------------------- #
OLE_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"   # real BIFF8 .xls
ZIP_MAGIC = b"PK\x03\x04"                          # .xlsx / .ods
BIFF_MAGIC = (b"\x09\x08", b"\x09\x04", b"\x09\x02", b"\x09\x00")

ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ISO_DATETIME = re.compile(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?")


@contextlib.contextmanager
def aliased_suffix(path, suffix):
    """fastexcel dispatches on the file EXTENSION, not the content, so a .xlsx
    wearing a .xls name fails to open. Present it under a correct name -- a
    hardlink where the filesystem allows one, else a copy."""
    tmp = Path(tempfile.mkdtemp(prefix="xls2tab_"))
    alias = tmp / ("data" + suffix)
    try:
        try:
            os.link(path, alias)
        except (OSError, NotImplementedError, AttributeError):
            shutil.copy2(path, alias)
        yield alias
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def sniff_format(path):
    """What the bytes actually say this file is, regardless of its extension."""
    with open(path, "rb") as fh:
        head = fh.read(4096)
    if head.startswith(OLE_MAGIC):
        return "xls"
    if head.startswith(ZIP_MAGIC):
        return "xlsx"
    if head[:2] in BIFF_MAGIC:
        return "xls"  # bare BIFF stream, no OLE wrapper; xlrd handles it
    if head.startswith(b"%PDF"):
        return "pdf"
    probe = head.lstrip()[:512].lower()
    if probe.startswith(b"<"):
        return "html"
    if probe.startswith(b"id;"):
        return "sylk"
    if b"\x00" in head:
        return "unknown"
    return "text"


def sniff_text(path):
    """Guess (encoding, delimiter) for a delimited text file."""
    import codecs

    with open(path, "rb") as fh:
        raw = fh.read(65536)

    enc = "latin-1"
    for cand in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            # final=False so a multi-byte char split by the read boundary does
            # not look like a decode failure.
            sample = codecs.getincrementaldecoder(cand)().decode(raw, False)
            enc = cand
            break
        except UnicodeDecodeError:
            continue

    try:
        delim = csv.Sniffer().sniff(sample[:8192], delimiters=",\t;|").delimiter
    except csv.Error:
        first = sample.splitlines()[0] if sample.splitlines() else ""
        delim = max("\t,;|", key=first.count)
    return enc, delim


def text_column_types(sample, ncols):
    """Conservative types for delimited text: int, float, ISO timestamp, else
    string. Text dates in other layouts stay strings -- guessing day/month order
    is how silent data corruption happens."""
    import pyarrow as pa

    kinds = [{"int", "float", "ts"} for _ in range(ncols)]
    seen = [False] * ncols

    for row in sample:
        for c in range(min(ncols, len(row))):
            v = row[c].strip()
            if not v:
                continue
            seen[c] = True
            k = kinds[c]
            if "int" in k:
                try:
                    int(v)
                except ValueError:
                    k.discard("int")
            if "float" in k:
                try:
                    float(v)
                except ValueError:
                    k.discard("float")
            if "ts" in k and not (ISO_DATE.match(v) or ISO_DATETIME.match(v)):
                k.discard("ts")

    out = []
    for c in range(ncols):
        k = kinds[c]
        if not seen[c]:
            out.append(pa.string())
        elif "int" in k:
            out.append(pa.int64())
        elif "ts" in k:
            out.append(pa.timestamp("us"))
        elif "float" in k:
            out.append(pa.float64())
        else:
            out.append(pa.string())
    return out


def coerce_text(v, arrow_type):
    import pyarrow as pa

    v = v.strip() if isinstance(v, str) else v
    if v is None or v == "":
        return None
    if pa.types.is_int64(arrow_type):
        try:
            return int(v)
        except ValueError:
            return None
    if pa.types.is_floating(arrow_type):
        try:
            return float(v)
        except ValueError:
            return None
    if pa.types.is_timestamp(arrow_type):
        try:
            return dt.datetime.fromisoformat(v.replace("T", " "))
        except ValueError:
            return None
    return v


def read_text_rows(path, enc, delim, args):
    """Stream rows of a delimited text file, applying header/skip options.
    Returns (headers, row-iterator-factory)."""
    def rows():
        with open(path, "r", newline="", encoding=enc) as fh:
            for row in csv.reader(fh, delimiter=delim):
                yield row

    header_row = None if args.no_header else args.header_row
    headers, ncols = None, 0
    for i, row in enumerate(rows()):
        if header_row is not None and i == header_row:
            headers = dedupe(row)
        ncols = max(ncols, len(row))
        if i >= max(args.sample_rows or 0, (header_row or 0) + 1, 1000):
            break
    if headers is None:
        headers = ["col_%d" % (i + 1) for i in range(ncols)]
    elif len(headers) < ncols:
        headers = dedupe(headers + [""] * (ncols - len(headers)))

    start = first_data_row(args, header_row)

    def data():
        for i, row in enumerate(rows()):
            if i < start:
                continue
            if len(row) < ncols:
                row = row + [""] * (ncols - len(row))
            elif len(row) > ncols:
                row = row[:ncols]
            if args.skip_blank_rows and not any(x.strip() for x in row):
                continue
            yield row

    return headers, ncols, data


def convert_text_file(path, out_dir, args):
    """Convert a delimited text file that happens to be named .xls."""
    enc, delim = sniff_text(path)
    if not args.quiet:
        shown = {"\t": "tab", ",": "comma", ";": "semicolon", "|": "pipe"}
        print("  delimited text: %s-separated, %s" % (shown.get(delim, delim), enc),
              file=sys.stderr)

    headers, ncols, data = read_text_rows(path, enc, delim, args)
    ext = "csv" if args.format == "csv" else "parquet"
    out_path = out_dir / ("%s.%s" % (path.stem, ext))
    if out_path.exists() and not args.overwrite:
        print("  [skip] %s exists (use --overwrite)" % out_path.name,
              file=sys.stderr)
        return 0
    if not args.quiet:
        print("  -> %s" % out_path.name, file=sys.stderr)

    written = 0
    if args.format == "csv":
        with open_csv_text(out_path, args.compression, args.encoding) as fh:
            writer = csv.writer(fh, delimiter=args.delimiter,
                                quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
            if not args.no_header:
                writer.writerow(headers)
            buf = []
            for row in data():
                buf.append(row)
                if len(buf) >= args.chunk_rows:
                    writer.writerows(buf)
                    written += len(buf)
                    buf = []
            if buf:
                writer.writerows(buf)
                written += len(buf)
        return written

    import pyarrow as pa
    import pyarrow.parquet as pq

    sample = []
    for row in data():
        sample.append(row)
        if len(sample) >= (args.sample_rows or 5000):
            break
    types = text_column_types(sample, ncols)
    schema = pa.schema([pa.field(h, t) for h, t in zip(headers, types)])

    writer = pq.ParquetWriter(out_path, schema,
                              compression=args.compression or "snappy")
    try:
        cols = [[] for _ in range(ncols)]
        n = 0
        for row in data():
            for c in range(ncols):
                cols[c].append(coerce_text(row[c], types[c]))
            n += 1
            if n >= args.chunk_rows:
                writer.write_table(pa.Table.from_arrays(
                    [pa.array(col, type=t) for col, t in zip(cols, types)],
                    schema=schema))
                written += n
                cols = [[] for _ in range(ncols)]
                n = 0
        if n:
            writer.write_table(pa.Table.from_arrays(
                [pa.array(col, type=t) for col, t in zip(cols, types)],
                schema=schema))
            written += n
    finally:
        writer.close()
    return written


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #
def pick_engine(requested):
    """Returns 'calamine' or 'xlrd'. 'auto' prefers calamine when available."""
    if requested == "xlrd":
        return "xlrd"
    try:
        import fastexcel  # noqa: F401
    except ImportError:
        if requested == "calamine":
            print("error: --engine calamine needs fastexcel "
                  "(pip install fastexcel polars)", file=sys.stderr)
            return None
        return "xlrd"
    return "calamine"


def output_path(xls_path, sheet_name, out_dir, ext, multi, args):
    stem = xls_path.stem
    if multi or not args.flat_names:
        stem = "%s__%s" % (xls_path.stem, safe_name(sheet_name))
    return out_dir / ("%s.%s" % (stem, ext))


def convert_workbook(xls_path, out_dir, args, engine, fallback_ok=True,
                     reader_path=None, note=""):
    if not args.quiet:
        print("%s  (%.1f MB)  [%s%s]"
              % (xls_path.name, xls_path.stat().st_size / 1024 / 1024,
                 note, engine), file=sys.stderr)

    ext = "csv" if args.format == "csv" else "parquet"
    fallback = XlrdBook(xls_path, args.ignore_corruption)
    reader = None

    try:
        if engine == "calamine":
            import fastexcel
            reader = fastexcel.read_excel(str(reader_path or xls_path))
            names = reader.sheet_names
        else:
            names = fallback.sheet_names()

        multi = len(names) > 1
        total = 0

        for name in names:
            if args.sheet and not any(fnmatch(name, pat) for pat in args.sheet):
                continue

            out_path = output_path(xls_path, name, out_dir, ext, multi, args)
            if out_path.exists() and not args.overwrite:
                print("  [skip] %s exists (use --overwrite)" % out_path.name,
                      file=sys.stderr)
                continue

            if not args.quiet:
                print("  -> %s" % out_path.name, file=sys.stderr)

            n = None
            if engine == "calamine":
                try:
                    n = calamine_convert_sheet(reader, name, out_path, args)
                except (UnicodeError, OSError):
                    # A write-side failure. xlrd would hit exactly the same wall,
                    # so let it propagate rather than doing the work twice.
                    raise
                except BaseException as exc:
                    # Not just Exception: a calamine panic surfaces through pyo3
                    # as PanicException, which derives from BaseException.
                    if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                        raise
                    if not fallback_ok:
                        raise  # e.g. a .xlsx, which xlrd 2.x cannot read at all
                    # Per-sheet fallback. xlrd reads a type code per cell, so it
                    # handles the mixed columns strict coercion refuses -- slower
                    # for this sheet, but exact.
                    if not args.quiet:
                        print("  [warn] calamine declined %r (%s) -- using xlrd "
                              "for exact values" % (name, type(exc).__name__),
                              file=sys.stderr)
                    n = fallback.convert(name, out_path, args)
            else:
                n = fallback.convert(name, out_path, args)

            if n is None:
                if not args.quiet:
                    print("     [skip] empty", file=sys.stderr)
                continue
            total += n
            if not args.quiet:
                print("     wrote %s rows" % format(n, ","), file=sys.stderr)
        return total
    finally:
        fallback.close()


EPILOG = """\
engines:
  auto      calamine if fastexcel is installed, else xlrd (default)
  calamine  Rust parser, ~4-5x faster; loads a sheet at a time into Arrow
  xlrd      pure Python, per-cell type codes, streams row by row

The two engines are written to agree: on a 3-sheet x 65,000-row workbook, every
combination of the options below produced byte-identical CSV and equal Parquet
tables either way. calamine costs roughly 2x the peak memory of xlrd, since it
materialises a sheet rather than streaming it.

A sheet is handed to xlrd automatically when calamine cannot do it exactly --
chiefly a column mixing text with numbers, which calamine stringifies at 9
decimal places. Pass -q to silence those notices, or --engine xlrd to skip
calamine entirely. A non-UTF-8 --encoding also bypasses the Polars CSV writer.

Remaining calamine-path differences, all in rare float territory: NaN prints as
"NaN" rather than "nan", and 1e-09 as "1e-9".

If a file is actually .xlsx despite its name, xlrd 2.x will refuse it. For those,
read with openpyxl in read-only mode, which streams the same way:

    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    for row in wb[sheet].iter_rows(values_only=True): ...

The chunked-write logic here applies unchanged.
"""


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Stream .xls worksheets to CSV or Parquet, one sheet at a time.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=EPILOG)
    p.add_argument("inputs", nargs="+",
                   help=".xls files, directories, or glob patterns")
    p.add_argument("-o", "--out-dir", default=".", help="output directory")
    p.add_argument("-f", "--format", choices=["csv", "parquet"], default="csv")
    p.add_argument("-e", "--engine", choices=["auto", "calamine", "xlrd"],
                   default="auto", help="parser backend (default: auto)")
    p.add_argument("--sheet", action="append", metavar="PATTERN",
                   help="only sheets matching this glob (repeatable)")
    p.add_argument("--header-row", type=int, default=0,
                   help="0-based row holding column names (default: 0)")
    p.add_argument("--no-header", action="store_true",
                   help="treat every row as data; name columns col_1..col_N")
    p.add_argument("--skip-rows", type=int, default=None, metavar="N",
                   help="first 0-based data row (default: header row + 1)")
    p.add_argument("--chunk-rows", type=int, default=50000,
                   help="rows per write / parquet row group (default: 50000)")
    p.add_argument("--sample-rows", type=int, default=5000,
                   help="rows sampled for type inference, 0 = all (default: 5000)")
    p.add_argument("--compression", default=None,
                   help="parquet: snappy|zstd|gzip|brotli|none (default snappy); "
                        "csv: gzip to write .csv.gz")
    p.add_argument("--delimiter", default=",", help="CSV delimiter (default ,)")
    p.add_argument("--encoding", default="utf-8-sig",
                   help="CSV encoding (default utf-8-sig, Excel-friendly)")
    p.add_argument("--skip-blank-rows", action="store_true",
                   help="drop rows where every cell is empty")
    p.add_argument("--flat-names", action="store_true",
                   help="name single-sheet output after the file alone")
    p.add_argument("--ignore-corruption", action="store_true",
                   help="tell xlrd to push past a damaged OLE container "
                        "(recovers what is readable; may lose records)")
    p.add_argument("--overwrite", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")
    return p.parse_args(argv)


def expand(inputs):
    found = []
    for item in inputs:
        pth = Path(item)
        if pth.is_dir():
            found += sorted(pth.glob("*.xls"))
        elif any(ch in item for ch in "*?["):
            found += [Path(m) for m in sorted(glob.glob(item))]
        elif pth.exists():
            found.append(pth)
        else:
            print("warning: no such path: %s" % item, file=sys.stderr)
    return [f for f in found if f.suffix.lower() == ".xls"]


def main(argv=None):
    args = parse_args(argv)
    if args.format == "csv" and args.compression not in (None, "gzip"):
        print("error: csv output supports --compression gzip only", file=sys.stderr)
        return 2

    engine = pick_engine(args.engine)
    if engine is None:
        return 2

    files = expand(args.inputs)
    if not files:
        print("error: no .xls files matched", file=sys.stderr)
        return 2

    if args.format == "parquet":
        try:
            import pyarrow  # noqa: F401
        except ImportError:
            print("error: parquet output needs pyarrow (pip install pyarrow)",
                  file=sys.stderr)
            return 2

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    grand, failures = 0, 0
    for f in files:
        try:
            fmt = sniff_format(f)
            if fmt == "text":
                # Not corrupt -- an export tool wrote delimited text and named
                # it .xls. Excel opens those, which is why nobody notices.
                if not args.quiet:
                    print("%s  (%.1f MB)  [not a real .xls]"
                          % (f.name, f.stat().st_size / 1024 / 1024),
                          file=sys.stderr)
                grand += convert_text_file(f, out_dir, args)
            elif fmt == "xlsx":
                if engine != "calamine":
                    raise ValueError(
                        "this is really a .xlsx (ZIP) file; xlrd 2.x cannot read "
                        "it. Install fastexcel, or use openpyxl in read_only mode")
                with aliased_suffix(f, ".xlsx") as alias:
                    grand += convert_workbook(f, out_dir, args, engine,
                                              fallback_ok=False,
                                              reader_path=alias,
                                              note="really .xlsx; ")
            elif fmt == "xls":
                grand += convert_workbook(f, out_dir, args, engine)
            else:
                raise ValueError(
                    "not a spreadsheet: sniffed as %s. Rename it and open it with "
                    "the right tool (%s)"
                    % (fmt, {"html": "pandas.read_html", "sylk": "a SYLK reader",
                             "pdf": "a PDF extractor"}.get(fmt, "unknown format")))
        except Exception as exc:  # keep going through the rest of the batch
            failures += 1
            print("error: %s: %s: %s" % (f, type(exc).__name__, exc),
                  file=sys.stderr)

    if not args.quiet:
        print("\ndone: %s rows from %d/%d file(s) -> %s"
              % (format(grand, ","), len(files) - failures, len(files), out_dir),
              file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
