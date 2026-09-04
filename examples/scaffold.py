#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Set up the repo and scaffold new pipelines / steps.

Commands:
    new-pipeline <name>                 Copy the my-pipeline template and rename it
    new-step <pipeline> <step> <type>   Scaffold a new batch|lambda step
    reconcile <pipeline> [--prune]      Sync code/ with pipeline.yaml (source of truth)

Run from the repository root. Examples:
    ./scaffold.py new-pipeline my-new-pipeline
    ./scaffold.py new-step my-new-pipeline ingest_raw_data batch
    ./scaffold.py reconcile my-new-pipeline

Pre-commit hooks are installed directly with `pre-commit install` and
`pre-commit install --hook-type commit-msg` — see examples/README.md Step 1.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

# --- Configuration --------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parent
TEMPLATE_PIPELINE = "my-pipeline"
TEMPLATE_STEP = {
    # type -> template step directory (relative to repo root)
    "batch": "my-pipeline/code/simple_step",  # has a Dockerfile
    "lambda": "my-pipeline/code/process_item",  # no Dockerfile (zip-deployed)
}
# Directories under <pipeline>/code/ that are not steps and must never be pruned.
NON_STEP_DIRS = {"test-data"}

# Pipeline names become S3 bucket prefixes (S3 bucket naming rules).
PIPELINE_NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
# Step names map to ECR repos / Step Functions states / Python step dirs:
# lowercase letters, digits and underscores only — no hyphens.
STEP_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_]*$")


# --- Console helpers ------------------------------------------------------
def info(msg: str) -> None:
    print(f"\033[1;34m==>\033[0m {msg}")


def ok(msg: str) -> None:
    print(f"\033[1;32m  \u2713\033[0m {msg}")


def warn(msg: str) -> None:
    print(f"\033[1;33m  !\033[0m {msg}")


def die(msg: str) -> "None":
    print(f"\033[1;31mERROR:\033[0m {msg}", file=sys.stderr)
    raise SystemExit(1)


# --- Validation -----------------------------------------------------------
def validate_pipeline_name(name: str) -> None:
    if not PIPELINE_NAME_RE.match(name):
        die(
            f"Invalid pipeline name '{name}'. Use lowercase letters, digits, "
            "and hyphens only (S3-safe), e.g. my-new-pipeline."
        )


def validate_step_name(name: str) -> None:
    if not STEP_NAME_RE.match(name):
        die(
            f"Invalid step name '{name}'. Use lowercase letters, digits and "
            "underscores only (no hyphens), starting with a letter or digit."
        )


def safe_path(*parts: str) -> Path:
    """Resolve a path under REPO_ROOT, refusing anything that escapes it.

    Defense-in-depth path-traversal guard: even though pipeline and step names
    are validated against strict allowlists, every filesystem path derived from
    user input is also confirmed to stay inside the repository before use.
    """
    candidate = REPO_ROOT.joinpath(*parts).resolve()
    if candidate != REPO_ROOT and REPO_ROOT not in candidate.parents:
        die(f"Refusing to operate outside the repository: {candidate}")
    return candidate


# --- pipeline.yaml parsing ------------------------------------------------
def parse_compute_steps(yaml_file: Path) -> list[tuple[str, str]]:
    """Return [(type, name), ...] for every batch/lambda step in the YAML.

    Descends into a parallel block's `parallel_steps`. pipeline.yaml is the
    source of truth; parallel steps have no code of their own.
    """
    try:
        import yaml
    except ModuleNotFoundError:
        die(
            "PyYAML is required to parse pipeline.yaml: pip install pyyaml==6.0.3"
        )

    with yaml_file.open(encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}

    steps: list[tuple[str, str]] = []

    def visit(step: object) -> None:
        if not isinstance(step, dict):
            return
        step_type, name = step.get("type"), step.get("name")
        if step_type in ("batch", "lambda") and name:
            steps.append((step_type, name))
        if step_type == "parallel":
            for inner in step.get("parallel_steps") or []:
                visit(inner)

    for step in doc.get("steps") or []:
        visit(step)
    return steps


# --- Core step scaffolding ------------------------------------------------
def create_step(pipeline: str, step: str, step_type: str) -> bool:
    """Copy the template for `step_type` into <pipeline>/code/<step>.

    Returns True if created, False if the target already exists.
    """
    template_rel = TEMPLATE_STEP.get(step_type)
    if template_rel is None:
        die(
            f"Unknown step type '{step_type}' for step '{step}'. "
            "Use 'batch' or 'lambda'."
        )
    template = REPO_ROOT / template_rel
    if not template.is_dir():
        die(f"Template step '{template_rel}/' not found.")

    target = safe_path(pipeline, "code", step)
    if target.exists():
        return False

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(template, target)
    (target / "tests").mkdir(exist_ok=True)
    # A lambda step must not ship a Dockerfile (it is zip-deployed).
    if step_type == "lambda":
        dockerfile = target / "Dockerfile"
        if dockerfile.exists():
            dockerfile.unlink()
    return True


def step_yaml_snippet(step: str, step_type: str) -> str:
    if step_type == "batch":
        return (
            f"       - name: {step}\n"
            "         type: batch\n"
            "         ram_mb: 2048\n"
            "         vcpu: 1\n"
            "         image_tag: latest\n"
            "         copy_to_target: false"
        )
    return (
        f"       - name: {step}\n"
        "         type: lambda\n"
        "         lambda_timeout: 60\n"
        "         lambda_memory_size: 512"
    )


def print_step_next_steps(pipeline: str, step: str, step_type: str) -> None:
    target = f"{pipeline}/code/{step}"
    extra = " / Dockerfile" if step_type == "batch" else ""
    print()
    print(
        f"Next:\n  1. Declare the step in {pipeline}/pipeline.yaml under 'steps:', e.g.:"
    )
    print(step_yaml_snippet(step, step_type))
    print(f"  2. Edit {target}/main.py (and pyproject.toml{extra}).")
    print(f"  3. Test it:  make unit-tests DIR={pipeline}/code/{step}")


# --- Commands -------------------------------------------------------------
def cmd_new_pipeline(args: argparse.Namespace) -> None:
    name = args.name
    validate_pipeline_name(name)

    template = REPO_ROOT / TEMPLATE_PIPELINE
    if not template.is_dir():
        die(
            f"Template '{TEMPLATE_PIPELINE}/' not found. Run from the repository root."
        )
    target = safe_path(name)
    if target.exists():
        die(
            f"'{name}' already exists — choose a different name or remove it first."
        )

    info(f"Copying {TEMPLATE_PIPELINE}/ -> {name}/")
    shutil.copytree(template, target)

    info(f"Renaming pipeline to '{name}'")
    # pipeline.yaml: pipeline_name must match the directory name (preserve comments).
    pipeline_yaml = target / "pipeline.yaml"
    text = pipeline_yaml.read_text(encoding="utf-8")
    text = re.sub(r"(?m)^pipeline_name:.*$", f"pipeline_name: {name}", text)
    pipeline_yaml.write_text(text, encoding="utf-8")

    # backend.tfvars: per-environment OpenTofu state key.
    for tfvars in (target / "env").rglob("backend.tfvars"):
        content = tfvars.read_text(encoding="utf-8")
        content = re.sub(
            r"tf-[A-Za-z0-9._-]*\.tfstate", f"tf-{name}.tfstate", content
        )
        tfvars.write_text(content, encoding="utf-8")
        ok(f"Updated state key in {tfvars.relative_to(REPO_ROOT)}")

    ok(f"Created pipeline '{name}'.")

    # Ask the user to define the steps, then scaffold the code from the YAML.
    print()
    info(f"Define your steps in {name}/pipeline.yaml now.")
    print(
        "  Each entry under 'steps:' is one of: batch, lambda, parallel.\n"
        "  Every batch/lambda step (including those nested in a parallel block)\n"
        "  needs a code/<step> directory — 'reconcile' creates them from the YAML."
    )
    if sys.stdin.isatty():
        input(
            "\nPress Enter once the steps are defined to scaffold their code "
            "(Ctrl-C to skip)... "
        )
        reconcile(name, prune=False)
    else:
        print(
            f"\nWhen the steps are defined, scaffold/sync the code with:\n  {_prog()} reconcile {name}"
        )


def cmd_new_step(args: argparse.Namespace) -> None:
    pipeline, step, step_type = args.pipeline, args.step, args.type
    validate_pipeline_name(pipeline)
    validate_step_name(step)
    if not safe_path(pipeline).is_dir():
        die(
            f"Pipeline '{pipeline}/' not found. Create it first: "
            f"{_prog()} new-pipeline {pipeline}"
        )

    target = safe_path(pipeline, "code", step)
    if target.exists():
        die(
            f"'{pipeline}/code/{step}' already exists — choose a different step name."
        )

    info(f"Creating {step_type} step '{step}' in {pipeline}")
    create_step(pipeline, step, step_type)
    ok(f"Created step '{step}' ({step_type}) at {pipeline}/code/{step}/")
    print_step_next_steps(pipeline, step, step_type)


def cmd_reconcile(args: argparse.Namespace) -> None:
    reconcile(args.pipeline, prune=args.prune)


def _confirm_delete(question: str) -> bool:
    """Prompt until the user answers strictly ``y`` or ``N`` (case-insensitive).

    Returns ``True`` only for yes. Any other input — including an empty line,
    ``yes``/``no``, or stray text — is rejected and re-prompted. EOF or a
    keyboard interrupt is treated as ``N`` (safe default: keep the directory).
    """
    while True:
        try:
            reply = input(f"{question} [y/N] ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return False
        if reply in ("y", "Y"):
            return True
        if reply in ("n", "N"):
            return False
        warn("Please answer 'y' or 'N'.")


def reconcile(pipeline: str, *, prune: bool) -> None:
    """Sync <pipeline>/code/ with pipeline.yaml (the source of truth)."""
    validate_pipeline_name(pipeline)
    pipeline_dir = safe_path(pipeline)
    if not pipeline_dir.is_dir():
        die(f"Pipeline '{pipeline}/' not found.")
    yaml_file = pipeline_dir / "pipeline.yaml"
    if not yaml_file.is_file():
        die(f"'{pipeline}/pipeline.yaml' not found.")

    info(f"Reconciling {pipeline}/code/ against {pipeline}/pipeline.yaml")

    expected: set[str] = set()
    created = present = 0
    for step_type, name in parse_compute_steps(yaml_file):
        validate_step_name(name)
        expected.add(name)
        if create_step(pipeline, name, step_type):
            ok(f"Created {step_type} step '{name}' -> {pipeline}/code/{name}/")
            created += 1
        else:
            present += 1

    # Orphans: code dirs not referenced by any compute step in the YAML.
    code_dir = pipeline_dir / "code"
    orphans = []
    if code_dir.is_dir():
        for child in sorted(code_dir.iterdir()):
            # Never follow symlinks (avoids deleting through a link on --prune).
            if child.is_symlink():
                warn(f"Skipping symlink {pipeline}/code/{child.name}")
                continue
            if not child.is_dir():
                continue
            if child.name in NON_STEP_DIRS or child.name in expected:
                continue
            orphans.append(child.name)

    print()
    info(f"Summary: {created} created, {present} already present.")
    if not orphans:
        ok("No orphan code directories.")
        return

    warn(
        "Orphan code directories (no matching batch/lambda step in pipeline.yaml):"
    )
    for name in orphans:
        print(f"      - {pipeline}/code/{name}")

    if not prune:
        print(
            "  These exist on disk but are not in pipeline.yaml. Re-run with "
            f"--prune to remove them:\n    {_prog()} reconcile {pipeline} --prune"
        )
        return

    # --prune: delete each orphan after explicit confirmation (destructive).
    interactive = sys.stdin.isatty()
    for name in orphans:
        path = safe_path(pipeline, "code", name)
        if path.is_symlink():  # belt-and-suspenders: never rmtree a link
            warn(f"Skipping symlink {pipeline}/code/{name}")
            continue
        if not interactive:
            warn(
                f"Refusing to prune '{pipeline}/code/{name}' without an "
                "interactive confirmation."
            )
            continue
        if _confirm_delete(f"Delete {pipeline}/code/{name} ?"):
            shutil.rmtree(path)
            ok(f"Removed {pipeline}/code/{name}")
        else:
            warn(f"Kept {pipeline}/code/{name}")


def _prog() -> str:
    return f"./{Path(sys.argv[0]).name}"


# --- CLI ------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Set up the repo and scaffold new pipelines/steps.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_new = sub.add_parser(
        "new-pipeline",
        help="Copy & rename the my-pipeline template, then scaffold steps",
    )
    p_new.add_argument(
        "name", help="New pipeline name (S3-safe: lowercase, digits, hyphens)"
    )
    p_new.set_defaults(func=cmd_new_pipeline)

    p_step = sub.add_parser("new-step", help="Scaffold a single compute step")
    p_step.add_argument("pipeline", help="Existing pipeline directory")
    p_step.add_argument("step", help="New step name")
    p_step.add_argument("type", choices=("batch", "lambda"), help="Step type")
    p_step.set_defaults(func=cmd_new_step)

    p_rec = sub.add_parser(
        "reconcile",
        help="Sync code/ with pipeline.yaml (the source of truth)",
    )
    p_rec.add_argument("pipeline", help="Pipeline directory to reconcile")
    p_rec.add_argument(
        "--prune",
        action="store_true",
        help="Remove orphan code dirs not in pipeline.yaml (asks for confirmation)",
    )
    p_rec.set_defaults(func=cmd_reconcile)

    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
