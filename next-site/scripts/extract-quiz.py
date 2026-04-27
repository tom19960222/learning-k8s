#!/usr/bin/env python3
"""Extract QuizQuestion components from VitePress quiz.md → quiz.json"""
import os, re, json
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent
DOCS_ROOT = REPO_ROOT / "docs-site"
CONTENT_OUT = Path(__file__).parent.parent / "content"

PROJECTS = [
    "cluster-api",
    "cluster-api-provider-maas",
    "cluster-api-provider-metal3",
]


def parse_quiz_questions(quiz_md: str) -> list[dict]:
    """Parse <QuizQuestion ... /> components from markdown."""
    questions = []
    q_id = 1

    # Match each <QuizQuestion ... />
    pattern = re.compile(r'<QuizQuestion\s+(.*?)/>', re.DOTALL)

    for match in pattern.finditer(quiz_md):
        attrs_raw = match.group(1)

        # Extract question=""
        q_match = re.search(r'question="((?:[^"\\]|\\.)*)"', attrs_raw)
        question = q_match.group(1) if q_match else ''
        # Unescape HTML entities
        question = question.replace('&quot;', '"').replace('&#39;', "'").replace('&amp;', '&')

        # Extract :options='[...]' — single-quoted outer, double-quoted inner
        opts_match = re.search(r":options='(\[.*?\])'", attrs_raw, re.DOTALL)
        options = []
        if opts_match:
            opts_raw = opts_match.group(1)
            # Extract strings from JSON-like array (double-quoted)
            options = re.findall(r'"((?:[^"\\]|\\.)*)"', opts_raw)

        # Extract :answer="N"
        ans_match = re.search(r':answer="(\d+)"', attrs_raw)
        answer = int(ans_match.group(1)) if ans_match else 0

        # Extract explanation=""
        exp_match = re.search(r'explanation="((?:[^"\\]|\\.)*)"', attrs_raw)
        explanation = exp_match.group(1) if exp_match else ''
        explanation = explanation.replace('&quot;', '"').replace('&#39;', "'").replace('&amp;', '&')

        if question and options:
            questions.append({
                "id": q_id,
                "question": question,
                "options": options,
                "answer": answer,
                "explanation": explanation,
            })
            q_id += 1

    return questions


def main():
    for project in PROJECTS:
        quiz_path = DOCS_ROOT / project / "quiz.md"
        if not quiz_path.exists():
            print(f"[WARN] {quiz_path} not found, skipping")
            continue

        content = quiz_path.read_text(encoding='utf-8')
        questions = parse_quiz_questions(content)

        out_path = CONTENT_OUT / project / "quiz.json"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(questions, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

        print(f"✓ {project}: {len(questions)} questions → {out_path}")

    print("\n✅ Done")


if __name__ == '__main__':
    main()
