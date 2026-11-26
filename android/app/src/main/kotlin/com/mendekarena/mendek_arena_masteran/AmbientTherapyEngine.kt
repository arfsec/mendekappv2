package com.mendekarena.mendek_arena_masteran

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.sin
import kotlin.random.Random

object AmbientTherapyEngine {
    @Volatile
    private var running = false

    @Volatile
    private var currentMode = "none"

    @Volatile
    private var volumeGain = 0.2f

    private var workerThread: Thread? = null
    private var audioTrack: AudioTrack? = null

    fun start(mode: String, volumePct: Int) {
        val normalized = mode.trim().lowercase()
        if (normalized == "none" || normalized.isEmpty()) {
            stop()
            return
        }
        setVolume(volumePct)
        if (running && currentMode == normalized) {
            return
        }
        stop()

        currentMode = normalized
        running = true

        val sampleRate = 22050
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(2048)

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .build()

        val track = try {
            AudioTrack(
                attrs,
                format,
                minBuf * 2,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE
            )
        } catch (_: Exception) {
            running = false
            return
        }

        audioTrack = track
        try {
            track.play()
        } catch (_: Exception) {
            running = false
            try {
                track.release()
            } catch (_: Exception) {
            }
            audioTrack = null
            return
        }

        val t = Thread {
            val chunkSamples = 1024
            val pcm = ShortArray(chunkSamples)
            val rng = Random(System.currentTimeMillis())
            var lp1 = 0.0
            var lp2 = 0.0
            var sampleIndex = 0L

            while (running) {
                val modeSnap = currentMode
                val gain = volumeGain

                for (i in 0 until chunkSamples) {
                    val sec = sampleIndex.toDouble() / sampleRate.toDouble()
                    val white = rng.nextDouble() * 2.0 - 1.0

                    val rawSample = when (modeSnap) {
                        "water" -> {
                            // Low-pass filtered babbling stream with soft wave modulation
                            lp1 = lp1 * 0.92 + white * 0.08
                            lp2 = lp2 * 0.85 + lp1 * 0.15
                            val swell = 0.65 + 0.35 * sin(2.0 * PI * 0.28 * sec)
                            val bubble = 0.18 * sin(2.0 * PI * (420.0 + 180.0 * sin(2.0 * PI * 1.4 * sec)) * sec) *
                                (0.5 + 0.5 * sin(2.0 * PI * 3.1 * sec))
                            (lp2 * 2.2 * swell + bubble) * 0.45
                        }

                        "rain" -> {
                            // Warm soothing pink-like rain drizzle
                            lp1 = lp1 * 0.86 + white * 0.14
                            lp2 = lp2 * 0.72 + lp1 * 0.28
                            val swell = 0.8 + 0.2 * sin(2.0 * PI * 0.12 * sec)
                            lp2 * 1.6 * swell * 0.42
                        }

                        else -> {
                            // Forest breeze + subtle morning shimmer
                            lp1 = lp1 * 0.94 + white * 0.06
                            val breeze = 0.55 + 0.45 * sin(2.0 * PI * 0.15 * sec)
                            val harmonic = 0.12 * sin(2.0 * PI * 528.0 * sec) *
                                (0.5 + 0.5 * sin(2.0 * PI * 0.35 * sec))
                            (lp1 * 1.8 * breeze + harmonic) * 0.38
                        }
                    }

                    val scaled = (rawSample * gain * 32767.0).toInt().coerceIn(-32000, 32000)
                    pcm[i] = scaled.toShort()
                    sampleIndex++
                }

                if (!running) break
                try {
                    track.write(pcm, 0, chunkSamples)
                } catch (_: Exception) {
                    break
                }
            }
        }
        t.isDaemon = true
        t.start()
        workerThread = t
    }

    fun setVolume(volumePct: Int) {
        val clamped = volumePct.coerceIn(0, 100)
        volumeGain = (clamped / 100.0f) * 0.85f
    }

    fun stop() {
        running = false
        currentMode = "none"
        try {
            workerThread?.join(250)
        } catch (_: Exception) {
        }
        workerThread = null
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
    }
}
