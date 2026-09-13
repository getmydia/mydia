import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing properties from key.properties if it exists
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "dev.mydia.player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.mydia.player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Fall back to debug signing for local development
                signingConfigs.getByName("debug")
            }

            ndk {
                // Release serves physical phones and televisions. x86_64 is
                // kept debug-only for local emulators so it does not add
                // ~62 MB to the shipped APK.
                //
                // Both remaining ABIs are load-bearing. armeabi-v7a is the
                // only one Chromecast with Google TV and most Android TV boxes
                // can run (they have no arm64 userspace); arm64-v8a is the
                // only one Pixel 7 and later can run (they have no 32-bit
                // runtime). The size matters on exactly those devices: a
                // Chromecast with Google TV has a 4 GB /data and routinely
                // sits near full, and an install there failed outright with
                // 517 MB free.
                //
                // Requires disable-abi-filtering=true in ../gradle.properties,
                // or the Flutter Gradle plugin's own defaultConfig list wins.
                abiFilters += listOf("armeabi-v7a", "arm64-v8a")
            }
        }
    }
}

flutter {
    source = "../.."
}
