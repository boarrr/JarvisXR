package com.spatialagent.updater

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File

/**
 * Godot Android plugin that hands a downloaded APK to the system package
 * installer. GDScript writes the verified APK under user://updates/ and calls
 * installApk(); the OS shows its normal install confirmation.
 *
 * The plugin never downloads anything and never installs silently: Android
 * requires the user to confirm, and the app must hold REQUEST_INSTALL_PACKAGES.
 */
class UpdaterPlugin(godot: Godot) : GodotPlugin(godot) {

    override fun getPluginName(): String = "AndroidUpdater"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("install_result", Boolean::class.java, String::class.java),
    )

    @UsedByGodot
    fun canRequestPackageInstalls(): Boolean {
        val host = activity ?: return false
        return host.packageManager.canRequestPackageInstalls()
    }

    @UsedByGodot
    fun installApk(path: String) {
        val host = activity ?: run {
            emitSignal("install_result", false, "no_activity")
            return
        }
        host.runOnUiThread {
            try {
                val file = File(path)
                if (!file.exists() || !file.name.endsWith(".apk")) {
                    emitSignal("install_result", false, "missing_apk")
                    return@runOnUiThread
                }
                val authority = "${host.packageName}.updater"
                val uri: Uri = FileProvider.getUriForFile(host, authority, file)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                host.startActivity(intent)
                emitSignal("install_result", true, "installer_opened")
            } catch (error: Exception) {
                emitSignal("install_result", false, error.message ?: "install_failed")
            }
        }
    }
}
