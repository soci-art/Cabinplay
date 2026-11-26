// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Created by riko chen on 2026-10-14

import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import top.cabinplay.branding.GenerateBrandingResources
import top.cabinplay.plugins.CopyPluginAssets

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    buildFeatures { compose = true }
    namespace = "top.cabinplay.direlay"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        // -Prelay.applicationId=… builds a test APK that upgrades an older install in place.
        applicationId = providers.gradleProperty("relay.applicationId").orNull ?: "top.cabinplay.relay"
        minSdk = 26
        targetSdk = 37
        // Release builds derive both from the tag: -Prelay.versionCode=… -Prelay.versionName=…
        versionCode = providers.gradleProperty("relay.versionCode").orNull?.toInt() ?: 2001
        versionName = providers.gradleProperty("relay.versionName").orNull ?: "0.2.1"
    }

    // Exclude identity assets from every merged dependency. Users provision their own files.
    androidResources {
        ignoreAssetsPattern = "offline-mfi:identity.pk8:certificate.p7b:*.p12:*.pfx:tls.password"
        // The app ships English and Simplified Chinese only, libraries included.
        localeFilters += listOf("en", "zh-rCN")
    }

    buildTypes {
        // Debug shares the release package; export configuration, then uninstall when switching signing keys.
        // relay.applicationId can still target a legacy .debug install to export its settings.
        debug { }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    // Robolectric tests read the merged app and library resources (About and acknowledgement copy).
    testOptions { unitTests.isIncludeAndroidResources = true; unitTests.isReturnDefaultValues = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

composeCompiler {
    stabilityConfigurationFiles.add(layout.projectDirectory.file("compose-stability.conf"))
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("top.cabinplay.diplay:common")
    implementation("top.cabinplay.diplay:shared")
    implementation(libs.kotlin.stdlib)
    implementation(libs.androidx.app.projected)
    implementation("top.cabinplay.stream:core")
    implementation("top.cabinplay.stream:web-server")
    implementation("top.cabinplay.stream:clink")
    implementation("top.cabinplay.stream:cast")
    implementation("top.cabinplay.stream:carlife")
    // mDNS host name for the admin page (cabinplay-android.local).
    implementation("org.jmdns:jmdns:3.6.3")
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.profileinstaller)
    implementation(libs.androidx.compose.material3)
    implementation("androidx.compose.animation:animation")
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.bouncycastle)
    implementation(libs.zxing.core)
    testImplementation(libs.junit)
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation(testFixtures("top.cabinplay.stream:core"))
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:5.13.4")
    testRuntimeOnly("org.junit.vintage:junit-vintage-engine:5.13.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:1.13.4")
}

// Resolve overrides relative to the Android build root, just like settings.gradle.kts.
val streamDir = providers.gradleProperty("stream.dir").orNull
    ?: if (rootProject.file("../third_party/CabinPlay-Stream/kotlin").isDirectory) {
        "../third_party/CabinPlay-Stream/kotlin"
    } else {
        "../../CabinPlay-Stream/kotlin"
    }
val receiverDistDir = rootProject.file(streamDir).resolve("web-receiver/dist")
/** Copies the built browser receiver into generated assets under web/. */
abstract class CopyReceiverAssets : DefaultTask() {
    @get:InputDirectory
    @get:Optional
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val receiverDist: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @get:Inject
    abstract val files: FileSystemOperations

    @TaskAction
    fun copy() {
        files.sync {
            into(outputDirectory)
            if (receiverDist.isPresent) from(receiverDist) { into("web") }
        }
    }
}

val copyReceiverAssets = tasks.register<CopyReceiverAssets>("copyReceiverAssets") {
    if (receiverDistDir.isDirectory) receiverDist.set(receiverDistDir)
    else logger.warn("Stream kotlin/web-receiver/dist is missing at $receiverDistDir; browser receiver will be unavailable.")
}
androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyReceiverAssets, CopyReceiverAssets::outputDirectory)
    }
}
tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    // Use Maven Central's canonical endpoint for Robolectric's separate runtime downloads too.
    systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
    testLogging { exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

// -Pplugins.dir may point at an alternate prebuilt install directory.
val copyPluginAssets = tasks.register<CopyPluginAssets>("copyPluginAssets") {
    val dist = rootProject.file(providers.gradleProperty("plugins.dir").orNull
        ?: "../../CabinPlay-Web-Plugins/dist/install")
    if (dist.isDirectory) pluginDist.set(dist)
    outputDirectory.set(layout.buildDirectory.dir("generated/pluginAssets"))
}
androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyPluginAssets, CopyPluginAssets::outputDirectory)
    }
}

// Mirror the composite-build lookup; include every values XML to cover satellite settings strings.
val diplayDir = providers.gradleProperty("diplay.dir").orNull
    ?: if (rootProject.file("../third_party/CabinPlay-DiPlay").isDirectory) {
        "../third_party/CabinPlay-DiPlay"
    } else {
        "../../CabinPlay-DiPlay"
    }
val brandingInputs = files(listOf("common", "shared").map { module ->
    fileTree(rootProject.file(diplayDir).resolve("$module/src/main/res")) {
        include("values*/**/*.xml")
    }
})
androidComponents {
    onVariants { variant ->
        val generateBranding = tasks.register<GenerateBrandingResources>(
            "generate${variant.name.replaceFirstChar { it.uppercaseChar() }}BrandingResources"
        ) {
            libraryResources.from(brandingInputs)
            manualResources.from(fileTree("src/main/res") { include("values*/**/*.xml") })
            outputDirectory.set(layout.buildDirectory.dir("generated/branding/${variant.name}/res"))
        }
        variant.sources.res?.addGeneratedSourceDirectory(generateBranding, GenerateBrandingResources::outputDirectory)
    }
}

/** Packages only the already-built shared admin page; source ownership stays with admin-web. */
abstract class CopyAdminAssets : DefaultTask() {
    @get:InputDirectory
    @get:Optional
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val adminDist: DirectoryProperty
    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty
    @get:Inject
    abstract val files: FileSystemOperations

    @TaskAction
    fun copy() {
        val dist = adminDist.orNull?.asFile
        check(dist != null && dist.resolve("index.html").isFile) {
            "Admin page assets missing: build ../admin-web/dist (including index.html) before building the APK."
        }
        files.sync { into(outputDirectory); from(dist) { into("admin") } }
    }
}
val copyAdminAssets = tasks.register<CopyAdminAssets>("copyAdminAssets") {
    val dist = rootProject.file("../admin-web/dist")
    if (dist.isDirectory) adminDist.set(dist)
}
androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyAdminAssets, CopyAdminAssets::outputDirectory)
    }
}
