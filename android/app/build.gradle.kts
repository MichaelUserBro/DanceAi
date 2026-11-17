import java.io.InputStreamReader
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Подпись релиза: android/key.properties (в git не попадает; образец —
// android/key.properties.example). Без него release-сборка останавливается
// с понятной ошибкой, а не подписывается debug-ключом. Debug-сборки — как раньше.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        InputStreamReader(keystorePropertiesFile.inputStream(), Charsets.UTF_8).use { load(it) }
    }
}
val signingKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

fun releaseSigningProblem(): String? {
    if (!keystorePropertiesFile.exists()) {
        return "нет файла ${keystorePropertiesFile.path} (образец — key.properties.example)"
    }
    val missing = signingKeys.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) return "в key.properties не заполнено: ${missing.joinToString()}"
    val store = file(keystoreProperties.getProperty("storeFile"))
    if (!store.exists()) return "файл ключа из storeFile не найден: ${store.path}"
    return null
}

android {
    namespace = "com.danceai.dance_ai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.danceai.dance_ai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Нативные библиотеки (FFmpeg) — сжатыми в APK: APK почти вдвое меньше,
    // ценой распаковки при установке.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        create("release") {
            if (releaseSigningProblem() == null) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Проверка до начала release-сборки (APK и AAB): без ключа — остановка.
val checkReleaseSigning = tasks.register("checkReleaseSigning") {
    doFirst {
        releaseSigningProblem()?.let {
            throw GradleException("Release-сборка не подписана: $it. См. CLAUDE.md, раздел «Подпись».")
        }
    }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(checkReleaseSigning)
}
