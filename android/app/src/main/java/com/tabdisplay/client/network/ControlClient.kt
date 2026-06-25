package com.tabdisplay.client.network

import android.os.Handler
import android.os.Looper
import com.tabdisplay.client.proto.*
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.Socket
import kotlin.concurrent.thread

class ControlClient(private val listener: Listener) {

    interface Listener {
        fun onHandshakeResponse(response: HandshakeResponse)
        fun onConnectionClosed(error: String?)
    }

    private var socket: Socket? = null
    private var outStream: DataOutputStream? = null
    private var inStream: DataInputStream? = null
    private var isRunning = false
    private val mainHandler = Handler(Looper.getMainLooper())

    fun connect(host: String, port: Int) {
        disconnect()
        isRunning = true
        thread(name = "ControlClient-Thread") {
            try {
                val sock = Socket(host, port)
                socket = sock
                outStream = DataOutputStream(sock.getOutputStream())
                inStream = DataInputStream(sock.getInputStream())

                println("ControlClient: Connected to $host:$port")

                // Send Handshake Request immediately
                sendHandshakeRequest()

                // Start receive loop
                receiveLoop()
            } catch (e: Exception) {
                println("ControlClient connection error: ${e.message}")
                notifyError(e.message)
            } finally {
                cleanup()
            }
        }
    }

    private fun sendHandshakeRequest() {
        val request = HandshakeRequest.newBuilder()
            .setClientDeviceName(android.os.Build.MODEL)
            .setPreferredWidth(1920)
            .setPreferredHeight(1080)
            .setTargetFps(60)
            .build()

        val packet = ControlPacket.newBuilder()
            .setHandshakeRequest(request)
            .build()

        sendPacket(packet)
    }

    fun sendPacket(packet: ControlPacket) {
        val bytes = packet.toByteArray()
        val length = bytes.size
        thread(name = "ControlClient-Send") {
            synchronized(this) {
                try {
                    val out = outStream ?: return@thread
                    // Write length prefix (4 bytes Big Endian)
                    out.writeInt(length)
                    out.write(bytes)
                    out.flush()
                } catch (e: IOException) {
                    println("ControlClient: Error sending packet: ${e.message}")
                }
            }
        }
    }

    fun sendTelemetry(lossRate: Float, jitterMs: Float, latencyMs: Float) {
        val telemetry = TelemetryFeedback.newBuilder()
            .setPacketLossRate(lossRate)
            .setAverageJitterMs(jitterMs)
            .setEndToEndLatencyMs(latencyMs)
            .build()

        val packet = ControlPacket.newBuilder()
            .setTelemetry(telemetry)
            .build()

        sendPacket(packet)
    }

    fun sendInput(action: InputEvent.ActionType, xPercent: Float, yPercent: Float) {
        val input = InputEvent.newBuilder()
            .setAction(action)
            .setXPercent(xPercent)
            .setYPercent(yPercent)
            .build()

        val packet = ControlPacket.newBuilder()
            .setInputEvent(input)
            .build()

        sendPacket(packet)
    }

    private fun receiveLoop() {
        val stream = inStream ?: return
        while (isRunning) {
            try {
                // Read 4-byte big endian length prefix
                val length = stream.readInt()
                if (length <= 0 || length > 10 * 1024 * 1024) {
                    throw IOException("Invalid packet length: $length")
                }

                val buffer = ByteArray(length)
                stream.readFully(buffer)

                val packet = ControlPacket.parseFrom(buffer)
                handleIncomingPacket(packet)
            } catch (e: Exception) {
                if (isRunning) {
                    println("ControlClient receive error: ${e.message}")
                    notifyError(e.message)
                }
                break
            }
        }
    }

    private fun handleIncomingPacket(packet: ControlPacket) {
        when (packet.payloadCase) {
            ControlPacket.PayloadCase.HANDSHAKE_RESPONSE -> {
                val response = packet.handshakeResponse
                mainHandler.post {
                    listener.onHandshakeResponse(response)
                }
            }
            ControlPacket.PayloadCase.KEEP_ALIVE -> {
                val keepAlive = packet.keepAlive
                // Echo keep-alive packet back to server
                val reply = ControlPacket.newBuilder()
                    .setKeepAlive(keepAlive)
                    .build()
                sendPacket(reply)
            }
            else -> {
                // Ignore other packets or log
            }
        }
    }

    private fun notifyError(error: String?) {
        mainHandler.post {
            listener.onConnectionClosed(error)
        }
    }

    fun disconnect() {
        isRunning = false
        thread(name = "ControlClient-Disconnect") {
            cleanup()
        }
    }

    private fun cleanup() {
        try {
            socket?.close()
        } catch (e: Exception) {}
        socket = null
        outStream = null
        inStream = null
    }
}
