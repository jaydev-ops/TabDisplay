package com.tabdisplay.client.network

import java.net.Socket

class ControlClient {
    // Placeholder class for TCP control handshake connection
    private var socket: Socket? = null

    fun connect(host: String, port: Int) {
        println("Connecting ControlClient TCP socket to $host:$port")
    }

    fun disconnect() {
        println("Disconnecting ControlClient TCP socket")
        socket?.close()
        socket = null
    }
}
