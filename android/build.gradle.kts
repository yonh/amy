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

// Plugins like desktop_drop declare compileSdk 33 while their androidx
// dependencies require 34+ — force every Android library module to 36 as
// the plugin is applied.
subprojects {
    pluginManager.withPlugin("com.android.library") {
        val android =
            extensions.getByName("android") as com.android.build.gradle.LibraryExtension
        if (android.compileSdk == null || android.compileSdk!! < 36) {
            android.compileSdk = 36
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
