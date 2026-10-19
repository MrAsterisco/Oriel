"""Prepare public, explicitly labelled photos for the opt-in local People validation test.

Usage: python3 scripts/prepare_people_validation.py /path/to/a/new/empty/directory
Downloads development fixtures only; neither photos nor labels are bundled with Oriel.
"""

import concurrent.futures
import csv
import io
import json
from pathlib import Path, PurePosixPath
import sys
from urllib.request import urlopen


REVISION = "7cc7afcd469645b70881a56d3d96d88902d24212"
REPOSITORY = "https://raw.githubusercontent.com/serengil/deepface/" + REVISION + "/"


def download(url):
    with urlopen(url, timeout=30) as response:
        return response.read()


def prepare(destination):
    tree = json.loads(download(
        "https://api.github.com/repos/serengil/deepface/git/trees/" + REVISION + "?recursive=1"
    ))
    available = {entry["path"] for entry in tree["tree"] if entry["type"] == "blob"}
    pairs = []
    for filename, decision_column in [("master.csv", "Decision"), ("face-recognition-pivot.csv", "decision")]:
        data = download(REPOSITORY + "tests/unit/dataset/" + filename).decode("utf-8-sig")
        for row in csv.DictReader(io.StringIO(data)):
            first = PurePosixPath(row["file_x"]).name
            second = PurePosixPath(row["file_y"]).name
            decision = row[decision_column]
            if decision not in ("Yes", "No"):
                raise ValueError("Unexpected verification label")
            if all("tests/unit/dataset/" + name in available for name in (first, second)):
                pairs.append({"first": first, "second": second, "same": decision == "Yes"})

    parents = {name: name for pair in pairs for name in (pair["first"], pair["second"])}

    def identity(name):
        while parents[name] != name:
            name = parents[name]
        return name

    for pair in pairs:
        if pair["same"]:
            roots = sorted([identity(pair["first"]), identity(pair["second"])])
            parents[roots[1]] = roots[0]
    for pair in pairs:
        if (identity(pair["first"]) == identity(pair["second"])) != pair["same"]:
            raise ValueError("Public identity labels contradict each other")
    samples = [{"relativePath": name, "identity": identity(name)} for name in sorted(parents)]
    identities = len({sample["identity"] for sample in samples})
    if len(samples) != 61 or identities != 13:
        raise ValueError("Pinned corpus did not contain the expected 61 photos and 13 identities")

    destination.mkdir(parents=True, exist_ok=False)

    def save(sample):
        name = sample["relativePath"]
        (destination / name).write_bytes(download(REPOSITORY + "tests/unit/dataset/" + name))

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        list(executor.map(save, samples))
    (destination / "manifest.json").write_text(json.dumps(
        {"sourceCommit": REVISION, "samples": samples, "pairs": pairs}, indent=2
    ) + "\n")
    print(f"Prepared {len(samples)} public photos / {identities} labelled identities in {destination}")


if __name__ == "__main__":
    prepare(Path(sys.argv[1]).expanduser().resolve())
