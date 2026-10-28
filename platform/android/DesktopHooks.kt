package dev.oriel

import android.app.Activity
import android.content.Intent
import android.content.ClipDescription
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import android.view.DragEvent
import android.view.View
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/** App-owned native-renderer integration. No WebView, broad storage permission or URI paths. */
class DesktopHooks : OrielAndroidHooks {
    companion object {
        private val worker = Executors.newSingleThreadExecutor()
        private const val MAX_FILES = 8
        private const val MAX_BATCH = 32 * 1024 * 1024
        private val active = java.util.Collections.newSetFromMap(java.util.WeakHashMap<Activity, Boolean>())
        internal fun nativeDrag(view: NuiView, event: DragEvent): Boolean? {
            val description = event.clipDescription ?: return null
            if (!description.hasMimeType("image/*") && !description.hasMimeType("application/pdf")) return null
            val activity = OrielRuntime.windows[view.window]?.activity ?: return false
            if (event.action == DragEvent.ACTION_DRAG_STARTED) return !active.contains(activity)
            if (event.action == DragEvent.ACTION_DROP) {
                val permission = activity.requestDragAndDropPermissions(event)
                val clip = event.clipData
                val uris = if (clip == null) emptyList() else (0 until clip.itemCount.coerceAtMost(MAX_FILES + 1)).mapNotNull { clip.getItemAt(it).uri }
                DesktopHooks().receive(activity, uris) { permission?.release() }
            }
            return true
        }
    }

    private fun view(activity: Activity): NuiView? =
        Nui.views.values.firstOrNull { it.context === activity || (activity as? OrielActivity)?.orielWindow?.id == it.window }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        withNative(activity) {
            NuiNative.event(it.window, 0, "desktop_profile".toByteArray(), (if (activity is CompareActivity) "compare" else "main").toByteArray())
            restoreSelection(activity)
        }
        acceptIntent(activity, activity.intent)
    }

    override fun onNewIntent(activity: Activity, intent: Intent) = acceptIntent(activity, intent)
    override fun onActivityStopped(activity: Activity) {
        view(activity)?.let {
            NuiNative.event(it.window, 0, "desktop_checkpoint".toByteArray(), "null".toByteArray())
            val file = android.util.AtomicFile(java.io.File(activity.filesDir, "desktop-selection-${if (activity is CompareActivity) "compare" else "main"}.json"))
            var stream: java.io.FileOutputStream? = null
            try {
                stream = file.startWrite()
                stream.write(it.desktopSelection().toString().toByteArray())
                file.finishWrite(stream)
            } catch (_: Exception) { file.failWrite(stream) }
        }
    }
    override fun onSaveInstanceState(activity: Activity, outState: Bundle) = onActivityStopped(activity)

    private fun withNative(activity: Activity, action: (NuiView) -> Unit) {
        val root = activity.findViewById<View>(android.R.id.content)
        var attempts = 0
        val pending = object : Runnable {
            override fun run() {
                if (activity.isDestroyed) return
                view(activity)?.let { action(it); return }
                attempts += 1
                if (attempts < 40) root.postDelayed(this, 250)
                else Toast.makeText(activity, "The ledger window is not ready. Please reopen the file.", Toast.LENGTH_LONG).show()
            }
        }
        root.post(pending)
    }

    private fun restoreSelection(activity: Activity) {
        val state = try { JSONObject(java.io.File(activity.filesDir, "desktop-selection-${if (activity is CompareActivity) "compare" else "main"}.json").readText()) } catch (_: Exception) { return }
        val root = activity.findViewById<View>(android.R.id.content)
        var attempts = 0
        val restore = object : Runnable {
            override fun run() {
                if (activity.isDestroyed) return
                if (view(activity)?.desktopRestoreSelection(state) == true) return
                attempts += 1
                if (attempts < 40) root.postDelayed(this, 250)
            }
        }
        root.postDelayed(restore, 250)
    }

    private fun acceptIntent(activity: Activity, intent: Intent) {
        if (activity.packageName == "com.pennygoblin.adaptive.test" && intent.action == "penny.adaptive.PROBE") {
            try {
                Class.forName("dev.oriel.AdaptiveProbe").getMethod("handle", Activity::class.java, Intent::class.java).invoke(null, activity, intent)
            } catch (error: Exception) { android.util.Log.w("PennyAdaptiveTest", "Probe unavailable", error) }
            return
        }
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return
        val uris = mutableListOf<Uri>()
        intent.data?.let { uris.add(it) }
        intent.clipData?.let { clip -> for (i in 0 until clip.itemCount.coerceAtMost(MAX_FILES + 1)) clip.getItemAt(i).uri?.let { if (it !in uris) uris.add(it) } }
        @Suppress("DEPRECATION")
        if (uris.isEmpty() && intent.action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.take(MAX_FILES + 1)?.let { uris.addAll(it) }
        }
        if (uris.isEmpty()) intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        receive(activity, uris) {}
    }

    private fun receive(activity: Activity, uris: List<Uri>, release: () -> Unit) {
        if (uris.isEmpty() || uris.size > MAX_FILES || !active.add(activity)) {
            release()
            Toast.makeText(activity, "Choose 1–8 image or PDF files; wait for the current import.", Toast.LENGTH_LONG).show()
            return
        }
        worker.execute {
            try {
                val files = JSONArray()
                var total = 0
                for (uri in uris) {
                    require(uri.scheme == "content") { "Only granted content files are accepted" }
                    val resolver = activity.contentResolver
                    val mime = resolver.getType(uri) ?: ""
                    val limit = if (mime == "application/pdf") 32 * 1024 * 1024 else 8 * 1024 * 1024
                    require(mime == "application/pdf" || mime in listOf("image/jpeg", "image/png")) { "Unsupported file type" }
                    val bytes = resolver.openInputStream(uri)?.use { input ->
                        val out = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(32768)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            require(out.size().toLong() + count <= limit && total.toLong() + out.size() + count <= MAX_BATCH) { "File or batch is too large" }
                            out.write(buffer, 0, count)
                        }
                        out.toByteArray()
                    } ?: throw IllegalArgumentException("File is unreadable")
                    total += bytes.size
                    var name = "attachment"
                    resolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) name = it.getString(0)?.take(240) ?: name
                    }
                    files.put(JSONObject().put("name", name).put("data_url", "data:$mime;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)))
                }
                activity.runOnUiThread {
                    if (!activity.isDestroyed) withNative(activity) { NuiNative.event(it.window, 0, "desktop_files".toByteArray(), files.toString().toByteArray()) }
                }
            } catch (error: Exception) {
                activity.runOnUiThread { Toast.makeText(activity, error.message ?: "Could not open files", Toast.LENGTH_LONG).show() }
            } finally {
                release()
                activity.runOnUiThread { active.remove(activity) }
            }
        }
    }
}
