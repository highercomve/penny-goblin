package com.pennygoblin.sync

import android.content.Context
import java.io.File
import org.json.JSONObject

object NativeSync {
    init { System.loadLibrary("oriel") }
    private external fun request(database: ByteArray, input: ByteArray): ByteArray

    fun call(context: Context, input: JSONObject): JSONObject {
        val path = File(context.filesDir, "ledger.sqlite3").absolutePath.toByteArray(Charsets.UTF_8)
        val value = JSONObject(String(request(path, input.toString().toByteArray(Charsets.UTF_8)), Charsets.UTF_8))
        if (!value.optBoolean("ok")) {
            android.util.Log.w("PennySync", "${input.optString("action")}: ${value.optString("err")} ${value.optString("detail").take(120)}")
            throw IllegalStateException(value.optString("err", "SyncFailed"))
        }
        return value.getJSONObject("value")
    }
}
