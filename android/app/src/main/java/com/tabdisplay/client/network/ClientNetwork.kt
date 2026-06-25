package com.tabdisplay.client.network

import com.tabdisplay.client.decoder.HardwareDecoder
import java.io.IOException
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

class ClientNetwork(private val decoder: HardwareDecoder) {

    // ── UDP Wi-Fi mode ────────────────────────────────────────────────────────
    private var socket: DatagramSocket? = null
    private var isListening = false
    private var pingThread: Thread? = null
    private var receiveThread: Thread? = null

    // ── TCP USB mode ──────────────────────────────────────────────────────────
    private var tcpSocket: Socket? = null
    private var tcpReceiveThread: Thread? = null
    private var isUsbMode = false

    // ── Frame assembly (shared) ───────────────────────────────────────────────
    private val activeFrames = ConcurrentHashMap<Int, FrameAssembly>()
    private var lastProcessedFrameIndex = 0

    // ── Telemetry ─────────────────────────────────────────────────────────────
    private var totalPacketsExpected = 0
    private var totalPacketsReceived = 0
    private var nacksSentCount = 0
    private var lastReceiveTime = 0L
    private var jitterSum = 0L
    private var jitterCount = 0
    private var currentLatencyMs = 0f

    private val sentNacks = ConcurrentHashMap<String, Long>()

    class FrameAssembly(val totalFragments: Int, val timestamp: Long, val isKeyframe: Boolean) {
        val fragmentsReceived = BooleanArray(totalFragments)
        val fragmentsData = Array<ByteArray?>(totalFragments) { null }

        fun isComplete(): Boolean {
            for (received in fragmentsReceived) {
                if (!received) return false
            }
            return true
        }

        fun getAssembledData(): ByteArray {
            var size = 0
            for (frag in fragmentsData) {
                size += frag?.size ?: 0
            }
            val result = ByteArray(size)
            var offset = 0
            for (frag in fragmentsData) {
                if (frag != null) {
                    System.arraycopy(frag, 0, result, offset, frag.size)
                    offset += frag.size
                }
            }
            return result
        }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /** Start in UDP mode (Wi-Fi default). */
    fun startListening(serverIp: String, port: Int) {
        stopListening()
        isUsbMode = false
        isListening = true
        startUdpListening(serverIp, port)
    }

    /** Start in TCP mode (USB ADB tunnel). Connects to 127.0.0.1:port. */
    fun startTcpListening(serverIp: String, port: Int) {
        stopListening()
        isUsbMode = true
        isListening = true
        startTcpReceiver(serverIp, port)
    }

    // ── UDP implementation ────────────────────────────────────────────────────

    private fun startUdpListening(serverIp: String, port: Int) {
        try {
            val sock = DatagramSocket()
            socket = sock
            println("ClientNetwork: UDP socket bound to local port ${sock.localPort}")

            val serverAddress = InetAddress.getByName(serverIp)

            // Periodic registration ping (0xFF) so the server discovers our UDP endpoint
            pingThread = thread(name = "ClientNetwork-Ping") {
                val pingPacket = byteArrayOf(0xFF.toByte())
                val packet = DatagramPacket(pingPacket, pingPacket.size, serverAddress, port)
                while (isListening) {
                    try {
                        sock.send(packet)
                    } catch (e: Exception) {
                        println("ClientNetwork: Error sending ping: ${e.message}")
                    }
                    try {
                        Thread.sleep(250)
                    } catch (ie: InterruptedException) {
                        break
                    }
                }
            }

            receiveThread = thread(name = "ClientNetwork-Receiver") {
                val buffer = ByteArray(65535)
                val packet = DatagramPacket(buffer, buffer.size)

                while (isListening) {
                    try {
                        sock.receive(packet)
                        val now = System.currentTimeMillis()

                        val data = packet.data
                        val length = packet.length

                        if (length < 20) continue

                        val headerBuffer = ByteBuffer.wrap(data, packet.offset, 20)
                        headerBuffer.order(ByteOrder.BIG_ENDIAN)

                        val frameIndex     = headerBuffer.getInt(0)
                        val fragmentIndex  = headerBuffer.getShort(4).toInt()
                        val totalFragments = headerBuffer.getShort(6).toInt()
                        val payloadSize    = headerBuffer.getShort(8).toInt()
                        val frameType      = data[packet.offset + 10]
                        val timestamp      = headerBuffer.getLong(12)

                        if (length < 20 + payloadSize) continue

                        if (pingThread != null) {
                            pingThread?.interrupt()
                            pingThread = null
                            println("ClientNetwork: First video packet received. Stopping UDP ping.")
                        }

                        updateJitter(now)

                        processFragment(
                            frameIndex, fragmentIndex, totalFragments,
                            frameType, timestamp, data, packet.offset + 20, payloadSize,
                            sock, serverAddress, port
                        )
                    } catch (e: Exception) {
                        if (isListening) println("ClientNetwork receiver loop error: ${e.message}")
                        break
                    }
                }
            }

        } catch (e: Exception) {
            println("ClientNetwork: Failed to start UDP listener: ${e.message}")
        }
    }

    // ── TCP implementation (USB mode) ─────────────────────────────────────────

    private fun startTcpReceiver(serverIp: String, port: Int) {
        tcpReceiveThread = thread(name = "ClientNetwork-TCPReceiver") {
            try {
                val sock = Socket(serverIp, port)
                tcpSocket = sock
                println("ClientNetwork: TCP video socket connected to $serverIp:$port (USB mode)")

                val stream: InputStream = sock.getInputStream()
                val lengthBuf = ByteArray(4)

                while (isListening) {
                    // Read 4-byte big-endian length prefix
                    if (!readFully(stream, lengthBuf, 4)) break
                    val frameLength = ByteBuffer.wrap(lengthBuf).order(ByteOrder.BIG_ENDIAN).int

                    if (frameLength <= 0 || frameLength > 4_000_000) {
                        println("ClientNetwork: Invalid TCP frame length $frameLength, skipping.")
                        continue
                    }

                    // Read raw H.264 frame payload
                    val frameData = ByteArray(frameLength)
                    if (!readFully(stream, frameData, frameLength)) break

                    val now = System.currentTimeMillis()
                    updateJitter(now)

                    // Deliver directly to decoder (TCP is reliable — no reassembly needed)
                    decoder.decodeBuffer(frameData, now)
                    currentLatencyMs = 0f // TCP has no timestamp header; latency tracked by Phase 8 profiling
                    totalPacketsReceived++
                    totalPacketsExpected++
                }

            } catch (e: Exception) {
                if (isListening) println("ClientNetwork: TCP receiver error: ${e.message}")
            } finally {
                tcpSocket?.close()
                tcpSocket = null
            }
        }
    }

    /** Reads exactly [count] bytes from [stream] into [buf]. Returns false on EOF/error. */
    private fun readFully(stream: InputStream, buf: ByteArray, count: Int): Boolean {
        var offset = 0
        while (offset < count) {
            val read = stream.read(buf, offset, count - offset)
            if (read < 0) return false
            offset += read
        }
        return true
    }

    // ── Fragment assembly (UDP only) ──────────────────────────────────────────

    private fun processFragment(
        frameIndex: Int, fragmentIndex: Int, totalFragments: Int,
        frameType: Byte, timestamp: Long,
        data: ByteArray, dataOffset: Int, payloadSize: Int,
        sock: DatagramSocket, serverAddress: InetAddress, port: Int
    ) {
        var assembly = activeFrames[frameIndex]
        if (assembly == null) {
            assembly = FrameAssembly(totalFragments, timestamp, frameType == 1.toByte())
            activeFrames[frameIndex] = assembly
            totalPacketsExpected += totalFragments

            if (activeFrames.size > 10) {
                val keys = activeFrames.keys().toList().sorted()
                for (i in 0 until keys.size - 5) {
                    activeFrames.remove(keys[i])
                }
            }
        }

        if (fragmentIndex in 0 until totalFragments && !assembly.fragmentsReceived[fragmentIndex]) {
            val fragmentData = ByteArray(payloadSize)
            System.arraycopy(data, dataOffset, fragmentData, 0, payloadSize)
            assembly.fragmentsData[fragmentIndex] = fragmentData
            assembly.fragmentsReceived[fragmentIndex] = true
            totalPacketsReceived++
            checkForMissingFragments(frameIndex, assembly, sock, serverAddress, port)
        }

        if (assembly.isComplete() && frameIndex > lastProcessedFrameIndex) {
            val rawFrame = assembly.getAssembledData()
            decoder.decodeBuffer(rawFrame, assembly.timestamp)
            lastProcessedFrameIndex = frameIndex
            activeFrames.remove(frameIndex)
            currentLatencyMs = (System.currentTimeMillis() - assembly.timestamp).toFloat()
        }
    }

    // ── NACK (UDP only) ───────────────────────────────────────────────────────

    private fun checkForMissingFragments(
        frameIndex: Int, assembly: FrameAssembly,
        socket: DatagramSocket, serverAddress: InetAddress, port: Int
    ) {
        val now = System.currentTimeMillis()
        for (i in 0 until assembly.totalFragments) {
            if (!assembly.fragmentsReceived[i]) {
                val nackKey = "$frameIndex-$i"
                val lastNackTime = sentNacks[nackKey] ?: 0L
                if (now - lastNackTime > 50) {
                    sendNack(frameIndex, i.toShort(), socket, serverAddress, port)
                    sentNacks[nackKey] = now
                }
            }
        }
    }

    private fun sendNack(
        frameIndex: Int, fragmentIndex: Short,
        socket: DatagramSocket, serverAddress: InetAddress, port: Int
    ) {
        val buffer = ByteBuffer.allocate(7)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.put(0xFD.toByte())
        buffer.putInt(frameIndex)
        buffer.putShort(fragmentIndex)

        val data = buffer.array()
        try {
            val packet = DatagramPacket(data, data.size, serverAddress, port)
            socket.send(packet)
            nacksSentCount++
        } catch (e: IOException) {
            println("ClientNetwork: Failed to send NACK: ${e.message}")
        }
    }

    // ── Jitter helper ─────────────────────────────────────────────────────────

    private fun updateJitter(now: Long) {
        if (lastReceiveTime > 0) {
            val elapsed = now - lastReceiveTime
            val jitter = Math.abs(elapsed - 16) // 16ms = ideal 60fps interval
            jitterSum += jitter
            jitterCount++
        }
        lastReceiveTime = now
    }

    // ── Telemetry ─────────────────────────────────────────────────────────────

    fun getTelemetryLossRate(): Float {
        val expected = totalPacketsExpected
        if (expected <= 0) return 0f
        val received = totalPacketsReceived
        val lost = expected - received
        return Math.max(0f, Math.min(100f, (lost.toFloat() / expected.toFloat()) * 100f))
    }

    fun getTelemetryJitterMs(): Float {
        if (jitterCount <= 0) return 0f
        val avg = jitterSum.toFloat() / jitterCount.toFloat()
        jitterSum = 0L
        jitterCount = 0
        return avg
    }

    fun getTelemetryLatencyMs(): Float = currentLatencyMs

    // ── Teardown ──────────────────────────────────────────────────────────────

    fun stopListening() {
        isListening = false

        // UDP
        pingThread?.interrupt()
        pingThread = null
        receiveThread?.interrupt()
        receiveThread = null
        socket?.close()
        socket = null

        // TCP
        tcpReceiveThread?.interrupt()
        tcpReceiveThread = null
        tcpSocket?.close()
        tcpSocket = null

        activeFrames.clear()
        sentNacks.clear()
        totalPacketsExpected  = 0
        totalPacketsReceived  = 0
        nacksSentCount        = 0
        jitterSum             = 0
        jitterCount           = 0
        currentLatencyMs      = 0f
        lastProcessedFrameIndex = 0
        isUsbMode             = false
    }
}
