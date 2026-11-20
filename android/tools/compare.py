#!/usr/bin/env python3
"""Compare node presence/source/parameter names, not raw group counts or tree equivalence."""
import argparse
from collections import Counter
import json
from pathlib import Path

FIXTURES = {
    "ProbeScreen", "ParameterCard", "DefaultCard", "InlineWrapper",
    "NonRestartableCard", "NoLayoutWrapper", "LazyRowProbe", "DialogContent", "PopupContent",
}


def walk(node, ancestors=()):
    yield node, ancestors
    for child in node.get("children", []):
        yield from walk(child, ancestors + (node,))


def sdk_nodes(document):
    return [pair for window in document["windows"] for table in window["tables"]
            if table.get("tree") for pair in walk(table["tree"]) if pair[0].get("name")]


def inspector_nodes(document):
    return [pair for window in document["windows"] for pair in walk(window["root"])
            if pair[0].get("type") == "ComposeNode"]


def sdk_key(node):
    source = node.get("source", {})
    return node["name"], source.get("file"), source.get("line")


def inspector_key(node):
    source = node.get("sourceLocation", {})
    return node["className"], source.get("fileName"), source.get("lineNumber")


def fixture_rows(pairs, sdk):
    name_key, source_key = ("name", "source") if sdk else ("className", "sourceLocation")
    return [
        {"name": node[name_key], "source": node.get(source_key),
         "parameters": node.get("parameters", []),
         "businessAncestors": [ancestor[name_key] for ancestor in ancestors if ancestor.get(name_key) in FIXTURES]}
        for node, ancestors in pairs if node[name_key] in FIXTURES
    ]


def compare(directory):
    report = {"scope": "Fixture node presence, call sites and parameter names; not full-tree equivalence", "scenarios": {}}
    for scenario in ("main", "dialog", "popup"):
        sdk = json.loads((directory / f"sdk-{scenario}.json").read_text())
        sdk_pairs = sdk_nodes(sdk)
        result = {"sdkStats": sdk["stats"], "sdkDiagnostics": sdk["diagnostics"],
                  "sdkFixtures": fixture_rows(sdk_pairs, True)}
        baseline_file = directory / f"inspector-{scenario}.json"
        if baseline_file.exists():
            baseline = json.loads(baseline_file.read_text())
            baseline_pairs = inspector_nodes(baseline)
            sdk_counts = Counter(sdk_key(n) for n, _ in sdk_pairs)
            baseline_counts = Counter(inspector_key(n) for n, _ in baseline_pairs)
            matched = sdk_counts & baseline_counts
            result.update({
                "inspectorComposeNodes": len(baseline_pairs),
                "matchedInspectorNodes": sum(matched.values()),
                "missingInspectorNodes": [{"key": key, "count": count} for key, count in (baseline_counts - sdk_counts).items()],
                "inspectorFixtures": fixture_rows(baseline_pairs, False),
            })
            sdk_parameters = Counter((sdk_key(n), p["name"]) for n, _ in sdk_pairs for p in n.get("parameters", []))
            inspector_parameters = Counter((inspector_key(n), p["name"]) for n, _ in baseline_pairs for p in n.get("parameters", []))
            result["inspectorParameters"] = sum(inspector_parameters.values())
            result["matchedInspectorParameterNames"] = sum((sdk_parameters & inspector_parameters).values())
            result["missingInspectorParameterNames"] = [
                {"key": key, "count": count} for key, count in (inspector_parameters - sdk_parameters).items()
            ]
        else:
            result["baselineUnavailable"] = f"See inspector-{scenario}.log; no successful JSON capture"
        report["scenarios"][scenario] = result
    return report


def validate_sdk(directory, source):
    """Checks actual payloads against independently known fixture values and source offsets."""
    for scenario in ("main", "dialog", "popup"):
        document = json.loads((directory / f"sdk-{scenario}.json").read_text())
        assert document["complete"] and not document["diagnostics"], document["diagnostics"]
        nodes = [node for node, _ in sdk_nodes(document)]
        required = {"dialog": {"DialogContent"}, "popup": {"PopupContent"}}.get(
            scenario, FIXTURES - {"DialogContent", "PopupContent"})
        captured = {n["name"] for n in nodes} & FIXTURES
        assert len(document["windows"]) == 1 and captured == required, (scenario, captured, required)
        for node in nodes:
            if node["name"] not in FIXTURES:
                continue
            location = node["source"]
            assert location["file"] == "MainActivity.kt"
            assert node["name"] in source.splitlines()[location["line"] - 1]
            # Fixture source is ASCII, so Python offsets and UTF-16 code units coincide.
            assert source[location["offset"]:].startswith(node["name"]), location
        if scenario != "main":
            continue
        card = next(n for n in nodes if n["name"] == "ParameterCard")
        params = {p["name"]: p for p in card["parameters"]}
        for name, value in {"title": "explicit-title", "count": 7, "enabled": True, "spacing": 12}.items():
            assert params[name]["value"]["value"] == value, (name, params[name])
        profile = {p["name"]: p["value"] for p in params["profile"]["value"]["fields"]}
        assert profile["name"]["value"] == "Ada" and profile["age"]["value"] == 37
        assert [p["value"] for p in profile["tags"]["items"]] == ["compose", "debug"]
        assert params["spacing"]["inlineClass"] == "androidx.compose.ui.unit.Dp"
        assert params["tint"]["inlineClass"] == "androidx.compose.ui.graphics.Color"
        defaults = next(n for n in nodes if n["name"] == "DefaultCard")["parameters"]
        assert {p["name"]: p["value"].get("value") for p in defaults} == {"title": "default-title", "count": 23, "nullable": None}
        assert all(p["fromDefault"] for p in defaults)
        rows = [n for n in nodes if n["name"] == "LazyRowProbe"]
        assert 0 < len(rows) < 100, "Only composed lazy items should be present"
        for name in ("InlineWrapper", "NonRestartableCard"):
            assert next(n for n in nodes if n["name"] == name)["parameters"] == [], name
    recomposed = directory / "sdk-recomposed.json"
    if recomposed.exists():
        node = next(n for n, _ in sdk_nodes(json.loads(recomposed.read_text())) if n["name"] == "ParameterCard")
        assert next(p for p in node["parameters"] if p["name"] == "count")["value"]["value"] == 8


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    if args.validate:
        source = Path(__file__).resolve().parents[1] / "sample/src/main/java/dev/composeinspect/sample/MainActivity.kt"
        validate_sdk(args.directory, source.read_text())
    report = compare(args.directory)
    (args.directory / "comparison.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    for scenario, value in report["scenarios"].items():
        print(scenario, {k: v for k, v in value.items() if k not in {"sdkFixtures", "inspectorFixtures"}})


if __name__ == "__main__":
    main()
