package com.spatialagent.updater

import androidx.core.content.FileProvider

/**
 * Distinct provider class so the Android manifest merger does not clash with
 * Godot's own FileProvider (androidx.core.content.FileProvider, authority
 * "${applicationId}.fileprovider"). Registered under the ".updater" authority.
 */
class UpdaterFileProvider : FileProvider()
