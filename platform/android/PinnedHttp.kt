package com.pennygoblin.sync

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

object PinnedHttp {
    const val MAX_BYTES = 64 * 1024 * 1024

    fun validEndpoint(endpoint: String): Boolean = try {
        val uri = URI(endpoint)
        uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.rawUserInfo == null &&
            (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/") && uri.rawQuery == null && uri.rawFragment == null &&
            (uri.port == -1 || uri.port in 1..65535) && endpoint.length <= 2048
    } catch (_: Exception) { false }

    fun post(endpoint: String, route: String, body: JSONObject, pin: String, token: String? = null, readTimeoutMs: Int = 90000): JSONObject {
        require(validEndpoint(endpoint) && Regex("[0-9a-f]{64}").matches(pin)) { "InvalidDesktopAddress" }
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) { throw CertificateException("Unsupported") }
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty()) throw CertificateException("DesktopIdentityMismatch")
                chain[0].checkValidity()
                val digest = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded).joinToString("") { "%02x".format(it) }
                if (!MessageDigest.isEqual(digest.toByteArray(Charsets.US_ASCII), pin.toByteArray(Charsets.US_ASCII))) throw CertificateException("DesktopIdentityMismatch")
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf<TrustManager>(trust), SecureRandom()) }
        val connection = URI(endpoint.trimEnd('/') + route).toURL().openConnection() as HttpsURLConnection
        // Routing names can change between LAN and Tailscale. Identity is the
        // exact certificate pin checked during TLS, before any token is sent.
        connection.sslSocketFactory = tls.socketFactory
        connection.setHostnameVerifier { _, _ -> true }
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 4000
        connection.readTimeout = readTimeoutMs
        connection.requestMethod = "POST"
        connection.setRequestProperty("Content-Type", "application/json")
        if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
        val bytes = body.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX_BYTES) { "SyncPayloadTooLarge" }
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(bytes.size)
        try {
            connection.outputStream.use { it.write(bytes) }
            val status = connection.responseCode
            if (status == 401 || status == 403) throw IllegalStateException("DeviceNotAuthorized")
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val output = ByteArrayOutputStream()
            stream?.use {
                val buffer = ByteArray(8192)
                while (true) {
                    val length = it.read(buffer)
                    if (length < 0) break
                    if (output.size() + length > MAX_BYTES) throw IllegalStateException("SyncPayloadTooLarge")
                    output.write(buffer, 0, length)
                }
            }
            val reply = JSONObject(output.toString("UTF-8"))
            if (status !in 200..299) throw IllegalStateException(reply.optString("error", "RequestRejected"))
            return reply
        } finally { connection.disconnect() }
    }
}
