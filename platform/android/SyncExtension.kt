package com.pennygoblin.sync

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import dev.oriel.*
import com.google.zxing.integration.android.IntentIntegrator
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

class SyncExtension : OrielAppExtension, OrielAndroidHooks {
    private var context: OrielExtensionContext? = null
    private fun comparisonWindow() = android.app.Application.getProcessName().endsWith(":compare")

    // Oriel constructs one instance for extension calls and another for hooks;
    // the request-code namespace and the pending scan must be shared by both.
    companion object {
        @Volatile private var hooks: OrielAndroidHooksContext? = null
        @Volatile private var scan: CompletableFuture<String?>? = null
    }

    override fun onRegistered(context: OrielAndroidHooksContext) { hooks = context }
    override fun onActivityResumed(activity: Activity) {
        if (comparisonWindow()) return
        val engine = SyncEngine.get(activity)
        engine.foreground = true
        engine.discover()
        engine.queueWork()
    }
    override fun onLoad(ctx: OrielExtensionContext) {
        if (comparisonWindow()) return
        context = ctx
        val engine = SyncEngine.get(ctx.context)
        engine.foreground = ctx.activity != null
        engine.listener = { changed -> ctx.emit("sync", JSONObject().put("changed", changed).toString().toByteArray()) }
    }
    override fun onLifecycle(event: String, level: String?) {
        if (comparisonWindow()) return
        val ctx = context ?: return
        if (event == "foreground" || event == "background") {
            val engine = SyncEngine.get(ctx.context)
            engine.foreground = event == "foreground"
            if (engine.foreground) { engine.discover(); engine.queueWork() }
        }
    }
    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != hooks?.requestCode(1)) return false
        scan?.complete(if (resultCode == Activity.RESULT_OK) data?.getStringExtra("SCAN_RESULT") else null)
        scan = null
        return true
    }

    override fun call(method: String, input: ByteArray, call: OrielCall): ByteArray {
        check(!comparisonWindow()) { "OpenPrimaryWindowForSync" }
        val args = JSONObject(String(input, Charsets.UTF_8))
        val engine = SyncEngine.get(call.context)
        try {
            val result = when (method) {
                "status" -> engine.status()
                "pair_link" -> engine.pair(args.getString("link"), args.optBoolean("replace"))
                "scan_pair" -> {
                    val activity = call.activity ?: throw IllegalStateException("OpenApplicationToPair")
                    val requestCode = hooks?.requestCode(1) ?: throw IllegalStateException("ScannerUnavailable")
                    val waiting = CompletableFuture<String?>()
                    check(scan == null) { "ScannerAlreadyOpen" }
                    scan = waiting
                    call.runOnUi {
                        // An exception here would crash the UI thread; report it to the caller instead.
                        try {
                            val intent = IntentIntegrator(activity).setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
                                .setPrompt("Scan the pairing QR shown by Penny Goblin on your desktop")
                                .setOrientationLocked(false).setBeepEnabled(false).createScanIntent()
                            activity.startActivityForResult(intent, requestCode)
                        } catch (error: Exception) {
                            waiting.completeExceptionally(IllegalStateException("ScannerUnavailable"))
                        }
                    }
                    val link = try { waiting.get(180, TimeUnit.SECONDS) }
                        catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
                        finally { scan = null }
                    if (link == null) JSONObject().put("cancelled", true) else engine.pair(link, args.optBoolean("replace"))
                }
                "sync_now" -> { engine.synchronize(); engine.status() }
                "unpair" -> engine.unpair()
                "research" -> engine.research(args)
                "scan" -> engine.scan(args.getString("data_url"))
                else -> throw IllegalStateException("UnknownSyncAction")
            }
            return result.toString().toByteArray(Charsets.UTF_8)
        } catch (error: Exception) {
            val allowed = setOf("DifferentPairedDesktop", "InvalidPairingCode", "InvalidDesktopAddress", "DesktopUnavailableOrIdentityMismatch",
                "PairingExpiredOrInvalid", "PairingRateLimited", "PairingNeedsRepair", "DeviceNotAuthorized", "CredentialSaveFailed", "OpenApplicationToPair", "ScannerUnavailable", "ScannerAlreadyOpen",
                "ResearchJobNotFound", "ResearchNotReady", "ResearchJobsFull", "InvalidSelection", "InvalidResearchAction", "RevisionConflict", "SettingsConflict", "CategorizationModelRequired", "DesktopResearchUnavailable", "NoCategories",
                "NotPaired", "DesktopUnavailable", "DesktopScannerBusy", "ScannerNotSetUp", "ModelNotDownloaded", "ModelNotImported", "SystemModelNotReady")
            val code = error.message.takeIf { it in allowed } ?: "SyncActionFailed"
            // Class and location only: messages may contain pairing material.
            if (code == "SyncActionFailed") android.util.Log.w("PennySync", "$method failed: ${error.javaClass.name} at ${error.stackTrace.firstOrNull { it.className.startsWith("com.pennygoblin") }}")
            throw OrielExtensionError(code, code)
        }
    }
}
