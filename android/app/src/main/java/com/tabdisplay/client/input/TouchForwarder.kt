package com.tabdisplay.client.input

import android.view.MotionEvent
import android.view.View

class TouchForwarder : View.OnTouchListener {
    // Intercepts touch inputs and compiles/sends Protobuf coordinate packet
    
    override fun onTouch(v: View, event: MotionEvent): Boolean {
        val x = event.x
        val y = event.y
        val action = event.action
        
        // TODO: Map to percentage coordinates and send to ControlClient
        println("Captured touch action $action at: $x, $y")
        return true
    }
}
