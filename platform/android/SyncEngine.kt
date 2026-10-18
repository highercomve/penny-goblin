package com.pennygoblin.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import androidx.work.*
import org.json.JSONObject
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock

class SyncEngine private constructor(private val context: Context) {
    private val credentials = Credentials(context)
    private val prefs = context.getSharedPreferences("penny-sync-status", Context.MODE_PRIVATE)
    private val lock = ReentrantLock()
    private val executor = Executors.newSingleThreadScheduledExecutor()
    @Volatile var foreground = false
    @Volatile var listener: ((Boolean) -> Unit)? = null
    @Volatile private var lastError = ""
    @Volatile private var lastConnection = 0L
    @Volatile private var discovered: String? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private val resolving = AtomicBoolean(false)
    /** The user's pairing or disconnect waits for the lock: a sync in flight gives it up between routes. */
    private val userWaiting = AtomicBoolean(false)

    init {
        scheduleWork()
        (context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { queueWork(); executor.execute { discover(); synchronize() } }
            override fun onLost(network: Network) { lastConnection = 0 }
        })
        executor.scheduleWithFixedDelay({ if (foreground) { discover(); synchronize() } }, 3, 5, TimeUnit.SECONDS)
    }

    fun status(): JSONObject {
        val result = NativeSync.call(context, JSONObject().put("action", "status"))
        val paired = try { credentials.load() != null } catch (_: Exception) { lastError = "PairingNeedsRepair"; false }
        return result.put("paired", paired).put("connected", paired && System.currentTimeMillis() - lastConnection < 20000)
            .put("busy", lock.isLocked).put("error", lastError).put("endpoint", prefs.getString("endpoint", ""))
    }

    fun pair(pasted: String, replace: Boolean): JSONObject {
        require(pasted.length <= 8192) { "InvalidPairingCode" }
        // Copying a long link from chat or notes can insert line breaks or spaces.
        val link = pasted.filterNot { it.isWhitespace() }
        val uri = android.net.Uri.parse(link)
        // Schemes and hosts are case-insensitive; keyboards may capitalize pasted links.
        require(uri.scheme.equals("pennygoblin", true) && uri.host.equals("pair", true)) { "InvalidPairingCode" }
        val raw = uri.getQueryParameter("data") ?: throw IllegalArgumentException("InvalidPairingCode")
        val code = try {
            val decoded = Base64.decode(raw, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            require(decoded.size <= 4096)
            JSONObject(String(decoded, Charsets.UTF_8))
        } catch (error: Exception) { throw IllegalArgumentException("InvalidPairingCode") } // Truncated or altered link.
        val serverId = code.getString("server_id")
        val pin = code.getString("pin")
        val secret = code.getString("secret")
        val endpoints = code.getJSONArray("endpoints")
        require(code.getInt("version") == 1 && Regex("[0-9a-f]{64}").matches(serverId) && Regex("[0-9a-f]{64}").matches(pin) &&
            Regex("[A-Za-z0-9_-]{43}").matches(secret) && endpoints.length() in 1..8) { "InvalidPairingCode" }
        for (index in 0 until endpoints.length()) require(PinnedHttp.validEndpoint(endpoints.getString(index))) { "InvalidDesktopAddress" }
        lockAhead()
        try {
            val local = NativeSync.call(context, JSONObject().put("action", "status"))
            val old = local.getString("server_id")
            if (old.isNotEmpty() && old != serverId && !replace) throw IllegalStateException("DifferentPairedDesktop")
            var response: JSONObject? = null
            var used = ""
            val pending = credentials.pending()
            val token = if (pending?.optString("server_id") == serverId && pending.optString("secret") == secret) pending.getString("token") else {
                val random = ByteArray(32).also { SecureRandom().nextBytes(it) }
                local.getString("device_id") + "." + Base64.encodeToString(random, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            }
            credentials.savePending(JSONObject().put("server_id", serverId).put("secret", secret).put("token", token))
            val tokenHash = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
            for (index in 0 until endpoints.length()) {
                try {
                    val endpoint = endpoints.getString(index)
                    response = PinnedHttp.post(endpoint, "/v1/pair", JSONObject().put("device_id", local.getString("device_id"))
                        .put("secret", secret).put("token_hash", tokenHash).put("label", Build.MODEL.take(80)), pin)
                    used = endpoint
                    break
                } catch (error: Exception) {
                    if (error.message in setOf("PairingExpiredOrInvalid", "PairingRateLimited")) throw error
                }
            }
            val paired = response ?: throw IllegalStateException("DesktopUnavailableOrIdentityMismatch")
            require(paired.getString("server_id") == serverId && paired.getBoolean("credential_ack")) { "WrongDesktopIdentity" }
            NativeSync.call(context, JSONObject().put("action", if (old.isNotEmpty() && old != serverId) "recover" else "pair").put("server_id", serverId))
            credentials.save(JSONObject().put("server_id", serverId).put("pin", pin).put("endpoints", endpoints).put("token", token))
            credentials.clearPending()
            prefs.edit().putString("endpoint", used).apply()
            lastError = ""; lastConnection = System.currentTimeMillis()
        } finally { lock.unlock() }
        queueWork(); executor.execute { synchronize() }
        return status()
    }

    /** The lock for the user's action: a sync with an unreachable desktop
     *  (seconds per route) stops at its next route instead of going first. */
    private fun lockAhead() {
        userWaiting.set(true)
        try { lock.lock() } finally { userWaiting.set(false) }
    }

    fun unpair(): JSONObject {
        lockAhead()
        try { credentials.clear(); lastConnection = 0; lastError = "" }
        finally { lock.unlock() }
        return status() // Local records and outgoing intent are retained.
    }

    /**
     * A voucher read by the paired desktop's scanner (its model is far faster
     * than the phone's), over the same pinned connection as sync. Only when
     * the desktop answered in the last seconds: otherwise the phone scans at
     * once instead of waiting on routes that don't answer.
     */
    fun scan(dataUrl: String): JSONObject {
        val config = credentials.load() ?: throw IllegalStateException("NotPaired")
        if (System.currentTimeMillis() - lastConnection > 20000) throw IllegalStateException("DesktopUnavailable")
        val body = JSONObject().put("device_id", NativeSync.call(context, JSONObject().put("action", "status")).getString("device_id")).put("data_url", dataUrl)
        val routes = linkedSetOf<String>()
        prefs.getString("endpoint", null)?.let { if (PinnedHttp.validEndpoint(it)) routes.add(it) }
        discovered?.let { routes.add(it) }
        for (route in routes) {
            try {
                return PinnedHttp.post(route, "/v1/scan", body, config.getString("pin"), config.getString("token"), readTimeoutMs = 300000).getJSONObject("extraction")
            } catch (error: java.io.IOException) {
                continue // This route didn't answer: the next one.
            }
        }
        throw IllegalStateException("DesktopUnavailable")
    }

    /** Small idempotent job requests, over the existing pinned paired transport. */
    fun research(args: JSONObject): JSONObject {
        val config = credentials.load() ?: throw IllegalStateException("NotPaired")
        val body = JSONObject(args.toString()).put("device_id", NativeSync.call(context, JSONObject().put("action", "status")).getString("device_id"))
        val routes = linkedSetOf<String>()
        prefs.getString("endpoint", null)?.let { if (PinnedHttp.validEndpoint(it)) routes.add(it) }
        discovered?.let { routes.add(it) }
        val known = config.getJSONArray("endpoints")
        for (index in 0 until known.length()) routes.add(known.getString(index))
        for (route in routes) {
            try {
                val result = PinnedHttp.post(route, "/v1/research", body, config.getString("pin"), config.getString("token"))
                prefs.edit().putString("endpoint", route).apply()
                lastConnection = System.currentTimeMillis()
                if (args.optString("action") == "apply") synchronize()
                return result
            } catch (error: java.io.IOException) { continue }
            catch (error: IllegalStateException) {
                if (error.message == "NotFound") throw IllegalStateException("DesktopResearchUnavailable")
                throw error
            }
        }
        throw IllegalStateException("DesktopUnavailable")
    }

    fun synchronize(): Boolean {
        if (!lock.tryLock()) return true
        var changed = false
        try {
            val config = credentials.load() ?: return true
            if (NativeSync.call(context, JSONObject().put("action", "status")).getString("server_id") != config.getString("server_id")) throw IllegalStateException("PairingNeedsRepair")
            for (round in 0 until 64) {
                val request = NativeSync.call(context, JSONObject().put("action", "prepare"))
                val routes = linkedSetOf<String>()
                prefs.getString("endpoint", null)?.let { if (PinnedHttp.validEndpoint(it)) routes.add(it) }
                discovered?.let { routes.add(it) }
                val known = config.getJSONArray("endpoints")
                for (index in 0 until known.length()) routes.add(known.getString(index))
                var response: JSONObject? = null
                for (route in routes) {
                    if (userWaiting.get()) return true // Retried after the user's action.
                    try {
                        response = PinnedHttp.post(route, "/v1/sync", request, config.getString("pin"), config.getString("token"))
                        prefs.edit().putString("endpoint", route).apply(); break
                    } catch (error: Exception) {
                        if (error.message == "DeviceNotAuthorized") throw error
                        if (error.message == "SyncRecoveryRequired") {
                            NativeSync.call(context, JSONObject().put("action", "recover").put("server_id", config.getString("server_id")))
                            lastError = "RecoveryQueued"; return false
                        }
                    }
                }
                val reply = response ?: throw IllegalStateException("DesktopUnavailableOrIdentityMismatch")
                require(reply.getString("server_id") == config.getString("server_id")) { "WrongDesktopIdentity" }
                changed = changed || request.getJSONArray("operations").length() > 0 || reply.getJSONArray("changes").length() > 0
                NativeSync.call(context, JSONObject().put("action", "consume").put("reply", reply))
                lastConnection = System.currentTimeMillis(); lastError = ""
                val pending = NativeSync.call(context, JSONObject().put("action", "status"))
                if (!reply.getBoolean("more") && pending.getLong("pending") <= pending.getJSONArray("conflicts").length()) break
            }
            return true
        } catch (error: Exception) {
            lastConnection = 0
            // Codes and class only; sync errors never carry credentials or record contents.
            android.util.Log.w("PennySync", "sync failed: ${error.javaClass.simpleName} ${error.message?.take(80)} at ${error.stackTrace.firstOrNull { it.className.startsWith("com.pennygoblin") }}")
            lastError = when (error.message) {
                "DeviceNotAuthorized" -> "DeviceNotAuthorized"
                "PairingNeedsRepair" -> "PairingNeedsRepair"
                else -> "DesktopUnavailableOrSyncFailed"
            }
            return false
        } finally { lock.unlock(); if (changed) listener?.invoke(true) } // The page reloads only on change.
    }

    private fun scheduleWork() {
        val work = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES).setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork("penny-sync-periodic", ExistingPeriodicWorkPolicy.KEEP, work)
    }
    fun queueWork() {
        val work = OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
        WorkManager.getInstance(context).enqueueUniqueWork("penny-sync-now", ExistingWorkPolicy.KEEP, work)
    }

    @Synchronized fun discover() {
        val config = try { credentials.load() } catch (_: Exception) { null } ?: return
        if (discovery != null) return
        val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val handler = Handler(Looper.getMainLooper())
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) { discovery = null }
            override fun onStartDiscoveryFailed(type: String, code: Int) { discovery = null }
            override fun onStopDiscoveryFailed(type: String, code: Int) { discovery = null }
            override fun onServiceLost(service: NsdServiceInfo) {}
            override fun onServiceFound(service: NsdServiceInfo) {
                if (!service.serviceName.startsWith("PennyGoblin-") || !resolving.compareAndSet(false, true)) return
                try {
                    manager.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(service: NsdServiceInfo, code: Int) { resolving.set(false) }
                        override fun onServiceResolved(service: NsdServiceInfo) {
                            resolving.set(false)
                            if (service.attributes["id"]?.toString(Charsets.UTF_8) != config.getString("server_id")) return
                            val host = service.host?.hostAddress ?: return
                            val route = URI("https", null, host, service.port, null, null, null).toString()
                            if (PinnedHttp.validEndpoint(route)) discovered = route
                        }
                    })
                } catch (_: Exception) { resolving.set(false) }
            }
        }
        discovery = listener
        try { manager.discoverServices("_pennygoblin._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
        catch (_: Exception) { discovery = null }
        handler.postDelayed({ if (!foreground && discovery === listener) { try { manager.stopServiceDiscovery(listener) } catch (_: Exception) {}; discovery = null } }, 20000)
    }

    companion object {
        @Volatile private var instance: SyncEngine? = null
        fun get(context: Context): SyncEngine = instance ?: synchronized(this) {
            instance ?: SyncEngine(context.applicationContext).also { instance = it }
        }
    }
}

class SyncWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val engine = SyncEngine.get(applicationContext)
        engine.discover()
        val success = engine.synchronize()
        return if (success || engine.status().optString("error") in setOf("DeviceNotAuthorized", "PairingNeedsRepair")) Result.success() else Result.retry()
    }
}
