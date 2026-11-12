plugins {
    id("com.android.application")
}

val upstream = rootProject.projectDir.resolve("../../third_party/fongmi-tv")

android {
    // catvod contains resources compiled against this upstream namespace.
    namespace = "com.github.catvod.crawler"
    compileSdk = 37

    sourceSets {
        getByName("main") {
            java.srcDir(upstream.resolve("catvod/src/main/java"))
            java.srcDir(upstream.resolve("quickjs/src/main/java"))
            assets.srcDir(upstream.resolve("quickjs/src/main/assets"))
            res.srcDir(upstream.resolve("catvod/src/main/res"))
        }
    }

    defaultConfig {
        applicationId = "app.firepick.bridge"
        minSdk = 24
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
        ndk.abiFilters += "arm64-v8a"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
        isCoreLibraryDesugaringEnabled = true
    }

    packaging {
        resources.excludes += setOf(
            "META-INF/DEPENDENCIES",
            "META-INF/LICENSE",
            "META-INF/LICENSE.txt",
            "META-INF/NOTICE",
            "META-INF/NOTICE.txt",
            "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
        )
    }

    configurations.configureEach {
        resolutionStrategy.force(
            "org.bouncycastle:bcprov-jdk18on:1.78.1",
            "org.bouncycastle:bcpkix-jdk18on:1.78.1",
            "org.bouncycastle:bcutil-jdk18on:1.78.1",
        )
    }
}

dependencies {
    implementation(files(upstream.resolve("quickjs/libs/wrapper-java.jar")))
    implementation(files(upstream.resolve("quickjs/libs/runtime-release.aar")))

    implementation("androidx.annotation:annotation:1.9.1")
    implementation("androidx.collection:collection:1.5.0")
    implementation("androidx.core:core:1.16.0")
    implementation("androidx.preference:preference:1.2.1")
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.78.1")
    implementation("org.brotli:dec:0.1.2")
    implementation("com.google.code.gson:gson:2.14.0")
    implementation("com.google.guava:guava:33.7.2-android")
    implementation("com.googlecode.juniversalchardet:juniversalchardet:1.0.3")
    implementation("com.orhanobut:logger:2.2.0")
    implementation("com.squareup.okhttp3:okhttp:5.5.0")
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:5.5.0")
    implementation("com.squareup.okhttp3:logging-interceptor:5.5.0")
    implementation("com.github.thegrizzlylabs:sardine-android:0.9")
    implementation("com.hierynomus:smbj:0.15.0")
    implementation("com.google.zxing:core:3.5.4")
    implementation("org.jsoup:jsoup:1.23.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
}

