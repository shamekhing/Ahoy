import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseSigningProperties = keystorePropertiesFile.exists()

if (hasReleaseSigningProperties) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun releaseSigningProperty(name: String): String {
    return keystoreProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("Missing '$name' in android/key.properties")
}

fun releaseStoreFile(): File {
    val path = releaseSigningProperty("storeFile")
    val configuredFile = File(path)
    return if (configuredFile.isAbsolute) configuredFile else rootProject.file(path)
}

android {
    namespace = "com.ahoy.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.ahoy.app"
        // Pinned explicitly: flutter_secure_storage (encryptedSharedPreferences)
        // requires API 23+, and relying on the Flutter toolchain default would
        // silently lower it again on a toolchain bump (round 7).
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigningProperties) {
            create("release") {
                keyAlias = releaseSigningProperty("keyAlias")
                keyPassword = releaseSigningProperty("keyPassword")
                storePassword = releaseSigningProperty("storePassword")
                storeFile = releaseStoreFile()
            }
        }
    }

    buildTypes {
        release {
            signingConfigs.findByName("release")?.let {
                signingConfig = it
            }
            // R8 stays disabled until a release keystore exists (see
            // key.properties below): enabling minification without a build to
            // verify against risks shipping an app that crashes on first
            // launch. Fifth-review L-11 asked for R8 with keep rules; the
            // original comment blamed reflection in pointycastle/encrypt,
            // which is doubtful. The actual blocker is validation: enable R8
            // with keep rules for pointycastle, encrypt and the plugins in
            // the same change as a verified release build once key.properties
            // is present on the build machine.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

gradle.taskGraph.whenReady {
    val releaseTaskRequested = allTasks.any { task ->
        task.path.contains("Release") &&
            (task.path.contains("assemble") || task.path.contains("bundle"))
    }
    if (releaseTaskRequested && !hasReleaseSigningProperties) {
        throw GradleException(
            "Release builds require android/key.properties with storeFile, " +
                "storePassword, keyPassword, and keyAlias. Debug signing is not " +
                "used for release builds.",
        )
    }
}
