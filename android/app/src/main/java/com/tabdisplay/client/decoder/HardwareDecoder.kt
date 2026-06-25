package com.tabdisplay.client.decoder

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import kotlin.concurrent.thread

class HardwareDecoder {
    private var codec: MediaCodec? = null
    private var drainThread: Thread? = null
    private var isRunning = false

    fun initialize(surface: Surface, width: Int, height: Int) {
        release()
        isRunning = true
        
        try {
            println("Initializing hardware MediaCodec decoder for ${width}x${height}")
            val format = MediaFormat.createVideoFormat("video/avc", width, height)
            
            // Set latency configurations to zero/low-latency
            format.setInteger(MediaFormat.KEY_LATENCY, 0)
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            
            val avcCodec = MediaCodec.createDecoderByType("video/avc")
            avcCodec.configure(format, surface, null, 0)
            avcCodec.start()
            codec = avcCodec

            // Spawn background thread to drain output buffers
            drainThread = thread(name = "MediaCodec-Drainer") {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY)
                val info = MediaCodec.BufferInfo()
                while (isRunning) {
                    try {
                        val activeCodec = codec ?: break
                        val index = activeCodec.dequeueOutputBuffer(info, 10000)
                        if (index >= 0) {
                            // Release buffer and render directly to bound OpenGL EGL Surface
                            activeCodec.releaseOutputBuffer(index, true)
                        } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            println("HardwareDecoder: Output format changed: ${activeCodec.outputFormat}")
                        }
                    } catch (e: Exception) {
                        if (isRunning) {
                            println("HardwareDecoder output loop error: ${e.message}")
                        }
                        break
                    }
                }
            }
        } catch (e: Exception) {
            println("Failed to initialize MediaCodec hardware decoder: ${e.message}")
            release()
        }
    }

    fun decodeBuffer(data: ByteArray, timestampMs: Long) {
        try {
            val activeCodec = codec ?: return
            val index = activeCodec.dequeueInputBuffer(10000)
            if (index >= 0) {
                val inputBuffer = activeCodec.getInputBuffer(index)
                if (inputBuffer != null) {
                    inputBuffer.clear()
                    inputBuffer.put(data)
                    // MediaCodec requires microseconds (Us) for presentation time
                    activeCodec.queueInputBuffer(
                        index,
                        0,
                        data.size,
                        timestampMs * 1000L,
                        0
                    )
                }
            }
        } catch (e: Exception) {
            println("HardwareDecoder input enqueue error: ${e.message}")
        }
    }

    fun release() {
        isRunning = false
        drainThread?.interrupt()
        drainThread = null
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {}
        codec = null
    }
}
