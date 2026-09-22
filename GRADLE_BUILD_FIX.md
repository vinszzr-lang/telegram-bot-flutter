# Gradle wrapper build fix

The Android project must keep `android/gradle/wrapper/gradle-wrapper.jar` in the repository.

The GitHub Actions workflow also bootstraps Gradle 8.14.5 with `gradle/actions/setup-gradle@v4`
and regenerates the wrapper JAR if it is missing or incomplete. This prevents:

`Could not find or load main class org.gradle.wrapper.GradleWrapperMain`

Before building, the workflow verifies that `GradleWrapperMain.class` exists in the wrapper JAR.
