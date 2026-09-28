import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.protobuf")
}

android {
    namespace = "com.androidbridge"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.androidbridge"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "1.0.1"
    }

    // Release signing is read from keystore.properties (gitignored) or the
    // matching environment variables. If neither is present the release build
    // falls back to the debug signing key so contributors can still build it.
    // See keystore/README.md for how to create your own key.
    val keystorePropsFile = rootProject.file("keystore.properties")
    val hasReleaseKeystore = keystorePropsFile.exists() ||
        System.getenv("MC_KEYSTORE_FILE") != null

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                val props = Properties()
                if (keystorePropsFile.exists()) {
                    keystorePropsFile.inputStream().use { props.load(it) }
                }
                fun cfg(key: String, env: String): String =
                    props.getProperty(key) ?: System.getenv(env) ?: ""

                storeFile = file(cfg("storeFile", "MC_KEYSTORE_FILE"))
                storePassword = cfg("storePassword", "MC_KEYSTORE_PASSWORD")
                keyAlias = cfg("keyAlias", "MC_KEY_ALIAS")
                keyPassword = cfg("keyPassword", "MC_KEY_PASSWORD")
                // Full signing (v1 JAR + v2 + v3 + v4) — proper hygiene, reduces
                // "tampered app" flags from Play Protect / installers.
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }
}

protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:4.28.2"
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                create("java") {
                    option("lite")
                }
            }
        }
    }
}

dependencies {
    // AndroidX
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.constraintlayout:constraintlayout:2.2.0")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Protobuf
    implementation("com.google.protobuf:protobuf-javalite:4.28.2")

    // QR Code
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("com.google.zxing:core:3.5.3")

    // mDNS / NSD is built into Android SDK — no dependency needed
}
