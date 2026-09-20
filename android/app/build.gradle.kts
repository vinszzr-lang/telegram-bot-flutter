plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.vinzz.chatwithu"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig { applicationId = "com.vinzz.chatwithu"; minSdk = 24; targetSdk = 36; versionCode = 3; versionName = "1.1.0" }
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
