plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.vinzz.chatwithu"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig { applicationId = "com.vinzz.chatwithu"; minSdk = 24; targetSdk = 36; versionCode = 4; versionName = "1.2.0" }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
    buildTypes {
        getByName("release") {
            // Test/distribution build: sign release with the runner's debug keystore so
            // the APK is a valid installable APK. Replace with a real release keystore
            // before publishing to an app store.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
flutter { source = "../.." }
