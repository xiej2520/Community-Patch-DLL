#!/usr/bin/env python3
"""
Check mod SQL/XML database changes against a copy of the game's database.

Civ V stops executing a SQL file at its first failing statement and silently
skips the rest, so a single bad table or column name can disable a large part
of a component. A plain SQLite syntax check does not catch this; the statements
must be compiled against the real schema.

Usage:
    python validate_sql.py --db Civ5DebugDatabase.db "(2) Vox Populi"
    python validate_sql.py --db Civ5DebugDatabase.db --loc-db Civ5LocalizationDatabase.db "(1)" "(2)"
    python validate_sql.py --db Civ5DebugDatabase.db "(2) Vox Populi/Database Changes/Units/UnitChanges.sql"

Arguments can be .civ5proj files, component directories, unique directory
prefixes (as for generate_modinfo.py), or individual .sql/.xml files. For a
project, its UpdateDatabase actions are checked in ModActions order on one
connection, as the game does.

Get the databases from "My Games/Sid Meier's Civilization 5/cache" after
starting a game with the mods enabled, and copy them before running
deploy-vp.sh, which deletes that folder. The copies are never modified: the
check runs on a temporary copy inside a transaction that is rolled back.

How statements are checked:
  - CREATE/DROP/ALTER statements are executed so later statements see the
    schema they create. "already exists" and "duplicate column" errors are
    accepted for permanent tables, indexes, triggers and views, because the
    copied database already contains the mods' schema; they are errors for
    TEMP tables, since a leaked TEMP table is a real failure in game.
  - Other statements are compiled with EXPLAIN without being run, which
    reports missing tables and columns without row-level conflicts.
  - Like the game, a SQL file stops at its first error.
  - XML files are checked for unknown tables and columns in Row, Replace,
    Update (Where/Set) and Delete elements; <Table> definitions are created.

Limitations: Python's SQLite is newer than the game's, so syntax the game's
SQLite lacks is not detected, and data errors (constraint violations, bad
references) still require the game's Database.log.
"""

import argparse
import re
import shutil
import sqlite3
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_modinfo  # noqa: E402

LEADING_COMMENTS = re.compile(r'^(\s*(--[^\n]*\n|/\*.*?\*/))*\s*', re.S)
XML_COMMENT = re.compile(r'<!--.*?-->', re.S)
LANGUAGE_TABLE = re.compile(r'^\s*(?:\w+\.)?"?Language_\w+', re.I)
IDEMPOTENT_ERRORS = ('already exists', 'duplicate column')


def split_statements(text: str) -> List[Tuple[int, str]]:
    """Split SQL into (start line, statement) pairs."""
    statements = []
    buf = ''
    start = None
    for lineno, line in enumerate(text.splitlines(True), 1):
        if start is None and line.strip() and not line.strip().startswith('--'):
            start = lineno
        buf += line
        if sqlite3.complete_statement(buf):
            statements.append((start or lineno, buf.strip()))
            buf = ''
            start = None
    tail = LEADING_COMMENTS.sub('', buf).strip()
    if tail:
        # SQLite also runs a final statement that lacks its semicolon.
        statements.append((start or 1, tail))
    return statements


def table_columns(conn: sqlite3.Connection, table: str) -> Optional[set]:
    for schema in ('main', 'temp', 'loc'):
        try:
            rows = conn.execute(f'PRAGMA {schema}.table_info("{table}")').fetchall()
        except sqlite3.Error:
            continue
        if rows:
            return {row[1].lower() for row in rows}
    return None


class Checker:
    def __init__(self, conn: sqlite3.Connection, has_loc: bool):
        self.conn = conn
        self.has_loc = has_loc
        self.errors = 0
        self.skipped_loc = 0

    def report(self, where: str, message: str) -> None:
        self.errors += 1
        print(f'ERROR {where}: {message}')

    def check_sql(self, path: Path, label: str) -> None:
        statements = split_statements(path.read_text(encoding='utf-8-sig'))
        for index, (line, statement) in enumerate(statements):
            body = LEADING_COMMENTS.sub('', statement)
            if not body.rstrip(';').strip():
                continue
            keyword = body.split(None, 1)[0].upper()
            target = re.sub(r'^\w+(\s+OR\s+\w+)?\s+((INTO|FROM)\s+)?', '', body, flags=re.I)
            if not self.has_loc and keyword in ('INSERT', 'UPDATE', 'DELETE', 'REPLACE') and LANGUAGE_TABLE.match(target):
                self.skipped_loc += 1
                continue
            try:
                if keyword in ('CREATE', 'DROP', 'ALTER'):
                    self.conn.execute(body)
                else:
                    self.conn.execute('EXPLAIN ' + body)
            except sqlite3.Error as e:
                message = str(e)
                is_temp = re.match(r'CREATE\s+TEMP(ORARY)?\s', body, re.I) is not None
                if keyword in ('CREATE', 'ALTER') and not is_temp and any(s in message for s in IDEMPOTENT_ERRORS):
                    continue
                remaining = len(statements) - index - 1
                self.report(f'{label}:{line}', f'{message}; the game skips the remaining {remaining} statement(s) in this file')
                first_line = body.splitlines()[0]
                print(f'      {first_line[:120]}')
                return

    def check_xml(self, path: Path, label: str) -> None:
        # The game accepts comments such as <!------ x ------> that strict XML
        # parsers reject, so drop comments before parsing.
        text = XML_COMMENT.sub('', path.read_text(encoding='utf-8-sig'))
        try:
            root = ET.fromstring(text)
        except ET.ParseError as e:
            self.report(label, f'XML parse error: {e}')
            return
        for table in root:
            if not isinstance(table.tag, str):
                continue
            if table.tag == 'Table':
                name = table.get('name')
                columns = [c.get('name') for c in table if c.tag == 'Column' and c.get('name')]
                if name and columns:
                    column_sql = ', '.join(f'"{c}"' for c in columns)
                    self.conn.execute(f'CREATE TABLE IF NOT EXISTS "{name}" ({column_sql})')
                continue
            if not self.has_loc and table.tag.startswith('Language_'):
                self.skipped_loc += 1
                continue
            known = table_columns(self.conn, table.tag)
            if known is None:
                self.report(label, f'no such table: {table.tag}')
                continue
            for op in table:
                if not isinstance(op.tag, str):
                    continue
                if op.tag in ('Row', 'Replace', 'Delete'):
                    parts = [op]
                elif op.tag == 'Update':
                    parts = [p for p in op if p.tag in ('Where', 'Set')]
                else:
                    self.report(label, f'{table.tag}: unknown element <{op.tag}>')
                    continue
                for part in parts:
                    used = list(part.attrib) + [c.tag for c in part if isinstance(c.tag, str)]
                    for column in used:
                        if column.lower() not in known:
                            self.report(label, f'{table.tag}.{column}: no such column (in <{op.tag}>)')


def database_files(arg: str) -> List[Tuple[Path, str]]:
    """Resolve an argument to (file, label) pairs in load order."""
    path = Path(arg)
    if path.is_file() and path.suffix.lower() in ('.sql', '.xml'):
        return [(path, str(path))]
    project = generate_modinfo.resolve_civ5proj_path(path)
    data = generate_modinfo.parse_civ5proj(project)
    mod_dir = project.parent
    files = []
    for actions in data['actions'].values():
        for action in actions:
            if action['type'] == 'UpdateDatabase':
                relative = action['file'].replace('\\', '/')
                files.append((mod_dir / relative, f'{mod_dir.name}/{relative}'))
    return files


def main() -> None:
    parser = argparse.ArgumentParser(description='Check mod SQL/XML database changes against a copy of the game database.')
    parser.add_argument('targets', nargs='+', help='.civ5proj files, component directories or prefixes, or .sql/.xml files')
    parser.add_argument('--db', type=Path, required=True, help='copy of the gameplay database (e.g. cache/Civ5DebugDatabase.db)')
    parser.add_argument('--loc-db', type=Path, default=None,
                        help='copy of the localization database, to also check Language_* changes')
    args = parser.parse_args()

    files = []
    for target in args.targets:
        files.extend(database_files(target))

    with tempfile.TemporaryDirectory() as tmp:
        db_copy = Path(tmp) / 'game.db'
        shutil.copyfile(args.db, db_copy)
        conn = sqlite3.connect(str(db_copy), isolation_level=None)
        if args.loc_db:
            loc_copy = Path(tmp) / 'loc.db'
            shutil.copyfile(args.loc_db, loc_copy)
            conn.execute('ATTACH DATABASE ? AS loc', (str(loc_copy),))
        conn.execute('BEGIN')
        checker = Checker(conn, args.loc_db is not None)
        for path, label in files:
            if not path.exists():
                checker.report(label, 'file listed in the project does not exist')
            elif path.suffix.lower() == '.sql':
                checker.check_sql(path, label)
            elif path.suffix.lower() == '.xml':
                checker.check_xml(path, label)
        conn.execute('ROLLBACK')
        conn.close()

    print(f'Checked {len(files)} file(s): {checker.errors} error(s).')
    if checker.skipped_loc:
        print(f'Skipped {checker.skipped_loc} Language_* change(s); pass --loc-db to check them.')
    sys.exit(1 if checker.errors else 0)


if __name__ == '__main__':
    main()
