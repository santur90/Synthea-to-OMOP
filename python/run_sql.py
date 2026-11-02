"""Minimal SQL file runner for PostgreSQL (replacement for psql).

Usage: python python/run_sql.py sql/03_build_analytic_cohort.sql [more.sql ...]

Credentials come from environment variables only: DB_USER and DB_PASSWORD are
required; DB_HOST (localhost), DB_PORT (5432) and DB_NAME (omop) have defaults.
Each file runs in autocommit mode and stops at the first error.
"""
import os
import re
import sys


def require_credentials():
    missing = [k for k in ("DB_USER", "DB_PASSWORD") if not os.environ.get(k)]
    if missing:
        raise SystemExit(
            f"ERROR: required environment variable(s) not set: {', '.join(missing)}. "
            "Copy .env.example to .env and fill them in."
        )


def connect():
    require_credentials()
    import psycopg2

    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "omop"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


def split_statements(sql):
    """Strip -- comments and split on ';', keeping $$ ... $$ blocks intact."""
    sql = re.sub(r"--[^\n]*", "", sql)
    stmts, buf, in_dollar = [], "", False
    for line in sql.split("\n"):
        if line.count("$$") % 2 == 1:
            in_dollar = not in_dollar
        buf += line + "\n"
        if not in_dollar and line.rstrip().endswith(";"):
            stmts.append(buf.strip())
            buf = ""
    if buf.strip():
        stmts.append(buf.strip())
    return [s for s in stmts if s]


def run_file(conn, path):
    with open(path) as fh:
        stmts = split_statements(fh.read())
    print(f"Running {path} ({len(stmts)} statements)")
    cur = conn.cursor()
    for s in stmts:
        cur.execute(s)
        if cur.description:
            print([d[0] for d in cur.description])
            for row in cur.fetchall():
                print(row)
            print()


def main(argv):
    if not argv:
        raise SystemExit("usage: python python/run_sql.py FILE.sql [FILE.sql ...]")
    require_credentials()  # fail before touching the filesystem or database
    conn = connect()
    conn.autocommit = True
    try:
        for path in argv:
            run_file(conn, path)
    finally:
        conn.close()


if __name__ == "__main__":
    main(sys.argv[1:])
