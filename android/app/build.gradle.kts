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
        // flutter_secure_storage (encryptedSharedPreferences) requires API 23+.
        minSdk = flutter.minSdkVersion
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
            // Minification disabled: pointycastle and encrypt use reflection and
            // are not compatible with R8 without a custom keep-rules file.
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
