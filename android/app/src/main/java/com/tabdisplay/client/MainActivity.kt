package com.tabdisplay.client

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.tabdisplay.client.decoder.HardwareDecoder
import com.tabdisplay.client.input.TouchForwarder
import com.tabdisplay.client.network.ClientNetwork
import com.tabdisplay.client.network.ControlClient
import com.tabdisplay.client.proto.HandshakeResponse
import com.tabdisplay.client.renderer.GlRenderView

class MainActivity : AppCompatActivity(), ControlClient.Listener, GlRenderView.SurfaceListener {

    private lateinit var ipInput: EditText
    private lateinit var btnConnect: Button
    private lateinit var statusText: TextView
    private lateinit var connectionOverlay: LinearLayout
    private lateinit var glRenderView: GlRenderView

    private var controlClient: ControlClient? = null
    private var clientNetwork: ClientNetwork? = null
    private var hardwareDecoder: HardwareDecoder? = null
    private var touchForwarder: TouchForwarder? = null

    private var serverIpAddress: String = ""
    private var isConnected = false
    private var allocatedWidth = 1920
    private var allocatedHeight = 1080
    private var videoStreamPort = 6002

    private val mainHandler = Handler(Looper.getMainLooper())
    
    private val telemetryRunnable = object : Runnable {
        override fun run() {
            if (isConnected) {
                val network = clientNetwork
                if (network != null) {
                    val loss = network.getTelemetryLossRate()
                    val jitter = network.getTelemetryJitterMs()
                    val latency = network.getTelemetryLatencyMs()
                    
                    // Dispatch telemetry feedback back to server for adaptive bitrate control
                    controlClient?.sendTelemetry(loss, jitter, latency)
                    
                    println("Telemetry -> Loss: ${String.format("%.2f", loss)}%, Jitter: ${String.format("%.2f", jitter)}ms, Latency: ${String.format("%.2f", latency)}ms")
                }
                mainHandler.postDelayed(this, 1000)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Force full screen & keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_FULLSCREEN,
            WindowManager.LayoutParams.FLAG_FULLSCREEN
        )
        
        setContentView(R.layout.activity_main)

        // Initialize UI Elements
        ipInput = findViewById(R.id.ip_input)
        btnConnect = findViewById(R.id.btn_connect)
        statusText = findViewById(R.id.status_text)
        connectionOverlay = findViewById(R.id.connection_overlay)
        glRenderView = findViewById(R.id.gl_render_view)

        // Setup clients and decoders
        controlClient = ControlClient(this)
        hardwareDecoder = HardwareDecoder()
        clientNetwork = ClientNetwork(hardwareDecoder!!)

        btnConnect.setOnClickListener {
            val ip = ipInput.text.toString().trim()
            if (ip.isNotEmpty()) {
                serverIpAddress = ip
                connectToServer(ip)
            } else {
                statusText.text = "Please enter a valid IP address"
            }
        }

        println("TabDisplay Android Client initialized and ready.")
    }

    private fun connectToServer(ip: String) {
        statusText.text = "Connecting to macOS Server at $ip..."
        btnConnect.isEnabled = false
        ipInput.isEnabled = false
        controlClient?.connect(ip, 5001)
    }

    override fun onHandshakeResponse(response: HandshakeResponse) {
        if (response.accepted) {
            println("Handshake accepted by macOS server: '${response.serverName}'")
            allocatedWidth = response.allocatedWidth
            allocatedHeight = response.allocatedHeight
            videoStreamPort = response.videoStreamPort
            
            statusText.text = "Handshake accepted. Activating display pipeline..."
            isConnected = true

            // Hide the configuration overlay
            connectionOverlay.visibility = View.GONE

            // Bind rendering surface and initiate decoder and UDP streaming stack
            glRenderView.setSurfaceListener(this)

            // Setup touch event forwarding listener
            val client = controlClient
            if (client != null) {
                val forwarder = TouchForwarder(client)
                touchForwarder = forwarder
                glRenderView.setOnTouchListener(forwarder)
            }

            // Start telemetry scheduler
            mainHandler.postDelayed(telemetryRunnable, 1000)
        } else {
            statusText.text = "Handshake rejected by server."
            resetConnectionUI()
        }
    }

    override fun onSurfaceAvailable(surface: Surface) {
        // Once the OpenGL view provides its hardware-backed Surface:
        // 1. Configure the H.264 MediaCodec decoder targeting this Surface
        hardwareDecoder?.initialize(surface, allocatedWidth, allocatedHeight)
        
        // 2. Start the UDP video fragment network stream receiver
        clientNetwork?.startListening(serverIpAddress, videoStreamPort)
        
        println("Display and streaming pipelines active.")
    }

    override fun onConnectionClosed(error: String?) {
        println("Connection closed: $error")
        statusText.text = if (error != null) "Connection lost: $error" else "Disconnected from server"
        
        // Teardown streaming and decoding pipeline
        teardownPipeline()
        resetConnectionUI()
    }

    private fun resetConnectionUI() {
        isConnected = false
        btnConnect.isEnabled = true
        ipInput.isEnabled = true
        connectionOverlay.visibility = View.VISIBLE
    }

    private fun teardownPipeline() {
        isConnected = false
        mainHandler.removeCallbacks(telemetryRunnable)
        clientNetwork?.stopListening()
        hardwareDecoder?.release()
        glRenderView.setOnTouchListener(null)
        touchForwarder = null
    }

    override fun onResume() {
        super.onResume()
        glRenderView.onResume()
    }

    override fun onPause() {
        super.onPause()
        glRenderView.onPause()
    }

    override fun onDestroy() {
        super.onDestroy()
        teardownPipeline()
        controlClient?.disconnect()
        glRenderView.release()
    }
}
