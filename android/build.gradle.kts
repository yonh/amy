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
// dependencies require 34+ — after every project is evaluated (so a
// plugin's own `compileSdk 33` line has already run), raise every
// Android library module's compileSdk to at least 36.
gradle.projectsEvaluated {
    rootProject.subprojects.forEach { sub ->
        sub.extensions.findByName("android")?.let { ext ->
            val android = ext as com.android.build.gradle.LibraryExtension
            if (android.compileSdk == null || android.compileSdk!! < 36) {
                android.compileSdk = 36
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
