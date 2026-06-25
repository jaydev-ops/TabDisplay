package com.tabdisplay.client.network

import java.net.DatagramSocket

class ClientNetwork {
    // Placeholder class for UDP video receiver socket and Jitter Buffer
    private var socket: DatagramSocket? = null

    fun startListening(port: Int) {
        println("Starting ClientNetwork UDP listener on port $port")
    }

    fun stopListening() {
        println("Stopping ClientNetwork UDP listener")
        socket?.close()
        socket = null
    }
}
