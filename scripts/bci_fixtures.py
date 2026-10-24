"""Small synthetic BCI-layout PDFs. No customer documents or transactions."""

def pdf(card):
    commands = []

    def text(x, y, value):
        escaped = value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        commands.append(f"BT /F1 10 Tf 1 0 0 1 {x} {y} Tm ({escaped}) Tj ET".encode("latin1"))

    if card:
        text(40, 800, "DETALLE MOVIMIENTOS TARJETA DE CREDITO")
        text(40, 780, "TARJETA: BCI / MASTERCARD **** 1234")
        for x, label in ((40, "Fecha"), (160, "Descripción"), (400, "Tipo"), (500, "Monto")):
            text(x, 740, label)
        for y, date, merchant, amount, arrow in ((700, "18/10/2026", "TEST BCI SHOP", "1.200", "Orange"),
                                                (660, "17/10/2026", "PAGO", "5.000", "Green")):
            text(40, y, date)
            text(150, y, merchant)
            text(500, y, amount)
            commands.append(f"q 6 0 0 6 485 {y} cm /{arrow} Do Q".encode())
    else:
        text(40, 800, "CARTOLA DE CUENTA CORRIENTE")
        text(40, 780, "N° CUENTA 00001234")
        for x, label in ((40, "FECHA"), (150, "DESCRIPCION"), (310, "DOCUMENTO"), (400, "CARGOS"), (480, "ABONOS"), (544, "SALDO DIARIO")):
            text(x, 740, label)
        for y, merchant, amount, x in ((700, "TEST BCI SHOP", "1.200", 406),
                                        (660, "PAGO TARJETA DE CREDITO", "2.000", 406),
                                        (620, "DEPOSITO", "1.000", 486)):
            text(40, y, "18/10/2026")
            text(140, y, merchant)
            text(x, y, amount)
        text(40, 580, "Resumen")
        text(40, 560, "0 - 3.200 + 1.000 = 0")
    stream = b"\n".join(commands)
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 700 842] /Resources << /Font << /F1 4 0 R >> /XObject << /Orange 6 0 R /Green 7 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"]
    for colour in (b"\xff\x80\x00", b"\x00\xff\x00"):
        objects.append(b"<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\n" + colour + b"\nendstream")
    data = b"%PDF-1.4\n"
    offsets = []
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
    start = len(data)
    data += f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode()
    data += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets)
    return data + f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
