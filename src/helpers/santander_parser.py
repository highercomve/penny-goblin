"""
Extract transactions from Santander Chile credit card statements and debit/checking cartolas.
Currently supports:
- Santander Chile Credit Card Statements (Estado de Cuenta / Movimientos Facturados)
- Santander Chile Checking / Debit Account Statements (Cuenta Corriente / Cartola)
"""

import pdfplumber
import json
import os
import sys
import re

def is_transfer_to_self(desc, owners):
    """Check if outgoing transfer description is a transfer to one's own account."""
    desc_clean = re.sub(r'[^a-zA-Z0-9\s]', ' ', desc).lower()
    m = re.search(r'\btransf(?:erencia)?\s*(?:a|\.)?\s+(.+)', desc_clean)
    if not m:
        return False
    recipient = m.group(1)
    recipient_words = set(recipient.split())
    for o in owners:
        o_clean = re.sub(r'[^a-zA-Z0-9\s]', ' ', o).lower()
        o_words = set(w for w in o_clean.split() if len(w) > 2)
        if o_words and o_words.issubset(recipient_words):
            return True
        if o.lower().strip() in recipient:
            return True
    return False

def is_internal_debt_payment(desc):
    """Filter out credit card and overdraft line of credit payoffs from checking account."""
    u = desc.upper()
    if re.search(r'\b(?:PAGO|TRASPASO).*(?:TARJETA|T\.)(?:\s*DE)?\s*CR[EÉ]DITO', u):
        return True
    if re.search(r'\b(?:PAGO|TRASPASO).*(?:L[IÍ]NEA)(?:\s*DE)?\s*CR[EÉ]DITO', u):
        return True
    if re.search(r'\bTRASPASO.*CON\s+LA\s+CUENTA', u):
        return True
    return False

def clean_cartola_desc(desc):
    """Clean redundant RUTs, prefixes, and formatting from cartola descriptions."""
    d = re.sub(r'\b\d{8,9}[0-9kK]\b', '', desc)
    d = re.sub(r'^\s*Compra\s+Nacional\s+VD\s+', '', d, flags=re.I)
    d = re.sub(r'\s+', ' ', d).strip()
    return d

def extract_cartola_transactions(pdf, filename, categories, categorize_fn, account_owners):
    """Extract outgoing expenses from a Santander Chile Cuenta Corriente (checking/debit) cartola."""
    transactions = []
    
    full_text = ''
    for p in pdf.pages:
        full_text += (p.extract_text() or '') + '\n'
        
    start_year = end_year = '26'
    m_range = re.search(r'(\d{2})/(\d{2})/(\d{4})\s+(\d{2})/(\d{2})/(\d{4})', full_text)
    start_month, end_month = '01', '12'
    if m_range:
        start_month, start_year = m_range.group(2), m_range.group(3)[-2:]
        end_month, end_year = m_range.group(5), m_range.group(6)[-2:]
    else:
        m_any_year = re.search(r'\b\d{2}/\d{2}/(\d{4})\b', full_text)
        if m_any_year:
            start_year = end_year = m_any_year.group(1)[-2:]
    
    # Auto-detect titular name from cartola header if present
    detected_owner = re.search(r'CUENTA CORRIENTE[^\n]*\n([A-Z\s]{4,50})\n', full_text)
    combined_owners = list(account_owners)
    if detected_owner:
        owner_name = detected_owner.group(1).strip()
        if owner_name and owner_name not in combined_owners:
            combined_owners.append(owner_name)
    
    for page in pdf.pages:
        words = page.extract_words()
        if not words:
            continue
        
        y_start = 0
        y_end = page.height
        for w in words:
            if 'DETALLE' in w['text']:
                y_start = max(y_start, w['bottom'])
            if any(stop in w['text'] for stop in ['Resumen', 'INFORMACION']):
                if w['top'] > y_start + 40:
                    y_end = min(y_end, w['top'])
        
        tx_words = [w for w in words if y_start < w['top'] < y_end]
        lines = []
        for w in tx_words:
            added = False
            for l in lines:
                if abs(l['top'] - w['top']) < 3.5:
                    l['words'].append(w)
                    added = True
                    break
            if not added:
                lines.append({'top': w['top'], 'words': [w]})
        
        lines.sort(key=lambda l: l['top'])
        for l in lines:
            ws = sorted(l['words'], key=lambda w: w['x0'])
            if not ws:
                continue
            m_date = re.match(r'^(\d{2})/(\d{2})', ws[0]['text'])
            if not m_date:
                continue
            day = m_date.group(1)
            month = m_date.group(2)
            year = start_year if month == start_month else end_year
            date_str = f"{day}/{month}/{year}"
            
            cargo_amount = None
            desc_words = []
            
            for w in ws:
                t = w['text']
                if '.' in t and re.match(r'^[\d.]+$', t):
                    val = int(t.replace('.', ''))
                    if w['x1'] <= 455:
                        cargo_amount = val
                else:
                    if w['x0'] >= 105 and w['x1'] <= 325:
                        desc_words.append(t)
            
            if cargo_amount is None or cargo_amount <= 0:
                continue
            
            raw_desc = ' '.join(desc_words).strip()
            if not raw_desc:
                continue
                
            if is_transfer_to_self(raw_desc, combined_owners):
                continue
            if is_internal_debt_payment(raw_desc):
                continue
                
            final_desc = clean_cartola_desc(raw_desc)
            transactions.append({
                "date": date_str,
                "card": "Debit",
                "desc": final_desc,
                "amount": cargo_amount,
                "category": categorize_fn(final_desc)
            })
            
    return transactions

def extract_transactions(folder_path):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(base_dir, "data")
    json_path = os.path.join(data_dir, "transactions.json")

    if not os.path.isdir(folder_path):
        print(f"Error: Folder '{folder_path}' does not exist.")
        return

    os.makedirs(data_dir, exist_ok=True)
    transactions = []

    # Category keywords live in categories.json so they can be edited without touching code.
    with open(os.path.join(base_dir, "categories.json"), 'r') as f:
        config = json.load(f)
    categories = config["categories"]

    # Load account owners and fixed expenses from config.json if available
    config_path = os.path.join(os.path.dirname(base_dir), "config.json")
    account_owners = []
    fixed_items = []
    if os.path.exists(config_path):
        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
                owner_val = cfg.get("account_owner") or cfg.get("account_owners", [])
                if isinstance(owner_val, str) and owner_val.strip():
                    account_owners.append(owner_val.strip())
                elif isinstance(owner_val, list):
                    account_owners.extend([str(x).strip() for x in owner_val if str(x).strip()])

                raw_fixed = cfg.get("budget", {}).get("fixed_expenses", [])
                if isinstance(raw_fixed, list):
                    for entry in raw_fixed:
                        if isinstance(entry, dict):
                            name = str(entry.get("name", "")).strip()
                            kws = entry.get("keywords") or entry.get("keyword") or entry.get("match") or []
                            if isinstance(kws, str):
                                kws = [k.strip() for k in kws.split(",") if k.strip()]
                            elif isinstance(kws, list):
                                kws = [str(k).strip() for k in kws if str(k).strip()]
                            else:
                                kws = []
                            if name and kws:
                                fixed_items.append({"name": name, "keywords": kws})
        except Exception:
            pass

    def categorize(desc):
        desc_clean = re.sub(r'[^a-zA-Z0-9\s]', ' ', desc).upper()
        for item in fixed_items:
            for kw in item["keywords"]:
                kw_clean = re.sub(r'[^a-zA-Z0-9\s]', ' ', kw).upper().strip()
                if kw_clean and kw_clean in desc_clean:
                    return f"Fixed: {item['name']}"

        desc_upper = desc.upper()
        for cat, keywords in categories.items():
            if any(k.upper() in desc_upper for k in keywords):
                return cat
        return "Other"

    for filename in sorted(os.listdir(folder_path)):
        if filename.lower().endswith(".pdf"):
            path = os.path.join(folder_path, filename)
            print(f"Processing {filename}...")
            try:
                with pdfplumber.open(path) as pdf:
                    p0_text = (pdf.pages[0].extract_text() or "").upper() if pdf.pages else ""
                    
                    # Detect if document is a Cuenta Corriente (checking/debit) cartola
                    is_cartola = "CUENTA CORRIENTE" in p0_text or ("CARTOLA" in p0_text and "DETALLE DE MOVIMIENTOS" in p0_text)
                    
                    if is_cartola:
                        cartola_txs = extract_cartola_transactions(pdf, filename, categories, categorize, account_owners)
                        transactions.extend(cartola_txs)
                        print(f"  -> Extracted {len(cartola_txs)} debit expense(s) from {filename}")
                        continue

                    # Otherwise, extract as Santander Credit Card statement
                    current_card = "Unknown"
                    cc_count = 0
                    for page in pdf.pages:
                        text = page.extract_text()
                        if text:
                            for line in text.split('\n'):
                                # Detect card header
                                card_match = re.search(r'MOVIMIENTOS TARJETA XXXX-(\d{4})', line)
                                if card_match:
                                    current_card = card_match.group(1)
                                    continue

                                if '$' in line:
                                    date_match = re.search(r'(\d{2}/\d{2}/\d{2})', line)
                                    amount_match = re.search(r'\$([\d,.]+)', line)

                                    if date_match and amount_match:
                                        date_str = date_match.group(1)
                                        amount_str = amount_match.group(1).replace(',', '').replace('.', '')

                                        start_idx = date_match.end()
                                        end_idx = amount_match.start()
                                        desc_str = line[start_idx:end_idx].strip()

                                        try:
                                            clean_amount = re.sub(r'[^\d]', '', amount_str)
                                            amount = int(clean_amount)

                                            if amount > 0:
                                                transactions.append({
                                                    "date": date_str,
                                                    "card": current_card,
                                                    "desc": desc_str,
                                                    "amount": amount,
                                                    "category": categorize(desc_str)
                                                })
                                                cc_count += 1
                                        except ValueError:
                                            continue
                    print(f"  -> Extracted {cc_count} credit card transaction(s) from {filename}")
            except Exception as e:
                print(f"Failed to process {filename}: {e}")

    with open(json_path, 'w') as f:
        json.dump(transactions, f, indent=4)
    print(f"Successfully saved {len(transactions)} transactions to {json_path}")
    if len(transactions) == 0:
        pdf_count = len([f for f in os.listdir(folder_path) if f.lower().endswith(".pdf")])
        if pdf_count > 0:
            print("💡 Note: Found PDF files but extracted 0 transactions. Currently, only Santander Chile statements are supported.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 extract_data.py <folder_path>")
    else:
        extract_transactions(sys.argv[1])
