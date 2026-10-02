plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.headsup.heads_up"
    // compileSdk 36: androidx.core 1.17.0 (transitive) requires it.
    // Deviation from architecture.md §4, which specified 35.
    // targetSdk stays 35 so we don't opt into new runtime behaviors.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.headsup"
        minSdk = 30 // Required for LiteRT-LM (flutter_gemma_litertlm)
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // LiteRT-LM is 64-bit only; strips 32-bit libs
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // minifyEnabled is false by default in AGP — left off deliberately
            // (architecture.md §4: keep false during hackathon, debug easier).
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
