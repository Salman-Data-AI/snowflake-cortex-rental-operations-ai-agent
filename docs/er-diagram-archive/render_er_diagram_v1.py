"""ARCHIVED v1 — Gold star schema ER diagram (structured data only: FleetOps + BookWave).

Superseded by ../render_er_diagram.py (v2). Kept to reproduce gold_star_schema_er_v1.png:
    python3 render_er_diagram_v1.py
"""
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle

OUT = Path(__file__).with_name("gold_star_schema_er_v1.png")

ROW_H = 0.34
HEAD_H = 0.55
BOX_W = 4.6

STYLE = {
    "fact":   {"head": "#E8445A", "edge": "#E8445A"},
    "dim":    {"head": "#1F2A44", "edge": "#1F2A44"},
    "bridge": {"head": "#2E8B6E", "edge": "#2E8B6E"},
}

# name: (kind, x, top_y, [(column, type, key)])
TABLES = {
    "DIM_CURRENCIES": ("dim", 0.3, 17.6, [
        ("currency_code", "TEXT", "PK"), ("currency_name", "TEXT", ""), ("symbol", "TEXT", ""),
        ("usd_exchange_rate", "NUMBER(18,6)", ""), ("decimal_places", "NUMBER", "")]),
    "DIM_COUNTRIES": ("dim", 6.2, 17.6, [
        ("country_id", "NUMBER", "PK"), ("country_code", "TEXT", ""), ("country_name", "TEXT", ""),
        ("region", "TEXT", ""), ("currency_code", "TEXT", "FK")]),
    "DIM_CAR_CATEGORIES": ("dim", 18.2, 17.6, [
        ("category_id", "NUMBER", "PK"), ("category_name", "TEXT", ""), ("daily_rate_usd", "NUMBER(12,2)", "")]),
    "DIM_BRANCHES": ("dim", 0.3, 12.4, [
        ("id", "NUMBER", "PK"), ("name", "TEXT", ""), ("city", "TEXT", ""), ("capacity", "NUMBER", ""),
        ("country_id", "NUMBER", "FK"), ("country_code", "TEXT", ""), ("country_name", "TEXT", ""),
        ("region", "TEXT", ""), ("currency_code", "TEXT", "")]),
    "BRIDGE_BRANCH_CATEGORY_AVAILABILITY": ("bridge", 0.3, 7.6, [
        ("branch_id", "NUMBER", "PK, FK"), ("category_id", "NUMBER", "PK, FK"),
        ("category_name", "TEXT", ""), ("is_offered", "BOOLEAN", "")]),
    "FACT_RESERVATIONS": ("fact", 11.0, 12.4, [
        ("id", "NUMBER", "PK"), ("pickup_branch_id", "NUMBER", "FK"), ("return_branch_id", "NUMBER", "FK"),
        ("customer_id", "NUMBER", "FK"), ("car_id", "NUMBER", "FK"), ("start_date", "DATE", ""),
        ("end_date", "DATE", ""), ("booking_date", "DATE", ""), ("paid_date", "DATE", ""),
        ("payment_id", "NUMBER", ""), ("payment_method", "TEXT", ""), ("total_days", "NUMBER", ""),
        ("amount_local", "NUMBER(18,2)", ""), ("currency_code", "TEXT", "FK"),
        ("total_amount_usd", "NUMBER(37,2)", "")]),
    "DIM_CARS": ("dim", 18.2, 12.4, [
        ("id", "NUMBER", "PK"), ("license_plate", "TEXT", ""), ("model", "TEXT", ""), ("year", "NUMBER", ""),
        ("category_id", "NUMBER", "FK"), ("category", "TEXT", ""), ("daily_rate_usd", "NUMBER(12,2)", ""),
        ("current_branch_id", "NUMBER", "FK"), ("is_new_fleet", "BOOLEAN", "")]),
    "DIM_CUSTOMERS": ("dim", 18.2, 7.6, [
        ("id", "NUMBER", "PK"), ("name", "TEXT", ""), ("email", "TEXT", ""), ("phone", "TEXT", ""),
        ("phone_extension", "TEXT", ""), ("is_phone_valid", "BOOLEAN", ""),
        ("driver_license_number", "TEXT", ""), ("date_of_birth", "DATE", "")]),
}


def row_y(table, column):
    _, _, top, cols = TABLES[table]
    i = [c[0] for c in cols].index(column)
    return top - HEAD_H - ROW_H * (i + 0.5)


def side_x(table, side):
    x = TABLES[table][1]
    return x if side == "L" else x + BOX_W


def draw_table(ax, name):
    kind, x, top, cols = TABLES[name]
    st = STYLE[kind]
    h = HEAD_H + ROW_H * len(cols)
    ax.add_patch(FancyBboxPatch((x, top - h), BOX_W, h, boxstyle="round,pad=0,rounding_size=0.08",
                                fc="white", ec=st["edge"], lw=1.6, zorder=3))
    ax.add_patch(Rectangle((x, top - HEAD_H), BOX_W, HEAD_H, fc=st["head"], ec=st["edge"], lw=1.6, zorder=4))
    ax.text(x + 0.15, top - HEAD_H / 2, name, color="white", weight="bold",
            fontsize=9.5 if len(name) < 26 else 7.0, va="center", zorder=5)
    for i, (col, typ, key) in enumerate(cols):
        y = top - HEAD_H - ROW_H * (i + 0.5)
        if i % 2:
            ax.add_patch(Rectangle((x, y - ROW_H / 2), BOX_W, ROW_H, fc="#F4F6FA", ec="none", zorder=3.5))
        is_pk = "PK" in key
        ax.text(x + 0.15, y, col, fontsize=8.2, va="center", zorder=5,
                color="#C0392B" if is_pk else "#1F2A44", weight="bold" if is_pk else "normal")
        if key:
            ax.text(x + 2.55, y, key, fontsize=7.2, va="center", color="#7A869A", zorder=5)
        ax.text(x + BOX_W - 0.12, y, typ, fontsize=7.2, va="center", ha="right", color="#7A869A", zorder=5)


def connect(ax, pts, color, label=None, label_at=None):
    """pts: polyline from child (FK, 'many') to parent (PK, 'one')."""
    xs, ys = zip(*pts)
    ax.plot(xs, ys, color=color, lw=1.4, zorder=2, solid_capstyle="round")
    # 'many' end: open circle + crow's foot hint
    ax.plot(*pts[0], marker="o", ms=4.5, mfc="white", mec=color, mew=1.3, zorder=6)
    # 'one' end: filled bar marker
    ax.plot(*pts[-1], marker="o", ms=4.5, color=color, zorder=6)
    if label:
        lx, ly = label_at
        ax.text(lx, ly, label, fontsize=7, color=color, ha="center", va="bottom", style="italic", zorder=6,
                bbox=dict(fc="white", ec="none", pad=0.6))


def main():
    fig, ax = plt.subplots(figsize=(17, 13.5), dpi=150)
    ax.set_xlim(-0.3, 23.2)
    ax.set_ylim(0.2, 19.4)
    ax.axis("off")

    ax.text(11.45, 19.05, "Avelto Rentals — Gold Star Schema  (RENTAL_OPS.GOLD)", ha="center",
            fontsize=16, weight="bold", color="#1F2A44")
    ax.text(11.45, 18.55, "Lines run from a foreign key (open circle, many side) to the primary key it references "
            "(filled circle, one side).", ha="center", fontsize=9, color="#5A6476")

    c_branch, c_ref, c_car, c_cust = "#E8445A", "#4A6FA5", "#8E5BB5", "#D98C1F"

    # fact -> dim_branches (role-playing: pickup + return)
    for col, dx, lab in [("pickup_branch_id", 8.4, "pickup"), ("return_branch_id", 7.6, "return")]:
        y1, y2 = row_y("FACT_RESERVATIONS", col), row_y("DIM_BRANCHES", "id")
        connect(ax, [(side_x("FACT_RESERVATIONS", "L"), y1), (dx, y1), (dx, y2), (side_x("DIM_BRANCHES", "R"), y2)],
                c_branch, lab, ((side_x("FACT_RESERVATIONS", "L") + dx) / 2, y1 + 0.02))
    # fact -> customers / cars
    y1, y2 = row_y("FACT_RESERVATIONS", "customer_id"), row_y("DIM_CUSTOMERS", "id")
    connect(ax, [(side_x("FACT_RESERVATIONS", "R"), y1), (16.9, y1), (16.9, y2), (side_x("DIM_CUSTOMERS", "L"), y2)], c_cust)
    y1, y2 = row_y("FACT_RESERVATIONS", "car_id"), row_y("DIM_CARS", "id")
    connect(ax, [(side_x("FACT_RESERVATIONS", "R"), y1), (17.5, y1), (17.5, y2), (side_x("DIM_CARS", "L"), y2)], c_car)
    # fact -> dim_currencies (routed below the fact, up the far left)
    y1, y2 = row_y("FACT_RESERVATIONS", "currency_code"), row_y("DIM_CURRENCIES", "currency_code")
    connect(ax, [(side_x("FACT_RESERVATIONS", "L"), y1), (10.3, y1), (10.3, 2.3), (-0.1, 2.3), (-0.1, y2),
                 (side_x("DIM_CURRENCIES", "L"), y2)], c_ref, "payment currency", (5.2, 2.32))
    # branches -> countries, countries -> currencies
    y1, y2 = row_y("DIM_BRANCHES", "country_id"), row_y("DIM_COUNTRIES", "country_id")
    connect(ax, [(side_x("DIM_BRANCHES", "R"), y1), (5.7, y1), (5.7, y2), (side_x("DIM_COUNTRIES", "L"), y2)], c_ref)
    y1, y2 = row_y("DIM_COUNTRIES", "currency_code"), row_y("DIM_CURRENCIES", "currency_code")
    connect(ax, [(side_x("DIM_COUNTRIES", "L"), y1), (5.35, y1), (5.35, y2), (side_x("DIM_CURRENCIES", "R"), y2)], c_ref)
    # cars -> car categories
    y1, y2 = row_y("DIM_CARS", "category_id"), row_y("DIM_CAR_CATEGORIES", "category_id")
    connect(ax, [(side_x("DIM_CARS", "R"), y1), (23.0, y1), (23.0, y2), (side_x("DIM_CAR_CATEGORIES", "R"), y2)], c_car)
    # cars -> branches (current location, routed above the fact)
    y1, y2 = row_y("DIM_CARS", "current_branch_id"), row_y("DIM_BRANCHES", "id")
    connect(ax, [(side_x("DIM_CARS", "L"), y1), (18.0, y1), (18.0, 12.75), (9.2, 12.75), (9.2, y2),
                 (side_x("DIM_BRANCHES", "R"), y2)], "#9AA3B2", "car's current branch", (13.6, 12.77))
    # bridge -> branches, bridge -> car categories
    y1, y2 = row_y("BRIDGE_BRANCH_CATEGORY_AVAILABILITY", "branch_id"), row_y("DIM_BRANCHES", "id")
    connect(ax, [(side_x("BRIDGE_BRANCH_CATEGORY_AVAILABILITY", "L"), y1), (0.05, y1), (0.05, y2),
                 (side_x("DIM_BRANCHES", "L"), y2)], "#2E8B6E")
    y1, y2 = row_y("BRIDGE_BRANCH_CATEGORY_AVAILABILITY", "category_id"), row_y("DIM_CAR_CATEGORIES", "category_id")
    connect(ax, [(side_x("BRIDGE_BRANCH_CATEGORY_AVAILABILITY", "R"), y1), (9.8, y1), (9.8, 13.1), (17.85, 13.1),
                 (17.85, y2), (side_x("DIM_CAR_CATEGORIES", "L"), y2)], "#2E8B6E", "category availability", (13.6, 13.12))

    for name in TABLES:
        draw_table(ax, name)

    # legend
    lx, ly = 0.3, 1.35
    for i, (kind, text) in enumerate([("dim", "Dimension: descriptive attributes"),
                                      ("fact", "Fact: one row per reservation (measures)"),
                                      ("bridge", "Bridge: branch × category availability")]):
        ax.add_patch(Rectangle((lx + i * 7.4, ly - 0.15), 0.45, 0.32, fc=STYLE[kind]["head"], ec="none"))
        ax.text(lx + i * 7.4 + 0.6, ly, text, fontsize=9, va="center", color="#1F2A44")
    ax.text(0.3, 0.75, "PK = primary key   FK = foreign key   Constraints are not enforced on Dynamic Tables; "
            "integrity is checked by the validation queries.", fontsize=8, color="#5A6476")

    fig.savefig(OUT, bbox_inches="tight", facecolor="white")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
