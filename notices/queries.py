"""Appends the highlight queries' section to THIRD-PARTY-NOTICES.txt.

Usage: python3 -I notices/queries.py <packages/cli-rs> <THIRD-PARTY-NOTICES.txt>

The client compiles assets/queries/<filetype>/*.scm into the binary; its generator records each filetype's sources in
assets/queries/manifest.json. Every source is matched against notices/queries.tsv, and the section lists each query
file with its sources and their licences, then each licence text once. It fails, and writes nothing, when a query
file has no manifest entry or a source matches no row: no shipped query goes without a recorded licence.
"""

import fnmatch
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
package, notices = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
queries = package / "assets" / "queries"

rows = []
for line in (here / "queries.tsv").read_text().splitlines():
    if line and not line.startswith("#"):
        pattern, project, repository, spdx, text = line.split("\t")
        rows.append({"pattern": pattern, "project": project, "repository": repository, "spdx": spdx, "text": text})

manifest = {entry["filetype"]: entry["sources"] for entry in json.loads((queries / "manifest.json").read_text())}
files = sorted(path.relative_to(queries).as_posix() for path in queries.glob("*/*.scm"))
errors, listing, used = [], [], {}
for file in files:
    filetype = file.split("/")[0]
    if filetype not in manifest:
        errors.append(f"{file}: no entry in manifest.json")
        continue
    listing.append(f"  {file}")
    for source in manifest[filetype]:
        matched = [row for row in rows if fnmatch.fnmatchcase(source, row["pattern"])]
        if not matched:
            errors.append(f"{file}: no row in notices/queries.tsv for {source}")
        listing.append(f"    from {source}")
        for row in matched:
            listing.append(f"      {row['project']} ({row['spdx']}) {row['repository']}")
            used[row["project"]] = row
if errors:
    sys.exit("queries.py:\n" + "\n".join(errors))

section = [
    "",
    "=" * 80,
    "Highlight queries",
    "",
    "opencode-native compiles these tree-sitter highlight queries into the binary. Each is listed with the sources it",
    "was copied from and their licences; the licence texts follow.",
    "",
    *listing,
]
for project, row in sorted(used.items()):
    section += ["", "-" * 80, f"{project} ({row['spdx']}) {row['repository']}", "", (here / "licenses" / row["text"]).read_text().rstrip()]
with notices.open("a") as out:
    out.write("\n".join(section) + "\n")
print(f"queries.py: {len(files)} query files, {len(used)} licences")
