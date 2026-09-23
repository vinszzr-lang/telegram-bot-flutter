plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.vinzz.chatwithu"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        applicationId = "com.vinzz.chatwithu"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = 8
        versionName = "2.0.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        getByName("release") {
            // Test/distribution build: use the runner's debug keystore so the APK
            // is installable in CI. Replace with a real release keystore before
            // publishing to Google Play or another public store.
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
