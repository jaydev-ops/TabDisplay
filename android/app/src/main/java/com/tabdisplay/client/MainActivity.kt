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
import androidx.appcompat.widget.SwitchCompat
import com.tabdisplay.client.decoder.HardwareDecoder
import com.tabdisplay.client.input.TouchForwarder
import com.tabdisplay.client.network.ClientNetwork
import com.tabdisplay.client.network.ControlClient
import com.tabdisplay.client.proto.HandshakeResponse
import com.tabdisplay.client.proto.VideoTransport
import com.tabdisplay.client.renderer.GlRenderView

class MainActivity : AppCompatActivity(), ControlClient.Listener, GlRenderView.SurfaceListener {

    // ── UI ─────────────────────────────────────────────────────────────────────
    private lateinit var ipInput: EditText
    private lateinit var btnConnect: Button
    private lateinit var statusText: TextView
    private lateinit var connectionOverlay: LinearLayout
    private lateinit var glRenderView: GlRenderView
    private lateinit var usbModeSwitch: SwitchCompat
    private lateinit var usbModeHint: TextView

    // ── Pipeline ──────────────────────────────────────────────────────────────
    private var controlClient: ControlClient? = null
    private var clientNetwork: ClientNetwork? = null
    private var hardwareDecoder: HardwareDecoder? = null
    private var touchForwarder: TouchForwarder? = null

    // ── State ─────────────────────────────────────────────────────────────────
    private var serverIpAddress: String = ""
    private var isConnected = false
    private var allocatedWidth  = 1920
    private var allocatedHeight = 1080
    private var videoStreamPort = 6002
    private var negotiatedTransport = VideoTransport.UDP

    private val mainHandler = Handler(Looper.getMainLooper())

    private val telemetryRunnable = object : Runnable {
        override fun run() {
            if (isConnected) {
                val network = clientNetwork
                if (network != null) {
                    val loss    = network.getTelemetryLossRate()
                    val jitter  = network.getTelemetryJitterMs()
                    val latency = network.getTelemetryLatencyMs()
                    controlClient?.sendTelemetry(loss, jitter, latency)
                    println("Telemetry → Loss: ${String.format("%.2f", loss)}%, Jitter: ${String.format("%.2f", jitter)}ms, Latency: ${String.format("%.2f", latency)}ms")
                }
                mainHandler.postDelayed(this, 500)
            }
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        @Suppress("DEPRECATION")
        window.setFlags(
            WindowManager.LayoutParams.FLAG_FULLSCREEN,
            WindowManager.LayoutParams.FLAG_FULLSCREEN
        )

        setContentView(R.layout.activity_main)

        // Bind UI
        ipInput           = findViewById(R.id.ip_input)
        btnConnect        = findViewById(R.id.btn_connect)
        statusText        = findViewById(R.id.status_text)
        connectionOverlay = findViewById(R.id.connection_overlay)
        glRenderView      = findViewById(R.id.gl_render_view)
        usbModeSwitch     = findViewById(R.id.usb_mode_switch)
        usbModeHint       = findViewById(R.id.usb_mode_hint)

        // Initialize core objects
        controlClient  = ControlClient(this)
        hardwareDecoder = HardwareDecoder()
        clientNetwork  = ClientNetwork(hardwareDecoder!!)

        // USB Mode toggle
        usbModeSwitch.setOnCheckedChangeListener { _, isChecked ->
            if (isChecked) {
                // USB mode: auto-fill IP and disable editing
                ipInput.setText("127.0.0.1")
                ipInput.isEnabled = false
                usbModeHint.visibility = View.VISIBLE
                statusText.text = "USB Mode — connect via cable, then tap Connect"
            } else {
                // Wi-Fi mode: restore IP input
                ipInput.isEnabled = true
                ipInput.hint = "macOS Server IP Address"
                if (ipInput.text.toString() == "127.0.0.1") {
                    ipInput.setText("")
                }
                usbModeHint.visibility = View.GONE
                statusText.text = "Ready for connection"
            }
        }

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
        usbModeSwitch.isEnabled = false

        // Get native display resolution in pixels
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels

        controlClient?.connect(ip, 5001, width, height)
    }

    // ── ControlClient.Listener ────────────────────────────────────────────────

    override fun onHandshakeResponse(response: HandshakeResponse) {
        if (response.accepted) {
            println("Handshake accepted by macOS server: '${response.serverName}'")
            allocatedWidth       = response.allocatedWidth
            allocatedHeight      = response.allocatedHeight
            videoStreamPort      = response.videoStreamPort
            negotiatedTransport  = response.videoTransport

            val transportLabel = if (negotiatedTransport == VideoTransport.TCP) "TCP (USB)" else "UDP (Wi-Fi)"
            statusText.text = "Handshake accepted [$transportLabel]. Activating display..."
            isConnected = true

            connectionOverlay.visibility = View.GONE

            glRenderView.setVideoSize(allocatedWidth, allocatedHeight)
            glRenderView.setSurfaceListener(this)

            val client = controlClient
            if (client != null) {
                val forwarder = TouchForwarder(client)
                forwarder.setVideoSize(allocatedWidth, allocatedHeight)
                touchForwarder = forwarder
                glRenderView.setOnTouchListener(forwarder)
            }

            mainHandler.postDelayed(telemetryRunnable, 500)
        } else {
            statusText.text = "Handshake rejected by server."
            resetConnectionUI()
        }
    }

    // ── GlRenderView.SurfaceListener ──────────────────────────────────────────

    override fun onSurfaceAvailable(surface: Surface) {
        hardwareDecoder?.initialize(surface, allocatedWidth, allocatedHeight)

        // Start video reception using the transport negotiated at handshake
        if (negotiatedTransport == VideoTransport.TCP) {
            println("Starting TCP video receiver on $serverIpAddress:$videoStreamPort (USB mode)")
            clientNetwork?.startTcpListening(serverIpAddress, videoStreamPort)
        } else {
            println("Starting UDP video listener on $serverIpAddress:$videoStreamPort (Wi-Fi mode)")
            clientNetwork?.startListening(serverIpAddress, videoStreamPort)
        }

        println("Display and streaming pipelines active ($negotiatedTransport).")
    }

    override fun onConnectionClosed(error: String?) {
        println("Connection closed: $error")
        mainHandler.post {
            statusText.text = if (error != null) "Connection lost: $error" else "Disconnected from server"
            teardownPipeline()
            resetConnectionUI()
        }
    }

    // ── UI helpers ────────────────────────────────────────────────────────────

    private fun resetConnectionUI() {
        isConnected = false
        btnConnect.isEnabled    = true
        usbModeSwitch.isEnabled = true
        // Restore IP input based on mode
        if (!usbModeSwitch.isChecked) {
            ipInput.isEnabled = true
        }
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

    // ── GLSurfaceView lifecycle ───────────────────────────────────────────────

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
