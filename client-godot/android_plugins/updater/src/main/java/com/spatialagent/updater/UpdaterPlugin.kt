package com.spatialagent.updater

import android.content.BroadcastReceiver
import android.util.Log
import androidx.core.content.FileProvider
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

    private val tag = "UpdaterPlugin"

    override fun getPluginName(): String = "AndroidUpdater"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("install_result", Boolean::class.javaObjectType, String::class.java),
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
            val file = File(path)
            if (!file.exists() || !file.name.endsWith(".apk")) {
                emitSignal("install_result", false, "missing_apk")
                return@runOnUiThread
            }
            // Preferred path on Horizon OS: launch the system installer activity
            // directly with a content URI we grant read access to.
            try {
                val uri = FileProvider.getUriForFile(
                    host, "${host.packageName}.updater", file
                )
                val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    setClassName(
                        "com.android.packageinstaller",
                        "com.android.packageinstaller.InstallStart",
                    )
                }
                Log.i(tag, "launching InstallStart for $uri")
                host.startActivity(intent)
                emitSignal("install_result", true, "installer_opened")
                return@runOnUiThread
            } catch (error: Exception) {
                Log.w(tag, "InstallStart failed, falling back to session", error)
            }
            // Fallback: PackageInstaller session commit.
            try {
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
                    val callback = Intent(host, UpdaterInstallReceiver::class.java).apply {
                        action = "com.spatialagent.updater.INSTALL_RESULT"
                    }
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
                Log.e(tag, "install failed", error)
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
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        val keys = intent.extras?.keySet()?.joinToString(",") ?: "none"
        Log.i("UpdaterPlugin", "receiver action=${intent.action} statusKeys=$keys")
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirm: Intent? = intent.getParcelableExtra(Intent.EXTRA_INTENT)
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                Log.i("UpdaterPlugin", "launching install confirmation UI")
                context.startActivity(confirm)
            }
            UpdaterPlugin.activeInstance?.reportInstall(true, "user_action_required")
            return
        }
        val success = status == PackageInstaller.STATUS_SUCCESS
        val label = if (success) "installed" else message.ifEmpty { "install_failed_$status" }
        UpdaterPlugin.activeInstance?.reportInstall(success, label)
    }
}
