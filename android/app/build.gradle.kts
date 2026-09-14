import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------- 签名配置（密钥不入库，从 key.properties 读取）----------
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.taohua.mova"
    compileSdk = 36
    // 需取所有依赖中的最高版本：media_kit 的 jni 插件要求 28.2.13676358，
    // 低于该值会构建失败（NDK 向后兼容，取最高即可）。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    defaultConfig {
        // ✅ 修复 1：品牌包名（原 com.example.yingji）
        applicationId = "com.taohua.mova"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 不要在这里设 ndk.abiFilters：与下面的 splits.abi 同时存在会直接报错
        // "Conflicting configuration ... in ndk abiFilters cannot be present
        //  when splits abi filters are set"。ABI 白名单统一由 splits 控制。
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    // ⚠️ 不要在这里配置 splits { abi { ... } }：
    // `flutter build apk --split-per-abi` 自带按 ABI 拆分机制，
    // 手写 splits 会与其冲突，导致 APK 产出到错误目录，
    // Flutter 找不到产物而报 "Gradle build failed to produce an .apk file"。
    // 需要 universal 包时用 `flutter build apk`（不带 --split-per-abi）。

    packaging {
        // 避免多个 .so 打包冲突（media_kit 常见）
        jniLibs { pickFirsts += listOf("**/libmpv.so", "**/libflutter.so") }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FileProvider（把缓存里的 APK 以 content:// 交给系统安装器）来自
    // androidx.core。它本来就会作为 Flutter 嵌入层的传递依赖进来，这里
    // 显式声明一遍是为了让版本可见、好升级。
    implementation("androidx.core:core-ktx:1.13.1")
    // Dolby Vision 必须走系统 MediaCodec + SurfaceView，不能经过 Flutter
    // Texture。Media3 负责选择设备提供的 video/dolby-vision 解码器。
    implementation("androidx.media3:media3-exoplayer:1.11.0")
    implementation("androidx.media3:media3-ui:1.11.0")
}
