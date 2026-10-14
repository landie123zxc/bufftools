"""Lookup sticker / beequip prices from pricebook.json (for chat + local use)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

BOOK = Path(__file__).resolve().parent / "pricebook.json"


def flat(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def load():
    data = json.loads(BOOK.read_text(encoding="utf-8"))
    stick = {}
    for row in data["stickers"]:
        stick[row["name"].lower()] = row
        stick[flat(row["name"])] = row
        ac = row.get("acronyms")
        if isinstance(ac, str) and ac.strip():
            stick[ac.lower()] = row
            stick[flat(ac)] = row
    return data, stick


def fmt(row: dict) -> str:
    if row.get("open") or row.get("max") is None:
        return f">={row['min']:g}"
    if abs(row["min"] - row["max"]) < 0.01:
        return f"{row['min']:g}"
    return f"{row['min']:g}-{row['max']:g}"


def main(argv: list[str]) -> None:
    if not BOOK.is_file():
        print("Run build_pricebook.py first")
        sys.exit(1)
    data, stick = load()
    q = " ".join(argv[1:]).strip()
    if not q:
        print(json.dumps(data["stats"], ensure_ascii=False, indent=2))
        return
    # sticker
    hit = stick.get(q.lower()) or stick.get(flat(q))
    if hit:
        print(f"STICKER {hit['name']}: {fmt(hit)} ({hit.get('group')})")
        return
    # beequip by name
    bq = data["beequips"]
    key = None
    for name in bq:
        if name.lower() == q.lower() or flat(name) == flat(q):
            key = name
            break
    if not key:
        # substring
        matches = [n for n in bq if flat(q) in flat(n) or flat(n) in flat(q)]
        if len(matches) == 1:
            key = matches[0]
        elif matches:
            print("matches:", ", ".join(matches[:20]))
            return
    if not key:
        print("not found:", q)
        return
    cards = bq[key]
    print(f"BEEQUIP {key} ({len(cards)} cards)")
    for c in sorted(cards, key=lambda x: x["min"], reverse=True)[:25]:
        rng = fmt(c)
        print(f"  {rng:>12}  {c['label']}")


if __name__ == "__main__":
    main(sys.argv)
