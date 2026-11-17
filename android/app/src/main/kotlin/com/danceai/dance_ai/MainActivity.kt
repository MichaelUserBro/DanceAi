package com.danceai.dance_ai

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Выбор видео на Android: системный выбор документа (ACTION_OPEN_DOCUMENT)
 * отдаёт только content:// URI — файл не читается в память и не копируется.
 * FFmpeg и video_player читают URI напрямую.
 *
 * Если Android выгрузил приложение, пока был открыт выбор, результат
 * приходит в новый процесс: id танца сохраняется в savedInstanceState,
 * выбор откладывается до запроса из Dart ("takeRestored").
 */
class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingDanceId: String? = null
    private var restored: Map<String, Any?>? = null

    // Сохранение файла («Сохранить JSON» в «Для разработчика»).
    private var saveResult: MethodChannel.Result? = null
    private var saveBytes: ByteArray? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingDanceId = savedInstanceState?.getString(KEY_DANCE)
        super.onCreate(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pendingDanceId?.let { outState.putString(KEY_DANCE, it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::onCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler(::onFilesCall)
    }

    /**
     * "save": системный диалог «Сохранить как» (ACTION_CREATE_DOCUMENT) —
     * пользователь выбирает место (например, «Загрузки»), байты пишутся
     * через ContentResolver. Без разрешений на хранилище и без пакетов.
     */
    private fun onFilesCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "save") {
            result.notImplemented()
            return
        }
        val name = call.argument<String>("name") ?: "danceai.json"
        val mime = call.argument<String>("mime") ?: "application/json"
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("NO_DATA", "Нет данных", null)
            return
        }
        saveResult?.success(false)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            saveResult = result
            saveBytes = bytes
            startActivityForResult(intent, REQUEST_SAVE)
        } catch (e: Exception) {
            saveResult = null
            saveBytes = null
            result.error("NO_PICKER", "Не удалось открыть сохранение файла", null)
        }
    }

    private fun onSaveResult(resultCode: Int, data: Intent?) {
        val result = saveResult ?: return
        val bytes = saveBytes
        saveResult = null
        saveBytes = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null || bytes == null) {
            result.success(false)
            return
        }
        try {
            contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
                ?: throw IllegalStateException("нет потока")
            result.success(true)
        } catch (e: Exception) {
            result.error("WRITE_FAILED", "Не удалось записать файл", null)
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call.argument<String>("danceId"), result)
            "takeRestored" -> {
                result.success(restored)
                restored = null
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(danceId: String?, result: MethodChannel.Result) {
        if (pendingResult != null) {
            // Предыдущий выбор так и не вернулся — завершаем его как отмену.
            pendingResult?.success(null)
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            pendingResult = result
            pendingDanceId = danceId
            startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            pendingResult = null
            pendingDanceId = null
            result.error("NO_PICKER", "Не удалось открыть выбор файла", null)
        }
    }

    @Deprecated("FlutterActivity — не ComponentActivity, Activity Result API недоступен")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_SAVE) {
            onSaveResult(resultCode, data)
            return
        }
        if (requestCode != REQUEST_PICK) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult
        val danceId = pendingDanceId
        pendingResult = null
        pendingDanceId = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        val video = uri?.let { describe(it) }
        if (result != null) {
            result.success(video)
        } else if (video != null && danceId != null) {
            // Процесс был выгружен: Dart спросит после запуска.
            restored = video + ("danceId" to danceId)
        }
    }

    /**
     * Только метаданные провайдера (имя, размер). Право чтения — временное,
     * из результата выбора: его хватает и после перезапуска процесса
     * (проверено на Realme RMX3741), постоянное право не берём.
     */
    private fun describe(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        } catch (e: Exception) {
            // Метаданные необязательны.
        }
        return mapOf("uri" to uri.toString(), "name" to name, "size" to size)
    }

    companion object {
        private const val CHANNEL = "danceai/video_picker"
        private const val FILES_CHANNEL = "danceai/files"
        private const val REQUEST_PICK = 4207
        private const val REQUEST_SAVE = 4208
        private const val KEY_DANCE = "danceai.pick.danceId"
    }
}
