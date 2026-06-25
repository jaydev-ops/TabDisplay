package com.tabdisplay.client.network

import com.tabdisplay.client.decoder.HardwareDecoder
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

class ClientNetwork(private val decoder: HardwareDecoder) {

    private var socket: DatagramSocket? = null
    private var isListening = false
    private var pingThread: Thread? = null
    private var receiveThread: Thread? = null

    // Cache of active frames being assembled
    private val activeFrames = ConcurrentHashMap<Int, FrameAssembly>()
    private var lastProcessedFrameIndex = 0

    // Telemetry / Metrics
    private var totalPacketsExpected = 0
    private var totalPacketsReceived = 0
    private var nacksSentCount = 0
    private var lastReceiveTime = 0L
    private var jitterSum = 0L
    private var jitterCount = 0
    private var currentLatencyMs = 0f

    // Keep track of sent NACKs to avoid spamming
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

    fun startListening(serverIp: String, port: Int) {
        stopListening()
        isListening = true

        try {
            val sock = DatagramSocket()
            socket = sock
            println("ClientNetwork: UDP socket bound to local port ${sock.localPort}")

            val serverAddress = InetAddress.getByName(serverIp)

            // 1. Spawns periodic registration ping thread (0xFF)
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

            // 2. Start UDP receive loop
            receiveThread = thread(name = "ClientNetwork-Receiver") {
                val buffer = ByteArray(65535)
                val packet = DatagramPacket(buffer, buffer.size)

                while (isListening) {
                    try {
                        sock.receive(packet)
                        val now = System.currentTimeMillis()
                        
                        // Parse UDP payload
                        val data = packet.data
                        val length = packet.length

                        if (length < 20) continue

                        // Parse 20-byte custom header
                        val headerBuffer = ByteBuffer.wrap(data, packet.offset, 20)
                        headerBuffer.order(ByteOrder.BIG_ENDIAN)

                        val frameIndex = headerBuffer.getInt(0)
                        val fragmentIndex = headerBuffer.getShort(4).toInt()
                        val totalFragments = headerBuffer.getShort(6).toInt()
                        val payloadSize = headerBuffer.getShort(8).toInt()
                        val frameType = data[packet.offset + 10]
                        val timestamp = headerBuffer.getLong(12)

                        if (length < 20 + payloadSize) continue

                        // Stop sending pings once we receive the first valid video packet
                        if (pingThread != null) {
                            pingThread?.interrupt()
                            pingThread = null
                            println("ClientNetwork: Video packet received. Disabling UDP ping timer.")
                        }

                        // Update Jitter metric
                        if (lastReceiveTime > 0) {
                            val elapsed = now - lastReceiveTime
                            val jitter = Math.abs(elapsed - 16) // ideal interval is 16ms for 60fps
                            jitterSum += jitter
                            jitterCount++
                        }
                        lastReceiveTime = now

                        // Retrieve or create frame assembly
                        var assembly = activeFrames[frameIndex]
                        if (assembly == null) {
                            assembly = FrameAssembly(totalFragments, timestamp, frameType == 1.toByte())
                            activeFrames[frameIndex] = assembly
                            totalPacketsExpected += totalFragments

                            // Evict extremely old frames to prevent leaks
                            if (activeFrames.size > 10) {
                                val keys = activeFrames.keys().toList().sorted()
                                for (i in 0 until keys.size - 5) {
                                    activeFrames.remove(keys[i])
                                }
                            }
                        }

                        // Store fragment data if not already received
                        if (fragmentIndex in 0 until totalFragments && !assembly.fragmentsReceived[fragmentIndex]) {
                            val fragmentData = ByteArray(payloadSize)
                            System.arraycopy(data, packet.offset + 20, fragmentData, 0, payloadSize)
                            assembly.fragmentsData[fragmentIndex] = fragmentData
                            assembly.fragmentsReceived[fragmentIndex] = true
                            totalPacketsReceived++

                            // Trigger NACK check for any missing fragments in this frame
                            checkForMissingFragments(frameIndex, assembly, sock, serverAddress, port)
                        }

                        // Reassemble and decode if complete
                        if (assembly.isComplete() && frameIndex > lastProcessedFrameIndex) {
                            val rawFrame = assembly.getAssembledData()
                            decoder.decodeBuffer(rawFrame, assembly.timestamp)
                            lastProcessedFrameIndex = frameIndex
                            activeFrames.remove(frameIndex)

                            // Telemetry latency estimation
                            currentLatencyMs = (System.currentTimeMillis() - assembly.timestamp).toFloat()
                        }
                    } catch (e: Exception) {
                        if (isListening) {
                            println("ClientNetwork receiver loop error: ${e.message}")
                        }
                        break
                    }
                }
            }

        } catch (e: Exception) {
            println("ClientNetwork: Failed to start listener: ${e.message}")
        }
    }

    private fun checkForMissingFragments(
        frameIndex: Int,
        assembly: FrameAssembly,
        socket: DatagramSocket,
        serverAddress: InetAddress,
        port: Int
    ) {
        val now = System.currentTimeMillis()
        for (i in 0 until assembly.totalFragments) {
            if (!assembly.fragmentsReceived[i]) {
                // Send NACK if we haven't sent one recently for this specific fragment (throttle to 50ms)
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
        frameIndex: Int,
        fragmentIndex: Short,
        socket: DatagramSocket,
        serverAddress: InetAddress,
        port: Int
    ) {
        val buffer = ByteBuffer.allocate(7)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.put(0xFD.toByte()) // NACK Magic Byte
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

    fun getTelemetryLossRate(): Float {
        val expected = totalPacketsExpected
        if (expected <= 0) return 0f
        val received = totalPacketsReceived
        val lost = expected - received
        val rate = (lost.toFloat() / expected.toFloat()) * 100f
        return Math.max(0f, Math.min(100f, rate))
    }

    fun getTelemetryJitterMs(): Float {
        if (jitterCount <= 0) return 0f
        val avg = jitterSum.toFloat() / jitterCount.toFloat()
        // Reset jitter stats for sliding window calculation
        jitterSum = 0L
        jitterCount = 0
        return avg
    }

    fun getTelemetryLatencyMs(): Float {
        return currentLatencyMs
    }

    fun stopListening() {
        isListening = false
        pingThread?.interrupt()
        pingThread = null
        receiveThread?.interrupt()
        receiveThread = null
        socket?.close()
        socket = null
        activeFrames.clear()
        sentNacks.clear()
        totalPacketsExpected = 0
        totalPacketsReceived = 0
        nacksSentCount = 0
        jitterSum = 0
        jitterCount = 0
        currentLatencyMs = 0f
        lastProcessedFrameIndex = 0
    }
}
