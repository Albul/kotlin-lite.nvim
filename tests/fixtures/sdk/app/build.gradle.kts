plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "sdkdemo"
    compileSdk = libs.versions.android.compileSdk.get().toInt()
}
