"""Build a fully resolved sticker + beequip pricebook from bssm_values.json."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "bssm_values.json"
OUT = ROOT / "pricebook.json"


def flat(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def parse_amount(raw: str, stick: dict[str, float]) -> tuple[float | None, bool]:
    if raw is None:
        return None, False
    s = str(raw).strip()
    if not s or s.upper() == "TBD":
        return None, False
    open_ = ">" in s
    expr = re.sub(r"^>=?\s*", "", s)
    expr = re.sub(r"^=\s*", "", expr)
    try:
        return float(expr), open_
    except ValueError:
        pass

    ok = True

    def repl(m: re.Match[str]) -> str:
        nonlocal ok
        name = m.group(1)
        v = stick.get(name.lower()) or stick.get(flat(name))
        if v is None:
            ok = False
            return "0"
        return str(v)

    expr2 = re.sub(r"\{([^}]+)\}", repl, expr)
    expr2 = re.sub(r"\s+", "", expr2)
    if not ok or not re.match(r"^[\d.+\-*]+$", expr2):
        return None, True
    try:
        return float(eval(expr2, {"__builtins__": {}})), True
    except Exception:
        return None, True


def main() -> None:
    data = json.loads(SRC.read_text(encoding="utf-8"))
    stick: dict[str, float] = {}
    stick_rows: list[dict] = []
    pending: list[tuple[str, dict, str]] = []

    for gname, group in (data.get("Sticker") or {}).get("groups", {}).items():
        if str(gname).lower() == "services":
            continue
        items = group.get("items") if isinstance(group, dict) else None
        if not isinstance(items, dict):
            continue
        for name, rec in items.items():
            if not isinstance(rec, dict):
                continue
            vmin = str(rec.get("value_min") or "")
            vmax = str(rec.get("value_max") or "")
            if "{" in vmin:
                pending.append((name, rec, str(gname)))
                continue
            a, open_a = parse_amount(vmin, stick)
            if a is None:
                continue
            b, _ = parse_amount(vmax, stick)
            row = {
                "name": name,
                "group": str(gname),
                "min": a,
                "max": a if open_a or b is None else b,
                "open": open_a,
                "acronyms": rec.get("acronyms"),
            }
            stick_rows.append(row)
            stick[name.lower()] = a
            stick[flat(name)] = a
            ac = rec.get("acronyms")
            if isinstance(ac, str) and ac.strip():
                stick[ac.lower()] = a
                stick[flat(ac)] = a
            elif isinstance(ac, list):
                for x in ac:
                    if isinstance(x, str) and x.strip():
                        stick[x.lower()] = a
                        stick[flat(x)] = a

    for _ in range(5):
        left = []
        for name, rec, gname in pending:
            a, open_a = parse_amount(str(rec.get("value_min") or ""), stick)
            if a is None:
                left.append((name, rec, gname))
                continue
            b, _ = parse_amount(str(rec.get("value_max") or ""), stick)
            row = {
                "name": name,
                "group": gname,
                "min": a,
                "max": a if open_a or b is None else b,
                "open": open_a,
                "acronyms": rec.get("acronyms"),
            }
            stick_rows.append(row)
            stick[name.lower()] = a
            stick[flat(name)] = a
        pending = left

    beequip: dict[str, list[dict]] = {}
    cards_ok = cards_fail = 0
    for name, rec in (data.get("Beequip") or {}).items():
        if not isinstance(rec, dict):
            continue
        cards = []
        for gname, variants in (rec.get("stat_groups") or {}).items():
            if not isinstance(variants, dict):
                continue
            for label, row in variants.items():
                if not isinstance(row, dict):
                    continue
                a, open_a = parse_amount(str(row.get("value_min") or ""), stick)
                b, open_b = parse_amount(str(row.get("value_max") or ""), stick)
                if a is None:
                    cards_fail += 1
                    continue
                cards_ok += 1
                cards.append(
                    {
                        "label": str(label),
                        "group": str(gname),
                        "min": a,
                        "max": None if (open_a or open_b or b is None) else b,
                        "open": bool(open_a or open_b or b is None),
                        "demand": row.get("demand"),
                    }
                )
        beequip[name] = cards

    book = {
        "source": "bssmvalues.com/api/values",
        "stickers": sorted(stick_rows, key=lambda r: r["name"].lower()),
        "beequips": beequip,
        "stats": {
            "stickers": len(stick_rows),
            "beequip_items": len(beequip),
            "beequip_cards_ok": cards_ok,
            "beequip_cards_unpriced": cards_fail,
            "pending_stickers": [n for n, _, _ in pending],
        },
    }
    OUT.write_text(json.dumps(book, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(book["stats"], ensure_ascii=False))
    print("wrote", OUT, "bytes", OUT.stat().st_size)


if __name__ == "__main__":
    main()
