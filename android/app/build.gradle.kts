import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
//
// Secrets are resolved in this order:
//   1. environment variables (CI / local shell, e.g. `PHOTOJPG_STORE_PASSWORD`)
//   2. android/key.properties (git-ignored local file)
//
// Nothing is read from the repository and *no* build is aborted while Gradle
// configures the project: a checkout without signing material still builds a
// release APK signed with the debug key so that `flutter build apk` and the CI
// workflow keep working. The warning makes the resulting artifact obvious.
// ---------------------------------------------------------------------------
val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties().apply {
    if (signingPropertiesFile.isFile) {
        signingPropertiesFile.inputStream().use(::load)
    }
}

fun signingValue(propertyName: String, environmentName: String): String? {
    val environment = System.getenv(environmentName)
    if (!environment.isNullOrBlank()) return environment
    val stored = signingProperties.getProperty(propertyName)
    return stored?.takeIf { it.isNotBlank() }
}

val releaseStoreFile = signingValue("storeFile", "PHOTOJPG_STORE_FILE")
val releaseStorePassword = signingValue("storePassword", "PHOTOJPG_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "PHOTOJPG_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "PHOTOJPG_KEY_PASSWORD")

val resolvedKeystore =
    releaseStoreFile?.let { rootProject.file(it) }?.takeIf { it.isFile }

// Values that were supplied but are unusable are a configuration error and must
// fail the build: silently falling back to the debug key would ship an unsigned
// update while looking successful. The fallback below therefore only applies
// when *nothing* was configured.
val missingSigningValues = buildList {
    if (releaseStoreFile != null && resolvedKeystore == null) {
        add("storeFile '$releaseStoreFile' does not point to an existing file")
    }
    if (releaseStorePassword == null) add("storePassword is missing")
    if (releaseKeyAlias == null) add("keyAlias is missing")
    if (releaseKeyPassword == null) add("keyPassword is missing")
}
val anySigningValueProvided =
    releaseStoreFile != null ||
        releaseStorePassword != null ||
        releaseKeyAlias != null ||
        releaseKeyPassword != null
val hasReleaseSigning = anySigningValueProvided && missingSigningValues.isEmpty()

if (anySigningValueProvided && missingSigningValues.isNotEmpty) {
    throw GradleException(
        "[photo-jpg] Release signing is incomplete: " +
            missingSigningValues.joinToString("; ") +
            ". Provide all four values (PHOTOJPG_STORE_FILE, " +
            "PHOTOJPG_STORE_PASSWORD, PHOTOJPG_KEY_ALIAS, PHOTOJPG_KEY_PASSWORD) " +
            "or remove them all to build with the debug key.",
    )
}

android {
    namespace = "com.jules.docscanner.doc_scanner_app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.jules.docscanner.doc_scanner_app"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = resolvedKeystore
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Debug key: usable for testing, never for distribution.
                signingConfig = signingConfigs.getByName("debug")
            }
            // Minification is intentionally left at its previous setting: R8
            // cannot be verified here, and the native plugins in use
            // (opencv_dart JNI, ML Kit, image_editor) need their consumer rules
            // to be proven first. The proguard file stays wired for when that
            // verification can run.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

if (!hasReleaseSigning) {
    logger.warn(
        "[photo-jpg] Release signing is not configured; the release APK will be " +
            "signed with the debug key. Provide PHOTOJPG_STORE_FILE / " +
            "PHOTOJPG_STORE_PASSWORD / PHOTOJPG_KEY_ALIAS / PHOTOJPG_KEY_PASSWORD " +
            "or an android/key.properties file (see android/key.properties.example).",
    )
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
