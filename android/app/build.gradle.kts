plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.chengvar.dsh_pocket"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.chengvar.dsh_pocket"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ---------------------------------------------------------------------------
// 明文 HTTP 的内网豁免
//
// 局域网入口通常是 http://（无 TLS），而 Android 9+ 默认禁明文，
// 所以 res/xml/network_security_config.xml 里要填一个具体 host。
//
// 但那个 host 是**每台机器自己的内网地址**，不该硬编码进开源仓库，
// 所以仓库里那份是个"安全默认值"（invalid.invalid = 谁都不豁免），
// 需要连内网的人构建时传：
//
//   flutter build apk --release -P dshCleartextHost=10.0.0.5
//
// 实现说明（踩过的坑，别再试这些）：
//   * manifestPlaceholders **不生效** —— 它只替换 AndroidManifest.xml，
//     res/xml/ 下的占位符会原样进 APK（已实测）。
//   * 往 build/generated 加一个额外 res 源目录会被 AGP 9 的
//     "uses this output without declaring an explicit or implicit dependency"
//     一路拦截，逐个补 dependsOn 是打地鼠。
//   * resValue 只能生成 string/bool 之类，造不出 <domain> 元素。
//
// 所以就用最直白的办法：构建前把这个文件重写一遍。
// 仓库里那份始终是合法且安全的，不传属性也能正常构建。
//
// 注意**不要**在 application 上开 android:usesCleartextTraffic="true" ——
// 那是对所有域名放开明文，是 AGENTS.md 雷区 8 明确禁止的做法。
// ---------------------------------------------------------------------------
val dshCleartextHost: String =
    (project.findProperty("dshCleartextHost") as String?)?.trim().orEmpty()
        .ifEmpty { "invalid.invalid" }

val dshNetworkSecurityConfig: File =
    file("src/main/res/xml/network_security_config.xml")

tasks.register("dshWriteNetworkSecurityConfig") {
    val outFile = dshNetworkSecurityConfig
    val host = dshCleartextHost
    // 声明成输入：改 -P 值会触发重跑，值没变则跳过。
    inputs.property("dshCleartextHost", host)
    outputs.upToDateWhen { false }
    doLast {
        val xml = """
            |<?xml version="1.0" encoding="utf-8"?>
            |<!--
            |  由 android/app/build.gradle.kts 在构建时重写，请勿手改。
            |  当前豁免的明文 host：$host
            |  改它用 -P dshCleartextHost=<host>，说明见 build.gradle.kts。
            |-->
            |<network-security-config>
            |    <domain-config cleartextTrafficPermitted="true">
            |        <domain includeSubdomains="false">$host</domain>
            |    </domain-config>
            |</network-security-config>
            |""".trimMargin()
        outFile.writeText(xml)
    }
}

// 挂到 preBuild 上：所有变体的构建都会先经过它，不用猜任务名。
tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn("dshWriteNetworkSecurityConfig")
}

flutter {
    source = "../.."
}
