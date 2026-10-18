package com.pennygoblin.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Persistent device credentials never cross the frontend bridge. */
class Credentials(context: Context) {
    private val prefs = context.getSharedPreferences("penny-sync-credentials", Context.MODE_PRIVATE)
    private val alias = "penny-goblin-sync"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(alias, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return generator.generateKey()
    }

    @Synchronized fun load(): JSONObject? = read("")
    @Synchronized fun pending(): JSONObject? = read("pairing-")
    private fun read(prefix: String): JSONObject? {
        val ciphertext = prefs.getString(prefix + "ciphertext", null) ?: return null
        val iv = prefs.getString(prefix + "iv", null) ?: throw IllegalStateException("PairingNeedsRepair")
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            return JSONObject(String(cipher.doFinal(Base64.decode(ciphertext, Base64.NO_WRAP)), Charsets.UTF_8))
        } catch (_: Exception) { throw IllegalStateException("PairingNeedsRepair") }
    }

    @Synchronized fun save(value: JSONObject) = write("", value)
    @Synchronized fun savePending(value: JSONObject) = write("pairing-", value)
    @Synchronized fun clearPending() { check(prefs.edit().remove("pairing-ciphertext").remove("pairing-iv").commit()) }
    private fun write(prefix: String, value: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString(prefix + "ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .putString(prefix + "iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).commit()) { "CredentialSaveFailed" }
    }

    @Synchronized fun clear() { check(prefs.edit().clear().commit()) }
}
