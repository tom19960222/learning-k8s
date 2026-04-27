#!/usr/bin/env python3
"""Convert VitePress .md files to Next.js .mdx files."""
import os, re, sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
DOCS_ROOT = REPO_ROOT / "docs-site"
CONTENT_OUT = Path(__file__).parent.parent / "content"

PROJECTS = {
    "cluster-api": "cluster-api",
    "cluster-api-provider-maas": "cluster-api-provider-maas",
    "cluster-api-provider-metal3": "cluster-api-provider-metal3",
}

SLUG_MAP = {
    "cluster-api": {
        "architecture": "architecture",
        "controller-core": "controller-core",
        "controller-kcp": "controller-kcp",
        "controller-topology": "controller-topology",
        "api-cluster-machine": "api-cluster-machine",
        "api-machineset-machinedeployment": "api-machineset-machinedeployment",
        "api-kubeadm-controlplane": "api-kubeadm-controlplane",
        "bootstrap-kubeadmconfig": "bootstrap-kubeadmconfig",
        "machine-lifecycle": "machine-lifecycle",
        "machine-health-check": "machine-health-check",
        "clusterclass-topology": "clusterclass-topology",
        "addons-clusterresourceset": "addons-clusterresourceset",
        "provider-contracts-runtime-hooks": "provider-contracts-runtime-hooks",
        "clusterctl": "clusterctl",
    },
    "cluster-api-provider-maas": {
        "architecture": "architecture",
        "controllers": "controllers",
        "machine-lifecycle": "machine-lifecycle",
        "api-types": "api-types",
        "integration": "integration",
    },
    "cluster-api-provider-metal3": {
        "architecture": "architecture",
        "bmh-lifecycle": "bmh-lifecycle",
        "crds-cluster": "crds-cluster",
        "crds-machine": "crds-machine",
        "labelsync": "labelsync",
        "node-reuse": "node-reuse",
        "data-templates": "data-templates",
        "ipam": "ipam",
        "remediation": "remediation",
        "advanced-features": "advanced-features",
    },
}


def escape_braces(text: str) -> str:
    """Escape { and } outside code blocks and JSX components."""
    lines = text.split('\n')
    result = []
    in_code_block = False
    in_jsx = False

    for line in lines:
        # track fenced code blocks
        if re.match(r'^```', line):
            in_code_block = not in_code_block

        if in_code_block:
            result.append(line)
            continue

        # Don't escape lines that are JSX component lines
        stripped = line.strip()
        if stripped.startswith('<') and not stripped.startswith('</'):
            result.append(line)
            continue
        if stripped.startswith('/>') or stripped == '>':
            result.append(line)
            continue

        # Escape raw braces in prose
        new_line = re.sub(r'\{(?![^}]*\})', '&#123;', line)
        new_line = re.sub(r'(?<!&#123[^}]{0,10})\}', '&#125;', new_line)
        # Actually simpler: just escape all { } that aren't in JSX attr context
        result.append(line)  # skip escaping for now — only escape if build fails

    return '\n'.join(result)


def convert_callouts(text: str) -> str:
    """Convert ::: type [title]\n...\n::: to <Callout type="type">...</Callout>"""
    def replace_callout(m):
        ctype = m.group(1).lower()
        title = m.group(2).strip() if m.group(2) else ''
        body = m.group(3).strip()
        title_attr = f' title="{title}"' if title else ''
        return f'\n<Callout type="{ctype}"{title_attr}>\n\n{body}\n\n</Callout>\n'

    # Handle :::type title\n...\n:::
    text = re.sub(
        r':::[ \t]*(info|warning|tip|danger|details)([^\n]*)?\n(.*?):::',
        replace_callout,
        text,
        flags=re.DOTALL
    )
    return text


def remove_script_setup(text: str) -> str:
    return re.sub(r'<script\s+setup[^>]*>.*?</script>', '', text, flags=re.DOTALL)


def remove_quiz_questions(text: str) -> str:
    return re.sub(r'<QuizQuestion[^/]*/>', '', text, flags=re.DOTALL)


def convert_file(src_path: Path, out_path: Path):
    content = src_path.read_text(encoding='utf-8')

    # Remove script setup blocks
    content = remove_script_setup(content)

    # Remove QuizQuestion components (they go to quiz.json)
    content = remove_quiz_questions(content)

    # Convert ::: callouts to <Callout>
    content = convert_callouts(content)

    # Clean up multiple blank lines
    content = re.sub(r'\n{4,}', '\n\n\n', content)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(content.strip() + '\n', encoding='utf-8')
    print(f"  ✓ {src_path.name} → {out_path}")


def find_md_files(project_dir: Path) -> list[Path]:
    """Find all .md files excluding quiz.md and index.md"""
    files = []
    for md in sorted(project_dir.rglob('*.md')):
        if md.name in ('quiz.md', 'index.md'):
            continue
        files.append(md)
    return files


def get_slug_from_path(md_path: Path, project_docs_dir: Path) -> str:
    rel = md_path.relative_to(project_docs_dir)
    # e.g. architecture.md → architecture
    # or subdir/file.md → subdir-file
    parts = list(rel.parts)
    slug = '-'.join(p.replace('.md', '') for p in parts)
    return slug


def main():
    for project_id, project_dir_name in PROJECTS.items():
        project_docs_dir = DOCS_ROOT / project_dir_name
        if not project_docs_dir.exists():
            print(f"[WARN] {project_docs_dir} not found, skipping")
            continue

        out_dir = CONTENT_OUT / project_id / "features"
        out_dir.mkdir(parents=True, exist_ok=True)

        print(f"\n📦 {project_id}")
        md_files = find_md_files(project_docs_dir)

        for md_path in md_files:
            slug = get_slug_from_path(md_path, project_docs_dir)
            out_path = out_dir / f"{slug}.mdx"
            try:
                convert_file(md_path, out_path)
            except Exception as e:
                print(f"  ✗ {md_path.name}: {e}")

    print("\n✅ Done")


if __name__ == '__main__':
    main()
