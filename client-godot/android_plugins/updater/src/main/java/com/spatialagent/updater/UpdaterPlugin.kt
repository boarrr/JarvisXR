package com.spatialagent.updater

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.app.PendingIntent
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File
import java.io.FileInputStream

/**
 * Godot Android plugin that installs a downloaded APK through the platform
 * PackageInstaller session API. Horizon OS does not resolve ACTION_VIEW for
 * APKs, so a session commit (which still shows the system confirmation) is the
 * supported path. The app must hold REQUEST_INSTALL_PACKAGES.
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
                val installer = host.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL
                )
                val sessionId = installer.createSession(params)
                installer.openSession(sessionId).use { session ->
                    FileInputStream(file).use { input ->
                        session.openWrite("base.apk", 0L, file.length()).use { output ->
                            input.copyTo(output)
                            session.fsync(output)
                        }
                    }
                    val callback = Intent(host, UpdaterInstallReceiver::class.java)
                    val pending = PendingIntent.getBroadcast(
                        host,
                        sessionId,
                        callback,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    session.commit(pending.intentSender)
                }
                activeInstance = this
                emitSignal("install_result", true, "session_committed")
            } catch (error: Exception) {
                emitSignal("install_result", false, error.message ?: "install_failed")
            }
        }
    }

    fun reportInstall(success: Boolean, message: String) {
        emitSignal("install_result", success, message)
    }

    companion object {
        var activeInstance: UpdaterPlugin? = null
    }
}

class UpdaterInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()
        val success = status == PackageInstaller.STATUS_SUCCESS
        val label = if (message.isNotEmpty()) message else "status_$status"
        UpdaterPlugin.activeInstance?.reportInstall(success, label)
    }
}
