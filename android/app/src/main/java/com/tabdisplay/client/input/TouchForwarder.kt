package com.tabdisplay.client.input

import android.view.MotionEvent
import android.view.View
import com.tabdisplay.client.network.ControlClient
import com.tabdisplay.client.proto.ControlPacket
import com.tabdisplay.client.proto.InputEvent

class TouchForwarder(private val controlClient: ControlClient) : View.OnTouchListener {

    private var isScrolling = false
    private var prevScrollX = 0f
    private var prevScrollY = 0f

    override fun onTouch(v: View, event: MotionEvent): Boolean {
        val width = if (v.width > 0) v.width else 1
        val height = if (v.height > 0) v.height else 1
        
        val xPercent = (event.x / width).coerceIn(0.0f, 1.0f)
        val yPercent = (event.y / height).coerceIn(0.0f, 1.0f)
        val pointerCount = event.pointerCount
        val actionMasked = event.actionMasked

        when (actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                isScrolling = false
                sendInputEvent(InputEvent.ActionType.ACTION_DOWN, xPercent, yPercent, pointerCount)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (pointerCount == 2) {
                    // Transition to scroll: first release mouse down if any
                    sendInputEvent(InputEvent.ActionType.ACTION_UP, xPercent, yPercent, pointerCount)
                    isScrolling = true
                    prevScrollX = (event.getX(0) + event.getX(1)) / 2f
                    prevScrollY = (event.getY(0) + event.getY(1)) / 2f
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (isScrolling && pointerCount >= 2) {
                    val currentScrollX = (event.getX(0) + event.getX(1)) / 2f
                    val currentScrollY = (event.getY(0) + event.getY(1)) / 2f
                    val deltaX = currentScrollX - prevScrollX
                    val deltaY = currentScrollY - prevScrollY
                    
                    sendScrollEvent(deltaX.toInt(), deltaY.toInt(), pointerCount)
                    
                    prevScrollX = currentScrollX
                    prevScrollY = currentScrollY
                } else if (!isScrolling && pointerCount == 1) {
                    sendInputEvent(InputEvent.ActionType.ACTION_MOVE, xPercent, yPercent, pointerCount)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (isScrolling) {
                    isScrolling = false
                } else {
                    sendInputEvent(InputEvent.ActionType.ACTION_UP, xPercent, yPercent, pointerCount)
                }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (pointerCount <= 2 && isScrolling) {
                    isScrolling = false
                }
            }
        }
        return true
    }

    private fun sendInputEvent(action: InputEvent.ActionType, xPercent: Float, yPercent: Float, pointerCount: Int) {
        val input = InputEvent.newBuilder()
            .setAction(action)
            .setXPercent(xPercent)
            .setYPercent(yPercent)
            .setPointerCount(pointerCount)
            .build()

        val packet = ControlPacket.newBuilder()
            .setInputEvent(input)
            .build()

        controlClient.sendPacket(packet)
    }

    private fun sendScrollEvent(deltaX: Int, deltaY: Int, pointerCount: Int) {
        val input = InputEvent.newBuilder()
            .setAction(InputEvent.ActionType.ACTION_SCROLL)
            .setScrollDeltaX(deltaX)
            .setScrollDeltaY(deltaY)
            .setPointerCount(pointerCount)
            .build()

        val packet = ControlPacket.newBuilder()
            .setInputEvent(input)
            .build()

        controlClient.sendPacket(packet)
    }
}
