package com.fitgestion.fitgestion

import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.Executors

/// Native hot paths for the Dart `NativeLooktokEngine` (channel
/// `com.looktok.app/engine`) — see NATIVE_ENGINE.md for the full contract.
/// Payloads across the channel are FILE PATHS (never raw bytes); every failure
/// answers `null`, never an exception — Dart treats null as "use the fallback".
class MainActivity : FlutterActivity() {

    // ML Kit subject segmentation (people AND garments, unlike selfie
    // segmentation). foregroundBitmap = the input with background already
    // transparent. The model itself is fetched by Play Services on install
    // (see the DEPENDENCIES meta-data in AndroidManifest.xml).
    private val segmenter by lazy {
        SubjectSegmentation.getClient(
            SubjectSegmenterOptions.Builder()
                .enableForegroundBitmap()
                .build()
        )
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.looktok.app/engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSegmentationSupported" ->
                        // Subject segmentation needs API 24+. If the model
                        // hasn't downloaded yet, extractSilhouette fails soft
                        // (null) and Dart cascades to the next fallback.
                        result.success(Build.VERSION.SDK_INT >= 24)

                    "extractSilhouette" -> {
                        val path = call.argument<String>("imagePath")
                        if (path == null) result.success(null)
                        else extractSilhouette(path, result)
                    }

                    "captureHighResPhoto" ->
                        // TODO(CameraX): zero-lag capture — ImageCapture
                        // .takePicture into cacheDir, long side <=1600px,
                        // JPEG q85, return the file path. Until then null →
                        // Flutter silently falls back to image_picker.
                        result.success(null)

                    else -> result.notImplemented()
                }
            }
    }

    private fun extractSilhouette(path: String, result: MethodChannel.Result) {
        // MethodChannel results must be delivered on the platform thread.
        fun answer(value: String?) {
            mainHandler.post { result.success(value) }
        }
        try {
            val input = InputImage.fromFilePath(this, Uri.fromFile(File(path)))
            segmenter.process(input)
                .addOnSuccessListener { seg ->
                    val fg = seg.foregroundBitmap ?: return@addOnSuccessListener answer(null)
                    // Crop + PNG-encode off the main thread (hundreds of ms
                    // on big bitmaps — must not stall the UI).
                    worker.execute {
                        answer(
                            try {
                                tightCrop(fg)?.let(::writePng)
                            } catch (_: Exception) {
                                null
                            }
                        )
                    }
                }
                .addOnFailureListener { answer(null) } // model still downloading, etc.
        } catch (_: Exception) {
            answer(null) // unreadable file / bad path
        }
    }

    /** Crop the transparent bitmap to its opaque bounds (alpha > 16). Returns
     *  null when no meaningful subject was found (<2% of the frame). */
    private fun tightCrop(src: Bitmap): Bitmap? {
        val w = src.width
        val h = src.height
        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)
        var minX = w; var minY = h; var maxX = -1; var maxY = -1
        for (y in 0 until h) {
            val row = y * w
            for (x in 0 until w) {
                if (pixels[row + x] ushr 24 > 16) {
                    if (x < minX) minX = x
                    if (x > maxX) maxX = x
                    if (y < minY) minY = y
                    if (y > maxY) maxY = y
                }
            }
        }
        if (maxX < 0 || (maxX - minX) * (maxY - minY) < w * h * 0.02) return null
        return Bitmap.createBitmap(src, minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    private fun writePng(bmp: Bitmap): String {
        val out = File(cacheDir, "looktok-seg-${UUID.randomUUID()}.png")
        FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return out.absolutePath
    }

    override fun onDestroy() {
        segmenter.close()
        worker.shutdown()
        super.onDestroy()
    }
}
