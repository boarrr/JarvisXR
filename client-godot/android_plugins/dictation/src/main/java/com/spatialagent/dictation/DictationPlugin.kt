package com.spatialagent.dictation

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo

/**
 * Minimal Godot Android plugin exposing on-device dictation.
 *
 * GDScript calls startDictation()/stopDictation()/cancelDictation() and listens
 * for partial_transcript, final_transcript, and dictation_failed signals.
 * Audio never leaves the operating system speech service; only finalized text
 * reaches the game and then the protocol boundary.
 */
class DictationPlugin(godot: Godot) : GodotPlugin(godot) {

    private var recognizer: SpeechRecognizer? = null

    override fun getPluginName(): String = "AndroidDictation"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("partial_transcript", String::class.java),
        SignalInfo("final_transcript", String::class.java),
        SignalInfo("dictation_failed", String::class.java, String::class.java),
    )

    @Suppress("unused")
    fun startDictation() {
        val host = activity ?: return
        host.runOnUiThread {
            if (!SpeechRecognizer.isRecognitionAvailable(host)) {
                emitSignal(
                    "dictation_failed",
                    "dictation_unavailable",
                    "No on-device speech recognition service is available",
                )
                return@runOnUiThread
            }
            val instance = recognizer ?: SpeechRecognizer.createSpeechRecognizer(host).also {
                it.setRecognitionListener(listener)
                recognizer = it
            }
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                )
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
            instance.startListening(intent)
        }
    }

    @Suppress("unused")
    fun stopDictation() {
        activity?.runOnUiThread { recognizer?.stopListening() }
    }

    @Suppress("unused")
    fun cancelDictation() {
        activity?.runOnUiThread { recognizer?.cancel() }
    }

    private val listener = object : RecognitionListener {
        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?: return
            emitSignal("partial_transcript", text)
        }

        override fun onResults(results: Bundle?) {
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                .orEmpty()
            emitSignal("final_transcript", text)
        }

        override fun onError(error: Int) {
            emitSignal(
                "dictation_failed",
                "dictation_error",
                "Speech recognizer error $error",
            )
        }

        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    override fun onMainDestroy() {
        recognizer?.destroy()
        recognizer = null
        super.onMainDestroy()
    }
}
