"""Drop CSV columns that don't exist in the native (v330) tables; write to csv_v330/."""
import os, sys, pathlib
import pandas as pd
import psycopg2

src = pathlib.Path("data/synthea/csv")
dst = pathlib.Path("data/synthea/csv_v330")
dst.mkdir(parents=True, exist_ok=True)
schema = os.getenv("NATIVE_SCHEMA", "native")

missing = [k for k in ("DB_USER", "DB_PASSWORD") if not os.environ.get(k)]
if missing:
    sys.exit(f"ERROR: required environment variable(s) not set: {', '.join(missing)}")

conn = psycopg2.connect(
    host=os.getenv("DB_HOST", "localhost"), port=os.getenv("DB_PORT", "5432"),
    dbname=os.getenv("DB_NAME", "omop"), user=os.environ["DB_USER"],
    password=os.environ["DB_PASSWORD"])
cur = conn.cursor()
cur.execute("""select table_name, column_name from information_schema.columns
               where table_schema=%s""", (schema,))
cols = {}
for t, c in cur.fetchall():
    cols.setdefault(t.lower(), set()).add(c.lower())

for f in sorted(src.glob("*.csv")):
    table = f.stem.lower()
    if table not in cols:
        print(f"SKIP  {f.name}: no table {schema}.{table}")
        continue
    df = pd.read_csv(f, dtype=str, keep_default_na=False)  # keep leading zeros, empty strings
    extra = [c for c in df.columns if c.lower() not in cols[table]]
    missing = [c for c in cols[table] if c not in {x.lower() for x in df.columns}]
    df.drop(columns=extra).to_csv(dst / f.name, index=False)
    print(f"{f.name}: dropped {extra or '-'}; missing in CSV {missing or '-'}")
