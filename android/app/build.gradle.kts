import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = rootProject.file("key.properties")
if (!signingPropertiesFile.isFile) {
    throw GradleException(
        "Missing android/key.properties. Create it from android/key.properties.example " +
            "before building a release APK.",
    )
}

val signingProperties = Properties().apply {
    signingPropertiesFile.inputStream().use(::load)
}
val signingStoreFile = rootProject.file(
    signingProperties.getProperty("storeFile")
        ?: throw GradleException("Missing storeFile in android/key.properties"),
)
if (!signingStoreFile.isFile) {
    throw GradleException("Signing keystore not found: ${signingStoreFile.path}")
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.jules.docscanner.doc_scanner_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = signingStoreFile
            storePassword = signingProperties.getProperty("storePassword")
                ?: throw GradleException("Missing storePassword in android/key.properties")
            keyAlias = signingProperties.getProperty("keyAlias")
                ?: throw GradleException("Missing keyAlias in android/key.properties")
            keyPassword = signingProperties.getProperty("keyPassword")
                ?: throw GradleException("Missing keyPassword in android/key.properties")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
