allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 关键：把构建输出重定向到 <仓库>/build（与官方 Flutter 工程模板一致）。
// Flutter 工具在 <仓库>/build/app/outputs/flutter-apk/ 查找 APK 产物；
// 缺了这两段，:app 会输出到 android/app/build/，flutter 会报
// "Gradle build failed to produce an .apk file"。
rootProject.layout.buildDirectory.value(rootProject.layout.buildDirectory.dir("../../build").get())

subprojects {
    project.layout.buildDirectory.value(rootProject.layout.buildDirectory.dir(project.name).get())
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
