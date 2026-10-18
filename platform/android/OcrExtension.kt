package com.pennygoblin.ocr

import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import dev.oriel.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.concurrent.TimeUnit

/**
 * The "penny.ocr" app extension: on-device text recognition with ML Kit's
 * bundled Latin model (offline, no Play services download). Input is the
 * voucher's encoded bytes (JPEG/PNG); output is each recognized line with its
 * box, which src/core/ocr_rules.zig turns into rows and payment fields.
 */
class OcrExtension : OrielAppExtension {
    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

    override fun call(method: String, input: ByteArray, call: OrielCall): ByteArray {
        if (method != "recognize") throw OrielExtensionError("UnknownOcrMethod", "Unknown OCR method")
        val bitmap = BitmapFactory.decodeByteArray(input, 0, input.size)
            ?: throw OrielExtensionError("InvalidImage", "The image could not be decoded")
        try {
            val image = InputImage.fromBitmap(bitmap, rotation(input))
            val text = try {
                Tasks.await(recognizer.process(image), 30, TimeUnit.SECONDS)
            } catch (error: Exception) {
                throw OrielExtensionError("OcrFailed", "Text recognition failed")
            }
            val lines = JSONArray()
            for (block in text.textBlocks) for (line in block.lines) {
                val box = line.boundingBox ?: continue
                lines.put(JSONObject().put("text", line.text).put("left", box.left).put("top", box.top).put("right", box.right).put("bottom", box.bottom))
            }
            return JSONObject().put("lines", lines).toString().toByteArray(Charsets.UTF_8)
        } finally {
            bitmap.recycle()
        }
    }

    /** Camera JPEGs are often stored sideways with an EXIF orientation tag. */
    private fun rotation(bytes: ByteArray): Int = try {
        when (ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
    } catch (_: Exception) { 0 }
}
