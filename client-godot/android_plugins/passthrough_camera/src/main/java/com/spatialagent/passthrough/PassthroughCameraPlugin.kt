package com.spatialagent.passthrough

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import androidx.core.content.ContextCompat
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot

/**
 * exposes the Horizon OS passthrough cameras to Godot via Camera2.
 *
 * Requires the HEADSET_CAMERA permission. The GDScript polls [hasPermission]
 * after calling [requestPermission], then calls [start]; frames are read from
 * [frameJpeg] as JPEG bytes (decoding happens on the daemon).
 */
class PassthroughCameraPlugin(godot: Godot) : GodotPlugin(godot) {

    private val tag = "PassthroughCamera"
    private val headsetPermission = "horizonos.permission.HEADSET_CAMERA"

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null

    @Volatile
    private var lastJpeg: ByteArray = ByteArray(0)
    @Volatile
    private var loggedFirstFrame = false

    override fun getPluginName(): String = "PassthroughCamera"

    private fun cameraManager(): CameraManager? {
        val host = activity ?: return null
        return host.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
    }

    @UsedByGodot
    fun hasPermission(): Boolean {
        val host = activity ?: return false
        return ContextCompat.checkSelfPermission(host, headsetPermission) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(host, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    @UsedByGodot
    fun requestPermission() {
        val host = activity ?: return
        host.requestPermissions(arrayOf(headsetPermission, Manifest.permission.CAMERA), 8431)
    }

    @UsedByGodot
    fun cameraCount(): Int {
        return try {
            cameraManager()?.cameraIdList?.size ?: 0
        } catch (error: Exception) {
            0
        }
    }

    @UsedByGodot
    fun isOpen(): Boolean = device != null

    @UsedByGodot
    fun start() {
        val host = activity ?: return
        val manager = cameraManager() ?: return
        if (device != null) return
        if (!hasPermission()) {
            requestPermission()
            return
        }
        val background = HandlerThread("passthrough-camera").also { it.start() }
        thread = background
        handler = Handler(background.looper)
        for (id in orderedCameras(manager)) {
            try {
                val characteristics = manager.getCameraCharacteristics(id)
                val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                val sizes = map?.getOutputSizes(ImageFormat.JPEG)
                Log.i(tag, "camera $id JPEG sizes: ${sizes?.joinToString { "${it.width}x${it.height}" }}")
                // Prefer the largest size up to 1280 wide so a QR is legible.
                val size: Size = sizes?.filter { it.width <= 1280 }?.maxByOrNull { it.width * it.height }
                    ?: sizes?.maxByOrNull { it.width * it.height }
                    ?: Size(640, 480)
                val imageReader = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
                imageReader.setOnImageAvailableListener({ source ->
                    source.acquireLatestImage()?.use { image ->
                        val buffer = image.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        lastJpeg = bytes
                        if (!loggedFirstFrame) {
                            loggedFirstFrame = true
                            Log.i(tag, "first frame ${bytes.size} bytes")
                        }
                    }
                }, handler)
                reader = imageReader
                Log.i(tag, "opening camera $id at ${size.width}x${size.height}")
                manager.openCamera(id, stateCallback, handler)
                return
            } catch (error: SecurityException) {
                Log.w(tag, "no permission for camera $id: ${error.message}")
            } catch (error: Exception) {
                Log.w(tag, "camera $id failed: ${error.message}")
            }
        }
        Log.e(tag, "no openable camera among ${manager.cameraIdList.joinToString()}")
    }

    private fun orderedCameras(manager: CameraManager): List<String> {
        val preferred = mutableListOf<String>()
        val rest = mutableListOf<String>()
        for (id in manager.cameraIdList) {
            val facing = manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_FRONT ||
                facing == CameraCharacteristics.LENS_FACING_EXTERNAL
            ) {
                preferred.add(id)
            } else {
                rest.add(id)
            }
        }
        return preferred + rest
    }

    private val stateCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(camera: CameraDevice) {
            device = camera
            Log.i(tag, "camera ${camera.id} opened")
            val surface = reader?.surface ?: return
            try {
                camera.createCaptureSession(
                    listOf(surface),
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(configured: CameraCaptureSession) {
                            session = configured
                            Log.i(tag, "capture session configured")
                            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                addTarget(surface)
                                set(
                                    CaptureRequest.CONTROL_AF_MODE,
                                    CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE,
                                )
                            }
                            configured.setRepeatingRequest(request.build(), null, handler)
                        }

                        override fun onConfigureFailed(failed: CameraCaptureSession) {
                            Log.e(tag, "capture session configure failed")
                        }
                    },
                    handler,
                )
            } catch (error: Exception) {
                Log.e(tag, "createCaptureSession failed", error)
            }
        }

        override fun onDisconnected(camera: CameraDevice) {
            camera.close()
            device = null
        }

        override fun onError(camera: CameraDevice, error: Int) {
            Log.e(tag, "camera error $error")
            camera.close()
            device = null
        }
    }

    @UsedByGodot
    fun stop() {
        try { session?.close() } catch (_: Exception) {}
        try { device?.close() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        session = null
        device = null
        reader = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    @UsedByGodot
    fun frameJpeg(): ByteArray = lastJpeg

    override fun onMainDestroy() {
        stop()
    }
}
