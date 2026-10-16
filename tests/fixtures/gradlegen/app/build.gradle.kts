plugins {
    alias(libs.plugins.kotlin.jvm)
}

android {
    defaultConfig {
        versionName = "1.2"
        buildConfigField("Boolean", "LOGS", "false")
    }
    buildTypes {
        debug {
            buildConfigField("String", "API_URL", "\"https://dev.example.com\"")
        }
        release {
            buildConfigField("String", "API_URL", "\"https://example.com\"")
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinJvm)
    implementation(libs.bundles.ui)
    implementation(projects.coreUi)
    println(libs.versions.kotlin.get())
}
