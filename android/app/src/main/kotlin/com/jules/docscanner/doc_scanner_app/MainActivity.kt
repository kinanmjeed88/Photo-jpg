package com.jules.docscanner.doc_scanner_app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * Host activity for the scanner.
 *
 * The app stores identity documents, so the window is marked as secure:
 * this blocks screenshots and screen recording and keeps the content out of
 * the "recent apps" thumbnail. The flag is applied in [onCreate] before the
 * first frame, and re-applied in [onResume] because some OEM builds reset
 * window flags when the activity is restored from the background.
 *
 * If the product ever needs to allow screenshots of a specific screen, the
 * supported way is to clear the flag for that route instead of removing it
 * here.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applySecureFlag()
    }

    override fun onResume() {
        super.onResume()
        applySecureFlag()
    }

    private fun applySecureFlag() {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }
}
