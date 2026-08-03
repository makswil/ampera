plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_face_scan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Replace before Play Store / enterprise export (must be unique).
        applicationId = "com.example.flutter_face_scan"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Optional release signing: create `android/key.properties` (gitignored) with
    // storeFile / storePassword / keyAlias / keyPassword, then uncomment below.
    // val keystorePropertiesFile = rootProject.file("key.properties")
    // val keystoreProperties = java.util.Properties()
    // if (keystorePropertiesFile.exists()) {
    //     keystoreProperties.load(java.io.FileInputStream(keystorePropertiesFile))
    // }
    // signingConfigs {
    //     create("release") {
    //         keyAlias = keystoreProperties["keyAlias"] as String
    //         keyPassword = keystoreProperties["keyPassword"] as String
    //         storeFile = file(keystoreProperties["storeFile"] as String)
    //         storePassword = keystoreProperties["storePassword"] as String
    //     }
    // }

    buildTypes {
        release {
            // Debug signing keeps `flutter run --release` working locally.
            // For store export: wire signingConfigs.release (see above) and
            // set signingConfig = signingConfigs.getByName("release").
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
