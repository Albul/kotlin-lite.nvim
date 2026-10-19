plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidMultiplatformLibrary)
}

kotlin {
    android {
        namespace = "sdkdemo.kmp"
        compileSdk = 37
    }
    jvm()
}
