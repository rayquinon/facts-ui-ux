package com.example.facts_ui_ux

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
	private val channelName = "facts.app_update"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"canRequestPackageInstalls" -> {
						result.success(canRequestPackageInstallsCompat())
					}

					"openUnknownSourcesSettings" -> {
						try {
							openUnknownSourcesSettingsCompat()
							result.success(true)
						} catch (e: Exception) {
							result.error("OPEN_SETTINGS_FAILED", e.message, null)
						}
					}

					"installApk" -> {
						val path = call.argument<String>("path")
						if (path.isNullOrBlank()) {
							result.error("ARGUMENT_ERROR", "Missing 'path'", null)
							return@setMethodCallHandler
						}
						try {
							installApkFromPath(path)
							result.success(true)
						} catch (e: Exception) {
							result.error("INSTALL_FAILED", e.message, null)
						}
					}

					else -> result.notImplemented()
				}
			}
	}

	private fun canRequestPackageInstallsCompat(): Boolean {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
		return packageManager.canRequestPackageInstalls()
	}

	private fun openUnknownSourcesSettingsCompat() {
		val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			Intent(
				Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
				Uri.parse("package:$packageName")
			)
		} else {
			Intent(Settings.ACTION_SECURITY_SETTINGS)
		}

		intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		startActivity(intent)
	}

	private fun installApkFromPath(path: String) {
		val file = File(path)
		if (!file.exists()) {
			throw IllegalArgumentException("APK file not found")
		}

		val uri: Uri = FileProvider.getUriForFile(
			this,
			"$packageName.fileprovider",
			file
		)

		val intent = Intent(Intent.ACTION_VIEW)
		intent.setDataAndType(uri, "application/vnd.android.package-archive")
		intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
		startActivity(intent)
	}
}
