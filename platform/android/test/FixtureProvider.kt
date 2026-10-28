package dev.oriel

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/** Synthetic content only; no access to the ledger or arbitrary app files. Test APK only. */
class FixtureProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = if (uri.lastPathSegment == "statement.pdf") "application/pdf" else "image/png"
    private fun fixture(uri: Uri): File {
        val name = uri.lastPathSegment
        if (uri.pathSegments.size == 2 && uri.pathSegments[0] == "capture") {
            require(name != null && Regex("[a-zA-Z0-9_-]{1,110}\\.(json|png)").matches(name))
            return File(context!!.cacheDir, "adaptive-probe/$name")
        }
        require(name in listOf("receipt.png", "second.png", "oversize.png", "statement.pdf"))
        val file = File(context!!.cacheDir, "fixture-$name")
        if (!file.exists()) {
            if (name == "statement.pdf") {
                val document = android.graphics.pdf.PdfDocument()
                val page = document.startPage(android.graphics.pdf.PdfDocument.PageInfo.Builder(400, 400, 1).create())
                page.canvas.drawText("SYNTHETIC TEST STATEMENT", 20f, 60f, Paint().apply { textSize = 18f })
                document.finishPage(page)
                file.outputStream().use { document.writeTo(it) }
                document.close()
            } else if (name == "oversize.png") {
                file.outputStream().use { output -> repeat(9) { output.write(ByteArray(1024 * 1024)) } }
            } else {
                val bitmap = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                canvas.drawColor(Color.WHITE)
                val paint = Paint().apply { color = Color.BLACK; textSize = 20f }
                canvas.drawText("SYNTHETIC RECEIPT", 20f, 60f, paint)
                canvas.drawText("Test household 123 CLP", 20f, 110f, paint)
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
        }
        return file
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r")
        return ParcelFileDescriptor.open(fixture(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor {
        val file = fixture(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply { addRow(columns.map<String, Any?> { if (it == OpenableColumns.SIZE) file.length() else uri.lastPathSegment }.toTypedArray()) }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = throw UnsupportedOperationException()
}
