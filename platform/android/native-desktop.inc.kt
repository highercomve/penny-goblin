    // Penny Goblin desktop native state and scale.
    private var desktopZoomFactor = context.getSharedPreferences("desktop", 0).getFloat("zoom", 1f).coerceIn(1f, 2f)
    fun desktopScale(base: Float): Float = base * resources.configuration.fontScale.coerceAtLeast(1f) * desktopZoomFactor
    private fun desktopZoom(factor: Float) {
        desktopZoomFactor = factor.coerceIn(1f, 2f)
        context.getSharedPreferences("desktop", 0).edit().putFloat("zoom", desktopZoomFactor).apply()
        if (width > 0) {
            density = Nui.cssScale(width, desktopScale(resources.displayMetrics.density))
            NuiNative.resize(window, cssWidth(width), cssHeight(height), dark)
            desktopRelayout(true)
            invalidate()
        }
    }
    private val desktopPinch = android.view.ScaleGestureDetector(context,
        object : android.view.ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: android.view.ScaleGestureDetector): Boolean {
                desktopZoom(desktopZoomFactor * detector.scaleFactor)
                return true
            }
        })
    fun desktopSelection(): JSONObject {
        val out = JSONObject()
        for ((id, field) in fields) if (field is EditText && field.visibility == VISIBLE) {
            out.put(id.toString(), JSONArray().put(field.selectionStart).put(field.selectionEnd).put(field.hasFocus()))
        }
        return out
    }
    fun desktopRestoreSelection(state: JSONObject): Boolean {
        val keys = state.keys().asSequence().toList().take(4096)
        if (keys.any { fields[it.toIntOrNull()] !is EditText }) return false
        for (key in keys) {
            val field = fields[key.toInt()] as? EditText ?: continue
            val value = state.optJSONArray(key) ?: continue
            val length = field.text.length
            field.setSelection(value.optInt(0).coerceIn(0, length), value.optInt(1).coerceIn(0, length))
            if (value.optBoolean(2)) field.requestFocus()
        }
        return true
    }
    private var desktopScrollUntil = 0L
    private fun desktopScrollbars(canvas: Canvas) {
        if (android.os.SystemClock.uptimeMillis() > desktopScrollUntil) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xaa737a72.toInt() }
        val f = frames
        canvas.save()
        canvas.scale(density, density)
        var r = 0
        while (r + REC <= f.size) {
            val node = nodes[ids[r]]
            if (node?.p?.optBoolean("scroll") == true && f[r + 4] > 0) {
                var child = r + REC
                val end = (r + REC * (1 + f[r + 13].toInt())).coerceAtMost(f.size)
                var top = Float.POSITIVE_INFINITY
                var bottom = Float.NEGATIVE_INFINITY
                while (child + REC <= end) {
                    top = min(top, f[child + 2])
                    bottom = max(bottom, f[child + 2] + f[child + 4])
                    child += REC * (1 + f[child + 13].toInt()).coerceAtLeast(1)
                }
                val extent = bottom - top
                val height = f[r + 4]
                if (extent.isFinite() && extent > height + 1) {
                    val thumb = (height * height / extent).coerceIn(min(24f, height), height)
                    val offset = (f[r + 2] - top).coerceIn(0f, extent - height)
                    val y = f[r + 2] + offset / (extent - height) * (height - thumb)
                    val x = f[r + 1] + f[r + 3] - 6
                    val save = canvas.save()
                    canvas.clipRect(f[r + 5], f[r + 6], f[r + 5] + f[r + 7], f[r + 6] + f[r + 8])
                    canvas.drawRoundRect(x, y, x + 4, y + thumb, 2f, 2f, paint)
                    canvas.restoreToCount(save)
                }
            }
            r += REC
        }
        canvas.restore()
        postInvalidateDelayed(1000)
    }
    private var desktopTouchTarget: View? = null
    private fun desktopFieldAt(x: Float, y: Float): View? {
        for ((id, widget) in fields) {
            if (widget.visibility != VISIBLE) continue
            val r = index[id] ?: continue
            if (r + REC > frames.size) continue
            val px = x / density; val py = y / density
            if (px >= frames[r + 1] && py >= frames[r + 2] && px < frames[r + 1] + frames[r + 3] && py < frames[r + 2] + frames[r + 4] &&
                px >= frames[r + 5] && py >= frames[r + 6] && px < frames[r + 5] + frames[r + 7] && py < frames[r + 6] + frames[r + 8]) return widget
        }
        return null
    }
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            desktopTouchTarget = desktopFieldAt(event.x, event.y)?.takeIf {
                event.x < it.left || event.y < it.top || event.x >= it.right || event.y >= it.bottom
            }
        }
        val widget = desktopTouchTarget
        if (widget != null && event.pointerCount == 1) {
            val copy = MotionEvent.obtain(event)
            copy.setLocation((event.x - widget.left).coerceIn(0f, (widget.width - 1).coerceAtLeast(0).toFloat()),
                (event.y - widget.top).coerceIn(0f, (widget.height - 1).coerceAtLeast(0).toFloat()))
            val handled = widget.dispatchTouchEvent(copy)
            copy.recycle()
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) desktopTouchTarget = null
            return handled
        }
        desktopTouchTarget = null
        return super.dispatchTouchEvent(event)
    }
    private var desktopLayoutQueued = false
    private var desktopStylePending = false
    private fun desktopRelayout(style: Boolean = false) {
        desktopStylePending = desktopStylePending || style
        if (desktopLayoutQueued) return
        desktopLayoutQueued = true
        // Frame updates may arrive inside onSizeChanged/onLayout; defer the
        // native child measurement so Android doesn't discard the request.
        post {
            desktopLayoutQueued = false
            if (desktopStylePending) {
                desktopStylePending = false
                for ((id, widget) in fields) nodes[id]?.let { styleField(it, widget) }
            }
            requestLayout()
            post { desktopRestoreFocus() }
        }
    }
    private var desktopHiddenFocus: Triple<View, Int, Int>? = null
    private fun desktopRememberFocus(widget: View) {
        if (widget.hasFocus()) {
            val field = widget as? EditText
            desktopHiddenFocus = Triple(widget, field?.selectionStart ?: 0, field?.selectionEnd ?: 0)
        }
    }
    private fun desktopRestoreFocus() {
        val remembered = desktopHiddenFocus
        if (remembered != null && !fields.containsValue(remembered.first)) desktopHiddenFocus = null
        else if (remembered != null && remembered.first.visibility == VISIBLE) {
            desktopHiddenFocus = null
            remembered.first.requestFocus()
            (remembered.first as? EditText)?.let { field ->
                field.setSelection(remembered.second.coerceIn(0, field.length()), remembered.third.coerceIn(0, field.length()))
            }
        }
        if (findFocus() == null) requestFocus()
    }
