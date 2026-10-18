"""BCI (Banco de Crédito e Inversiones, Chile) statements, read by position.

Two documents, as BCI's Banco en Línea downloads them:
- "Detalle movimientos tarjeta de crédito" (facturados / no facturados): one
  row per movement between separator lines; whether it's a charge or a credit
  is only the colour of the arrow beside its amount (orange / green).
- "Cartola de cuenta corriente": charges and deposits are told apart by their
  column; a description may wrap onto the lines above and below its date.
  The period summary's "Total Cargos y Cheques" must equal the charges read.

Rows are expenses only: credits, deposits, overdraft-line movements, card
payments (their purchases come from the card's own statement) and transfers
to the account owners are left out.
"""
import re

CARD_MARKER = "DETALLE MOVIMIENTOS TARJETA DE CR"
CARTOLA_MARKER = "CARTOLA DE CUENTA CORRIENTE"


def detect(first_page_text):
    """"card", "cartola" or None, from the first page's text."""
    text = first_page_text.upper()
    if CARD_MARKER in text and "TARJETA: BCI" in text:
        return "card"
    # BCI's cartola names the bank only in its logo; its daily-balance column
    # and overdraft-line block are its own (Santander's says BANCO SANTANDER).
    if CARTOLA_MARKER in text and "SALDO DIARIO" in text and "SANTANDER" not in text:
        return "cartola"
    return None


def amount_of(text):
    """"1.149.431" or "$ 5.324" → 1149431; None for anything else."""
    t = text.replace("$", "").strip()
    if not re.fullmatch(r"\d{1,3}(?:\.\d{3})*", t):
        return None
    return int(t.replace(".", ""))


def iso_date(text):
    """"5/10/2026" or "06/05/2026" → "2026-10-05"; None if not a date."""
    m = re.fullmatch(r"(\d{1,2})/(\d{1,2})/(\d{4})", text)
    if not m:
        return None
    day, month, year = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if not (1 <= month <= 12 and 1 <= day <= 31):
        return None
    return f"{year:04d}-{month:02d}-{day:02d}"


def is_green(rgb):
    """An arrow's average colour: green is a credit (abono), orange a charge."""
    r, g, _ = rgb
    return g > r


def arrow_colour(image):
    """The average colour of an arrow image's visible (non-white) pixels."""
    stream = image["stream"]
    data = stream.get_data()
    width, height = image["srcsize"]
    channels = len(data) // max(1, width * height)
    if channels < 3:
        return None
    pixels = [data[i:i + 3] for i in range(0, width * height * channels, channels)]
    visible = [p for p in pixels if len(p) == 3 and not all(c > 230 for c in p)]
    if not visible:
        return None
    return tuple(sum(p[i] for p in visible) / len(visible) for i in range(3))


def is_owner_transfer(desc, owners):
    """"TRANSFER A S.MARIN ZAMBRA" to owner "Sergio Marin": BCI cuts names to
    a few letters, so each of the owner's words must match a recipient word
    exactly, by its initial ("S") or as a cut-off start ("ZAMBRA")."""
    m = re.match(r"\s*TRANSF(?:ER|ERENCIA)?\s+A\s+(.+)", desc, re.I)
    if not m:
        return False
    recipient = [w for w in re.split(r"[^A-Za-zÁÉÍÓÚÑáéíóúñ]+", m.group(1).lower()) if w]
    for owner in owners:
        words = [w for w in re.split(r"[^A-Za-zÁÉÍÓÚÑáéíóúñ]+", owner.lower()) if len(w) > 1]
        if words and all(any(r == w or (len(r) == 1 and w.startswith(r)) or (len(r) >= 4 and w.startswith(r)) for r in recipient) for w in words):
            return True
    return False


INTERNAL = re.compile(
    r"TRASPASO DESDE LINEA|AMORTIZACION LINEA|PAGO AUTO SOBREGIRO|"
    r"(?:PAGO|PAC|PAGO DEUDA)\s+(?:DEUDA\s+)?TARJETA DE CREDITO",
    re.I,
)


def _words(page):
    return page.extract_words(keep_blank_chars=False, use_text_flow=False)


def _band(anchors, index, half=14):
    """The vertical band of the row anchored at anchors[index] (a top)."""
    top = anchors[index]
    before = (anchors[index - 1] + top) / 2 if index > 0 else top - half
    after = (anchors[index + 1] + top) / 2 if index + 1 < len(anchors) else top + half
    return max(before, top - half), min(after, top + half)


def parse_card(pdf, categorize):
    """Charges of a BCI card's movements download (facturados or not)."""
    first = pdf.pages[0].extract_text() or ""
    m = re.search(r"\*{4}\s*(\d{4})", first)
    account = m.group(1) if m else "BCI"
    rows = []
    for page in pdf.pages:
        words = _words(page)
        header = {w["text"]: w for w in words if w["text"] in ("Fecha", "Descripción", "Tipo", "Monto")}
        if not {"Fecha", "Descripción", "Tipo"} <= header.keys():
            continue
        desc_left = header["Descripción"]["x0"] - 30
        desc_right = header["Tipo"]["x0"] - 5
        dates = [w for w in words if w["top"] > header["Fecha"]["bottom"] and w["x0"] < desc_left and iso_date(w["text"])]
        anchors = [w["top"] for w in dates]
        arrows = [im for im in page.images if im["width"] < 12 and im["height"] < 12]
        for i, date_word in enumerate(dates):
            low, high = _band(anchors, i, half=20)
            in_band = [w for w in words if low <= w["top"] <= high]
            desc = " ".join(w["text"] for w in sorted(in_band, key=lambda w: (round(w["top"]), w["x0"]))
                            if desc_left <= w["x0"] and w["x1"] <= desc_right)
            amount = next((a for w in in_band if w["x0"] > desc_right and (a := amount_of(w["text"])) is not None), None)
            arrow = next((im for im in arrows if low <= im["top"] <= high), None)
            colour = arrow_colour(arrow) if arrow else None
            if amount is None or colour is None:
                raise ValueError("Unreadable BCI card movement")
            if is_green(colour):
                continue  # A credit: a payment, refund or reversal.
            payee = re.sub(r"\s+", " ", desc).strip()
            rows.append({"date": iso_date(date_word["text"]), "amount": amount, "payee": payee,
                         "account": account, "category": categorize(payee)})
    return rows


def cartola_total_charges(text):
    """"Total Cargos y Cheques" from the period summary: the number after
    the minus sign in "262.890 - 45.413.736 + 45.150.846 = 0"."""
    m = re.search(r"([\d.]+)\s+-\s+([\d.]+)\s+\+\s+([\d.]+)\s+=", text)
    return amount_of(m.group(2)) if m else None


def parse_cartola(pdf, categorize, owners):
    """Expenses of a BCI checking account cartola."""
    first = pdf.pages[0].extract_text() or ""
    m = re.search(r"N°\s*CUENTA\s+(\d+)", first)
    account = m.group(1)[-4:] if m else "BCI"
    rows, all_charges, full_text = [], 0, ""
    desc_left = None
    for page in pdf.pages:
        full_text += (page.extract_text() or "") + "\n"
        words = _words(page)
        def header(text):
            return next((w for w in words if w["text"] == text), None)
        fecha, desc_h, doc_h = header("FECHA"), header("DESCRIPCION"), header("DOCUMENTO")
        cargos, abonos, diario = header("CARGOS"), header("ABONOS"), header("DIARIO")
        if not all((fecha, desc_h, doc_h, cargos, abonos, diario)):
            continue
        columns = {"charge": cargos["x1"], "deposit": abonos["x1"], "balance": diario["x1"]}
        stop = next((w["top"] for w in words if w["text"] == "Resumen" and w["top"] > fecha["bottom"]), page.height)
        dates = [w for w in words if fecha["bottom"] < w["top"] < stop and w["x0"] < desc_h["x0"] - 40 and iso_date(w["text"])]
        anchors = [w["top"] for w in dates]
        # The description column starts left of its centred header: where a
        # wrapped description's own lines (no date on them) begin.
        dated = {round(t) for t in anchors}
        wrapped = [w["x0"] for w in words if fecha["bottom"] < w["top"] < stop and w["x0"] > fecha["x1"]
                   and all(abs(w["top"] - t) >= 3 for t in dated)]
        if wrapped:
            desc_left = min(wrapped)
        left = (desc_left if desc_left is not None else desc_h["x0"] - 15) - 2
        for i, date_word in enumerate(dates):
            low, high = _band(anchors, i, half=12)
            in_band = [w for w in words if low <= w["top"] <= high]
            desc = " ".join(w["text"] for w in sorted(in_band, key=lambda w: (round(w["top"]), w["x0"]))
                            if left <= w["x0"] and w["x1"] <= doc_h["x0"] - 5)
            line = [w for w in words if abs(w["top"] - date_word["top"]) < 3]
            charge = None
            for w in line:
                value = amount_of(w["text"].lstrip("-"))
                if value is None or w["x0"] < doc_h["x1"]:
                    continue
                if min(columns, key=lambda c: abs(columns[c] - w["x1"])) == "charge":
                    charge = value
            if charge is None:
                continue  # A deposit.
            all_charges += charge
            payee = re.sub(r"\s+", " ", desc).strip()
            if INTERNAL.search(payee) or is_owner_transfer(payee, owners):
                continue
            rows.append({"date": iso_date(date_word["text"]), "amount": charge, "payee": payee,
                         "account": account, "category": categorize(payee)})
    total = cartola_total_charges(full_text)
    if total is None or total != all_charges:
        raise ValueError("BCI cartola charges don't match its total")
    return rows
