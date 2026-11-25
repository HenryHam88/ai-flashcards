allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// AGP 9.3 的 lint 在分析 image_picker_android 的 ExifDataCopier.java 时，CommentDetector（StopShip / EasterEgg 检查）
// 会崩溃（lint 自身的 bug，插件已是最新版）。只对这个插件关掉这两项检查，其余 lintVital 检查照常运行。
subprojects {
    if (name == "image_picker_android") {
        plugins.withId("com.android.library") {
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                lint {
                    disable += setOf("StopShip", "EasterEgg")
                }
            }
        }
    }
}
