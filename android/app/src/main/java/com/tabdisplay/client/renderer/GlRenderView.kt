package com.tabdisplay.client.renderer

import android.content.Context
import android.opengl.GLSurfaceView
import android.util.AttributeSet
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

class GlRenderView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : GLSurfaceView(context, attrs), GLSurfaceView.Renderer {

    init {
        setEGLContextClientVersion(2)
        setRenderer(this)
        renderMode = RENDERMODE_WHEN_DIRTY
        println("GlRenderView renderer initialized.")
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Setup OpenGL textures, shaders, and framebuffers
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        // Handle window resizing/rotation
    }

    override fun onDrawFrame(gl: GL10?) {
        // Render updated video texture to surface
    }
}
