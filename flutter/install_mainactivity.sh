#!/bin/bash
# Script to install the custom MainActivity.kt
# Run this in the flutter/ directory

# Find existing MainActivity
MAIN=$(find android -name "MainActivity.kt" -type f 2>/dev/null | head -1)
if [ -z "$MAIN" ]; then
  echo "ERROR: MainActivity.kt not found in android/"
  exit 1
fi

echo "Found: $MAIN"

# Extract package from existing file
PKG=$(grep "^package " "$MAIN" | head -1 | sed 's/package //')
echo "Package: $PKG"

# Write new file
cat > "$MAIN" << KOTLIN
package $PKG

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity: FlutterActivity() {
    private var volumeSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "fr.mangashelf/volume_keys")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    volumeSink = events
                }
                override fun onCancel(arguments: Any?) {
                    volumeSink = null
                }
            })
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeSink != null) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeSink?.success("volume_down")
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeSink?.success("volume_up")
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
KOTLIN

echo "MainActivity.kt updated!"
