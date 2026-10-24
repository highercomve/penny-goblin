"""Bank of America activity CSVs. Strict amounts; no inferred column mapping.

Supported layouts: checking Date/Description/Amount/Running Bal. and credit
card Posted Date/Reference Number/Payee/Amount. Negative values are debits.
Balances, deposits, refunds and card repayments are never expense rows.
"""
import csv
import datetime
import io
import re

MAX_BYTES = 8 * 1024 * 1024
MAX_ROWS = 10000
HEADERS = {
    ("Date", "Description", "Amount", "Running Bal."): ("Date", "Description"),
    ("Posted Date", "Reference Number", "Payee", "Address", "Amount"): ("Posted Date", "Payee"),
    ("Posted Date", "Reference Number", "Payee", "Amount"): ("Posted Date", "Payee"),
}
# Match bank card-payment descriptors, not arbitrary merchants containing PAYMENT.
REPAYMENT = re.compile(r"^(?:BA ELECTRONIC PAYMENT|BANK OF AMERICA (?:CREDIT CARD|DES:PAYMENT)|"
                       r"BKOFAMERICA (?:CC|CREDIT CARD)|PAYMENT (?:TO|THANK YOU)|"
                       r"ONLINE (?:BANKING )?PAYMENT (?:TO|THANK YOU))\b", re.I)


def cents(value):
    value = value.strip()
    if not re.fullmatch(r"-?(?:\d+|\d{1,3}(?:,\d{3})+)\.\d{2}", value):
        raise ValueError("Invalid USD amount")
    negative = value.startswith("-")
    dollars, fraction = value.lstrip("-").replace(",", "").split(".")
    result = int(dollars) * 100 + int(fraction)
    if result > 1_000_000_000_000:
        raise ValueError("Amount too large")
    return -result if negative else result


def parse(data):
    if not data or len(data) > MAX_BYTES:
        raise ValueError("CSV size limit")
    text = data.decode("utf-8-sig")
    if "\0" in text:
        raise ValueError("Invalid CSV")
    reader = csv.reader(io.StringIO(text, newline=""), strict=True)
    header = None
    for _ in range(25):
        line = next(reader, None)
        if line is None:
            break
        candidate = tuple(cell.strip() for cell in line)
        if candidate in HEADERS:
            header = candidate
            break
    if header is None:
        raise ValueError("Choose a Bank of America activity CSV, not a PDF")
    date_key, payee_key = HEADERS[header]
    output = []
    for index, cells in enumerate(reader):
        if index >= MAX_ROWS:
            raise ValueError("Too many movements")
        if not any(cell.strip() for cell in cells):
            continue
        if len(cells) != len(header):
            raise ValueError("Malformed CSV row")
        row = dict(zip(header, cells))
        # Checking exports may include a dated opening-balance row.
        if not row["Amount"].strip() and header[0] == "Date" and re.fullmatch(
                r"Beginning balance(?: as of \d{2}/\d{2}/\d{4})?", row[payee_key].strip(), re.I):
            continue
        raw_date = row[date_key].strip()
        if not re.fullmatch(r"\d{2}/\d{2}/\d{4}", raw_date):
            raise ValueError("Invalid posting date")
        date = datetime.datetime.strptime(raw_date, "%m/%d/%Y").date()
        if not 1900 <= date.year <= 2199:
            raise ValueError("Invalid posting date")
        amount = cents(row["Amount"])
        payee = " ".join(row[payee_key].split())
        if not payee or len(payee.encode("utf-8")) > 240:
            raise ValueError("Invalid payee")
        if amount >= 0 or REPAYMENT.search(payee):
            continue
        output.append({"date": date.isoformat(), "amount": -amount, "payee": payee,
                       "currency": "USD", "account": "Bank of America", "category": "Other"})
    return output
