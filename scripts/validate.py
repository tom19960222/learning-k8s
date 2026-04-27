#!/usr/bin/env python3
"""
MoLearn Site Validator
======================
Catches the most common failure modes BEFORE they reach production.
Run: python3 scripts/validate.py
     make validate

Exit code 0 = all checks passed
Exit code 1 = one or more checks failed
"""

import sys
import os
import re
import json
import subprocess
import struct
from pathlib import Path

ROOT = Path(__file__).parent.parent
NEXT_SITE = ROOT / "next-site"
CONTENT = NEXT_SITE / "content"
PUBLIC = NEXT_SITE / "public"
DIAGRAMS = PUBLIC / "diagrams"

PASS = "\033[32m✓\033[0m"
FAIL = "\033[31m✗\033[0m"
WARN = "\033[33m⚠\033[0m"
BOLD = "\033[1m"
RESET = "\033[0m"

errors: list[str] = []
warnings: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)
    print(f"  {FAIL} {msg}")


def warn(msg: str) -> None:
    warnings.append(msg)
    print(f"  {WARN} {msg}")


def ok(msg: str) -> None:
    print(f"  {PASS} {msg}")


# ─────────────────────────────────────────────
# CHECK 1: MDX frontmatter
# ─────────────────────────────────────────────
def check_mdx_frontmatter() -> None:
    print(f"\n{BOLD}[1] MDX Frontmatter{RESET}")
    mdx_files = list(CONTENT.rglob("*.mdx"))
    bad = []
    for f in mdx_files:
        text = f.read_text()
        if not text.startswith("---"):
            bad.append((f, "missing frontmatter block"))
            continue
        if "layout: doc" not in text[:300]:
            bad.append((f, "missing 'layout: doc'"))
        if not re.search(r"^title:", text[:300], re.MULTILINE):
            bad.append((f, "missing 'title:'"))

    if bad:
        for f, reason in bad:
            fail(f"{f.relative_to(NEXT_SITE)} — {reason}")
    else:
        ok(f"All {len(mdx_files)} MDX files have correct frontmatter")


# ─────────────────────────────────────────────
# CHECK 2: Broken image references
# ─────────────────────────────────────────────
def get_png_dimensions(path: Path) -> tuple[int, int]:
    """Read PNG width/height from header bytes."""
    try:
        with open(path, "rb") as f:
            f.read(8)  # PNG signature
            f.read(4)  # chunk length
            f.read(4)  # IHDR
            w = struct.unpack(">I", f.read(4))[0]
            h = struct.unpack(">I", f.read(4))[0]
            return w, h
    except Exception:
        return 0, 0


def check_images() -> None:
    print(f"\n{BOLD}[2] Image References{RESET}")
    mdx_files = list(CONTENT.rglob("*.mdx"))
    missing = []
    placeholder = []
    referenced = set()

    for f in mdx_files:
        text = f.read_text()
        for match in re.finditer(r"!\[[^\]]*\]\((/diagrams/[^)]+\.png)\)", text):
            img_path = match.group(1)
            referenced.add(img_path)
            abs_path = PUBLIC / img_path.lstrip("/")
            if not abs_path.exists():
                missing.append((f.relative_to(NEXT_SITE), img_path))
            else:
                w, h = get_png_dimensions(abs_path)
                size = abs_path.stat().st_size
                if w <= 1 and h <= 1:
                    placeholder.append((img_path, f"{w}x{h}"))
                elif size < 3000:
                    placeholder.append((img_path, f"{size}B (suspiciously small)"))

    if missing:
        for src_file, img in missing:
            fail(f"Missing image: {img}  (referenced in {src_file})")
    else:
        ok(f"All referenced images exist ({len(referenced)} unique paths)")

    if placeholder:
        for img, info in placeholder:
            fail(f"Placeholder image detected: {img} [{info}]")
    else:
        ok("No placeholder/empty images found")

    # Warn about orphaned images
    all_pngs = set()
    for png in DIAGRAMS.rglob("*.png"):
        all_pngs.add("/" + str(png.relative_to(PUBLIC)))
    orphans = all_pngs - referenced
    if orphans:
        for img in sorted(orphans):
            warn(f"Orphaned image (unreferenced): {img}")


# ─────────────────────────────────────────────
# CHECK 3: QuizQuestion syntax
# ─────────────────────────────────────────────
def check_quiz_syntax() -> None:
    print(f"\n{BOLD}[3] QuizQuestion Syntax{RESET}")
    mdx_files = list(CONTENT.rglob("*.mdx"))
    issues = []

    for f in mdx_files:
        text = f.read_text()
        for i, line in enumerate(text.splitlines(), 1):
            # :options must use single quotes on outside
            if ":options=" in line and ':options="' in line:
                issues.append((f.relative_to(NEXT_SITE), i, ":options must use single quotes on outside: :options='[...]'"))
            # HTML entities inside :options are forbidden
            if ":options=" in line and ("&quot;" in line or "&apos;" in line):
                issues.append((f.relative_to(NEXT_SITE), i, "HTML entities inside :options are forbidden"))
            # :answer must be a number, not a string
            if re.search(r':answer="[^0-9]', line):
                issues.append((f.relative_to(NEXT_SITE), i, ":answer must be a number (0-indexed), not a string"))
            # /> must be on its own line (simplified check: warn if on same line as other content)
            if "<QuizQuestion" in line and "/>" in line:
                issues.append((f.relative_to(NEXT_SITE), i, "<QuizQuestion .../> should end with /> on its own line"))

    if issues:
        for f, lineno, msg in issues:
            fail(f"{f}:{lineno} — {msg}")
    else:
        ok("All QuizQuestion components have correct syntax")


# ─────────────────────────────────────────────
# CHECK 4: Quiz JSON format
# ─────────────────────────────────────────────
def check_quiz_json() -> None:
    print(f"\n{BOLD}[4] Quiz JSON Files{RESET}")
    quiz_files = list(CONTENT.rglob("quiz.json"))
    issues = []

    for f in quiz_files:
        try:
            data = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            issues.append((f.relative_to(NEXT_SITE), f"Invalid JSON: {e}"))
            continue

        if not isinstance(data, list):
            issues.append((f.relative_to(NEXT_SITE), "Root must be a JSON array"))
            continue

        for item in data:
            q_id = item.get("id", "?")
            q = item.get("question", "")
            # Must have id field
            if "id" not in item:
                issues.append((f.relative_to(NEXT_SITE), f"Question missing 'id' field: {q[:40]}"))
            # Question must not start with a number prefix
            if re.match(r"^\d+[\.\)]\s", q):
                issues.append((f.relative_to(NEXT_SITE), f"id={q_id}: question has number prefix '{q[:20]}...' — remove it, page auto-adds it"))
            # answer must be 0-indexed integer within options range
            answer = item.get("answer")
            options = item.get("options", [])
            if answer is None:
                issues.append((f.relative_to(NEXT_SITE), f"id={q_id}: missing 'answer' field"))
            elif not isinstance(answer, int):
                issues.append((f.relative_to(NEXT_SITE), f"id={q_id}: 'answer' must be integer (0-indexed), got {type(answer).__name__}"))
            elif options and (answer < 0 or answer >= len(options)):
                issues.append((f.relative_to(NEXT_SITE), f"id={q_id}: answer={answer} out of range (options: {len(options)})"))

    if issues:
        for f, msg in issues:
            fail(f"{f} — {msg}")
    elif quiz_files:
        ok(f"All {len(quiz_files)} quiz.json files are valid")
    else:
        warn("No quiz.json files found")


# ─────────────────────────────────────────────
# CHECK 5: Feature files exist
# ─────────────────────────────────────────────
def check_feature_files() -> None:
    print(f"\n{BOLD}[5] Feature Files vs projects.ts{RESET}")
    projects_ts = NEXT_SITE / "lib" / "projects.ts"
    if not projects_ts.exists():
        fail("lib/projects.ts not found")
        return

    ts_text = projects_ts.read_text()
    missing = []

    # Extract project IDs and their features
    # Pattern: id: 'cluster-api', features: ['slug1', 'slug2']
    project_blocks = re.findall(
        r"id:\s*['\"]([^'\"]+)['\"].*?features:\s*\[(.*?)\]",
        ts_text, re.DOTALL
    )

    for project_id, features_str in project_blocks:
        slugs = re.findall(r"['\"]([^'\"]+)['\"]", features_str)
        for slug in slugs:
            mdx_path = CONTENT / project_id / "features" / f"{slug}.mdx"
            if not mdx_path.exists():
                missing.append(f"{project_id}/features/{slug}.mdx")

    if missing:
        for m in missing:
            fail(f"Feature file missing: content/{m}")
    else:
        ok("All features in projects.ts have corresponding MDX files")


# ─────────────────────────────────────────────
# CHECK 6: No VitePress / legacy artifacts
# ─────────────────────────────────────────────
def check_no_vitepress() -> None:
    print(f"\n{BOLD}[6] No VitePress / Legacy Artifacts{RESET}")
    issues = []

    # Check for vitepress references in key files (CLAUDE.md may mention it historically — skip)
    key_files = [
        ROOT / "BOOTSTRAP.md",
        ROOT / "README.md",
        ROOT / "Makefile",
    ]
    for f in key_files:
        if f.exists():
            text = f.read_text()
            if "vitepress" in text.lower():
                issues.append((f.relative_to(ROOT), "contains 'vitepress' reference"))

    # Check docs-site directory doesn't exist
    docs_site = ROOT / "docs-site"
    if docs_site.exists():
        issues.append(("docs-site/", "legacy VitePress directory still exists — run: rm -rf docs-site/"))

    if issues:
        for f, msg in issues:
            warn(f"{f} — {msg}")
    else:
        ok("No VitePress legacy artifacts found")


# ─────────────────────────────────────────────
# CHECK 7: Build
# ─────────────────────────────────────────────
def check_build() -> None:
    print(f"\n{BOLD}[7] Next.js Build{RESET}")
    print("  Running npm run build (this may take ~30s)...")
    result = subprocess.run(
        ["npm", "run", "build"],
        cwd=NEXT_SITE,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        ok("Build passed")
    else:
        # Extract meaningful error lines
        all_output = result.stdout + result.stderr
        error_lines = [l for l in all_output.splitlines()
                       if any(kw in l for kw in ["Error", "error", "failed", "×"])]
        fail(f"Build failed (exit {result.returncode})")
        for line in error_lines[:10]:
            fail(f"  {line.strip()}")


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
def main() -> None:
    print(f"\n{BOLD}{'='*50}")
    print("  MoLearn Site Validator")
    print(f"{'='*50}{RESET}")

    # Fast checks first (no build needed)
    check_mdx_frontmatter()
    check_images()
    check_quiz_syntax()
    check_quiz_json()
    check_feature_files()
    check_no_vitepress()

    # Build runs by default. Use --no-build / -n to skip (e.g. in quick iteration loops)
    if "--no-build" in sys.argv or "-n" in sys.argv:
        print(f"\n  {WARN}  Skipping build check (--no-build flag passed)")
    else:
        check_build()

    # Summary
    print(f"\n{BOLD}{'='*50}")
    print("  Summary")
    print(f"{'='*50}{RESET}")

    if errors:
        print(f"\n  {FAIL} {BOLD}{len(errors)} error(s){RESET}")
        for e in errors:
            print(f"    • {e}")
    if warnings:
        print(f"\n  {WARN} {len(warnings)} warning(s)")
        for w in warnings:
            print(f"    • {w}")

    if not errors:
        print(f"\n  {PASS} {BOLD}All checks passed!{RESET}\n")
        sys.exit(0)
    else:
        print(f"\n  {FAIL} {BOLD}Fix errors above before committing.{RESET}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
