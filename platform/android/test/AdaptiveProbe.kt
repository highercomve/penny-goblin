package dev.oriel

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Included only in the separate synthetic-data test APK. Never copied into production builds. */
object AdaptiveProbe {
    @JvmStatic fun handle(activity: Activity, intent: Intent): Boolean {
        if (activity.packageName != "com.pennygoblin.adaptive.test" || intent.action != "penny.adaptive.PROBE") return false
        val command = intent.getStringExtra("command") ?: "capture"
        if (command == "recreate") { activity.recreate(); return true }
        if (command in listOf("tap", "right", "hover", "wheel")) {
            val view = Nui.views.values.firstOrNull { (activity as? OrielActivity)?.orielWindow?.id == it.window } ?: return true
            val x = intent.getFloatExtra("x", 100f); val y = intent.getFloatExtra("y", 100f)
            val now = android.os.SystemClock.uptimeMillis()
            val prop = android.view.MotionEvent.PointerProperties().apply { id = 0; toolType = android.view.MotionEvent.TOOL_TYPE_MOUSE }
            val coord = android.view.MotionEvent.PointerCoords().apply { this.x = x; this.y = y; pressure = 1f; size = 1f
                setAxisValue(android.view.MotionEvent.AXIS_VSCROLL, intent.getFloatExtra("amount", -3f)) }
            val actions = when (command) {
                "hover" -> listOf(android.view.MotionEvent.ACTION_HOVER_MOVE)
                "wheel" -> listOf(android.view.MotionEvent.ACTION_SCROLL)
                else -> listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)
            }
            for (action in actions) {
                val buttons = if (action == android.view.MotionEvent.ACTION_UP) 0 else if (command == "right") android.view.MotionEvent.BUTTON_SECONDARY else android.view.MotionEvent.BUTTON_PRIMARY
                val event = android.view.MotionEvent.obtain(now, now, action, 1, arrayOf(prop), arrayOf(coord), intent.getIntExtra("meta", 0), buttons,
                    1f, 1f, 0, 0, android.view.InputDevice.SOURCE_MOUSE, 0)
                if (command == "hover" || command == "wheel") view.dispatchGenericMotionEvent(event) else view.dispatchTouchEvent(event)
                event.recycle()
            }
            return true
        }
        val name = (intent.getStringExtra("name") ?: "capture").take(80).replace(Regex("[^a-zA-Z0-9_-]"), "_")
        activity.window.decorView.postDelayed({
            val view = Nui.views.values.firstOrNull { (activity as? OrielActivity)?.orielWindow?.id == it.window } ?: return@postDelayed
            if (view.width <= 0 || view.height <= 0) return@postDelayed
            val directory = File(activity.cacheDir, "adaptive-probe").apply { mkdirs() }
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            val records = JSONArray()
            try {
                val member = view.javaClass.getDeclaredField("frames").apply { isAccessible = true }
                val idsMember = view.javaClass.getDeclaredField("ids").apply { isAccessible = true }
                val nodesMember = view.javaClass.getDeclaredField("nodes").apply { isAccessible = true }
                val frames = member.get(view) as FloatArray
                val ids = idsMember.get(view) as IntArray
                @Suppress("UNCHECKED_CAST") val nodes = nodesMember.get(view) as Map<Int, NuiNode>
                var r = 0
                while (r + 14 <= frames.size && records.length() < 10000) {
                    val node = nodes[ids[r]]
                    records.put(JSONObject().put("id", ids[r]).put("kind", node?.kind).put("text", node?.textForDump())
                        .put("x", frames[r + 1]).put("y", frames[r + 2]).put("width", frames[r + 3]).put("height", frames[r + 4])
                        .put("content_x", frames[r + 9]).put("content_y", frames[r + 10]).put("content_width", frames[r + 11]).put("content_height", frames[r + 12]))
                    r += 14
                }
            } catch (_: Exception) {}
            val nativeFields = try {
                @Suppress("UNCHECKED_CAST")
                (view.javaClass.getDeclaredField("fields").apply { isAccessible = true }.get(view) as Map<Int, View>)
            } catch (_: Exception) { emptyMap<Int, View>() }
            val scale = try { view.javaClass.getDeclaredField("density").apply { isAccessible = true }.getFloat(view) } catch (_: Exception) { view.resources.displayMetrics.density }
            val fields = JSONArray()
            fun visit(node: View, depth: Int) {
                if (depth > 32) return
                if (node is EditText && node.visibility == View.VISIBLE) fields.put(JSONObject()
                    .put("id", node.id).put("node", nativeFields.entries.firstOrNull { it.value === node }?.key).put("text", node.text.toString()).put("hint", node.hint?.toString())
                    .put("description", node.contentDescription?.toString()).put("focused", node.hasFocus())
                    .put("start", node.selectionStart).put("end", node.selectionEnd)
                    .put("x", node.x).put("y", node.y).put("width", node.width).put("height", node.height))
                if (node is ViewGroup) for (i in 0 until node.childCount.coerceAtMost(4096)) visit(node.getChildAt(i), depth + 1)
            }
            visit(view, 0)
            File(directory, "$name.json").writeText(JSONObject().put("width", view.width).put("height", view.height)
                .put("scale", scale).put("orientation", view.resources.configuration.orientation).put("density", view.resources.displayMetrics.density).put("fontScale", view.resources.configuration.fontScale)
                .put("task", activity.taskId).put("fields", fields).put("nodes", records).toString(2))
        }, 500)
        return true
    }
}
