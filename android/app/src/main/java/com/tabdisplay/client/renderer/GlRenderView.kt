package com.tabdisplay.client.renderer

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.util.AttributeSet
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

class GlRenderView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : GLSurfaceView(context, attrs), GLSurfaceView.Renderer {

    interface SurfaceListener {
        fun onSurfaceAvailable(surface: Surface)
    }

    private var surfaceListener: SurfaceListener? = null
    private var surfaceTexture: SurfaceTexture? = null
    private var surface: Surface? = null
    private var textureId = -1

    private var program = -1
    private var positionHandle = -1
    private var textureCoordinateHandle = -1
    private var textureTransformHandle = -1

    private val transformMatrix = FloatArray(16)
    
    private val vertexBuffer: FloatBuffer = createFloatBuffer(
        floatArrayOf(
            -1.0f, -1.0f,
             1.0f, -1.0f,
            -1.0f,  1.0f,
             1.0f,  1.0f
        )
    )

    private val textureBuffer: FloatBuffer = createFloatBuffer(
        floatArrayOf(
            0.0f, 0.0f,
            1.0f, 0.0f,
            0.0f, 1.0f,
            1.0f, 1.0f
        )
    )

    init {
        setEGLContextClientVersion(2)
        setRenderer(this)
        renderMode = RENDERMODE_WHEN_DIRTY
        println("GlRenderView: GLSurfaceView initialized.")
    }

    fun setSurfaceListener(listener: SurfaceListener) {
        this.surfaceListener = listener
        // If surface is already available, notify immediately
        val surf = surface
        if (surf != null) {
            listener.onSurfaceAvailable(surf)
        }
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Generate EGL External OES texture ID
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        // Setup EGL SurfaceTexture
        val tex = SurfaceTexture(textureId)
        tex.setOnFrameAvailableListener {
            post {
                requestRender()
            }
        }
        surfaceTexture = tex
        
        val surf = Surface(tex)
        surface = surf

        // Setup OpenGL shaders
        val vertexShaderSource = "attribute vec4 position;\n" +
                "attribute vec4 inputTextureCoordinate;\n" +
                "varying vec2 textureCoordinate;\n" +
                "uniform mat4 textureTransform;\n" +
                "void main() {\n" +
                "    gl_Position = position;\n" +
                "    textureCoordinate = (textureTransform * inputTextureCoordinate).xy;\n" +
                "}"

        val fragmentShaderSource = "#extension GL_OES_EGL_image_external : require\n" +
                "precision mediump float;\n" +
                "varying vec2 textureCoordinate;\n" +
                "uniform samplerExternalOES videoTexture;\n" +
                "void main() {\n" +
                "    gl_FragColor = texture2D(videoTexture, textureCoordinate);\n" +
                "}"

        val vertexShader = loadShader(GLES20.GL_VERTEX_SHADER, vertexShaderSource)
        val fragmentShader = loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentShaderSource)
        
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)

        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            println("GlRenderView Error: OpenGL program linking failed: $log")
        }

        positionHandle = GLES20.glGetAttribLocation(program, "position")
        textureCoordinateHandle = GLES20.glGetAttribLocation(program, "inputTextureCoordinate")
        textureTransformHandle = GLES20.glGetUniformLocation(program, "textureTransform")

        // Invoke callback on main thread
        post {
            surfaceListener?.onSurfaceAvailable(surf)
        }
    }

    private var videoWidth = 0
    private var videoHeight = 0
    private var viewWidth = 0
    private var viewHeight = 0

    fun setVideoSize(width: Int, height: Int) {
        post {
            videoWidth = width
            videoHeight = height
            updateVertexBuffers()
            requestRender()
        }
    }

    private fun updateVertexBuffers() {
        if (viewWidth <= 0 || viewHeight <= 0 || videoWidth <= 0 || videoHeight <= 0) {
            val vertices = floatArrayOf(
                -1.0f, -1.0f,
                 1.0f, -1.0f,
                -1.0f,  1.0f,
                 1.0f,  1.0f
            )
            synchronized(vertexBuffer) {
                vertexBuffer.clear()
                vertexBuffer.put(vertices)
                vertexBuffer.position(0)
            }
            return
        }

        val viewRatio = viewWidth.toFloat() / viewHeight.toFloat()
        val videoRatio = videoWidth.toFloat() / videoHeight.toFloat()

        var xScale = 1.0f
        var yScale = 1.0f

        if (videoRatio > viewRatio) {
            yScale = viewRatio / videoRatio
        } else if (videoRatio < viewRatio) {
            xScale = videoRatio / viewRatio
        }

        val vertices = floatArrayOf(
            -xScale, -yScale,
             xScale, -yScale,
            -xScale,  yScale,
             xScale,  yScale
        )
        synchronized(vertexBuffer) {
            vertexBuffer.clear()
            vertexBuffer.put(vertices)
            vertexBuffer.position(0)
        }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        viewWidth = width
        viewHeight = height
        updateVertexBuffers()
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClearColor(0.0f, 0.0f, 0.0f, 1.0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        val tex = surfaceTexture ?: return
        synchronized(this) {
            tex.updateTexImage()
            tex.getTransformMatrix(transformMatrix)
        }

        GLES20.glUseProgram(program)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)

        vertexBuffer.position(0)
        GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)
        GLES20.glEnableVertexAttribArray(positionHandle)

        textureBuffer.position(0)
        GLES20.glVertexAttribPointer(textureCoordinateHandle, 2, GLES20.GL_FLOAT, false, 0, textureBuffer)
        GLES20.glEnableVertexAttribArray(textureCoordinateHandle)

        GLES20.glUniformMatrix4fv(textureTransformHandle, 1, false, transformMatrix, 0)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(positionHandle)
        GLES20.glDisableVertexAttribArray(textureCoordinateHandle)
    }

    private fun loadShader(type: Int, shaderCode: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, shaderCode)
        GLES20.glCompileShader(shader)
        
        val compileStatus = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compileStatus, 0)
        if (compileStatus[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            println("GlRenderView Error: OpenGL shader compilation failed (type=$type): $log")
        }
        return shader
    }

    fun release() {
        surfaceTexture?.release()
        surfaceTexture = null
        surface?.release()
        surface = null
    }

    private fun createFloatBuffer(array: FloatArray): FloatBuffer {
        return ByteBuffer.allocateDirect(array.size * 4).run {
            order(ByteOrder.nativeOrder())
            asFloatBuffer().apply {
                put(array)
                position(0)
            }
        }
    }
}
