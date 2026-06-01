import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import javax.inject.Inject
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.TaskAction
import org.gradle.process.ExecOperations

plugins {
    id("com.android.library")
    id("maven-publish")
}

val repoRoot = rootProject.layout.projectDirectory
val generatedRoot = layout.buildDirectory.dir("generated/ejs/android")
val generatedJavaDir = generatedRoot.map { it.dir("java") }
val generatedResourcesDir = generatedRoot.map { it.dir("resources") }
val generatedManifest = generatedRoot.map { it.file("AndroidManifest.xml") }

fun propertyString(name: String, defaultValue: String): String {
    return providers.gradleProperty(name).orElse(defaultValue).get()
}

fun propertyInt(name: String, defaultValue: Int): Int {
    return providers.gradleProperty(name).map(String::toInt).orElse(defaultValue).get()
}

fun detectCompileSdk(defaultValue: Int): Int {
    val sdkDir = providers.environmentVariable("ANDROID_HOME")
        .orElse(providers.environmentVariable("ANDROID_SDK_ROOT"))
        .map(::File)
        .orNull
        ?: File(System.getProperty("user.home"), "Library/Android/sdk")
    val platforms = File(sdkDir, "platforms")
    return platforms.listFiles()
        ?.mapNotNull { file ->
            Regex("""android-(\d+)""").matchEntire(file.name)?.groupValues?.get(1)?.toIntOrNull()
        }
        ?.maxOrNull()
        ?: defaultValue
}

val compileSdkValue = providers.gradleProperty("ejsAndroidCompileSdk")
    .map(String::toInt)
    .orElse(detectCompileSdk(35))
    .get()

val minSdkValue = propertyInt("ejsAndroidMinSdk", 28)
val ejsEngine = propertyString("ejsAndroidEngine", "quickjs-ng")
val ejsRuntimeLoop = propertyString("ejsAndroidRuntimeLoop", "libuv")
val quickJsNgSourceDir = providers.gradleProperty("ejsQuickJsNgSourceDir")
    .orElse(repoRoot.dir("third_party/quickjs-ng").asFile.absolutePath)
    .get()
val libuvSourceDir = providers.gradleProperty("ejsLibuvSourceDir")
    .orElse(repoRoot.dir("third_party/libuv").asFile.absolutePath)
    .get()

android {
    namespace = "com.ejs"
    compileSdk = compileSdkValue

    defaultConfig {
        minSdk = minSdkValue
        consumerProguardFiles("consumer-rules.pro")

        externalNativeBuild {
            cmake {
                targets += "ejs_android_platform"
                arguments += listOf(
                    "-DBUILD_TESTING=OFF",
                    "-DEJS_ENGINE=$ejsEngine",
                    "-DEJS_RUNTIME_LOOP=$ejsRuntimeLoop",
                    "-DEJS_QUICKJS_NG_SOURCE_DIR=$quickJsNgSourceDir",
                    "-DEJS_LIBUV_SOURCE_DIR=$libuvSourceDir"
                )
            }
        }
    }

    sourceSets {
        getByName("main") {
            java.srcDir(generatedJavaDir)
            resources.srcDir(generatedResourcesDir)
            manifest.srcFile(generatedManifest)
        }
    }

    externalNativeBuild {
        cmake {
            path = repoRoot.file("CMakeLists.txt").asFile
        }
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

abstract class GenerateEjsAndroidPackaging @Inject constructor(
    private val execOperations: ExecOperations
) : DefaultTask() {
    @get:Internal
    abstract val repoRootDir: DirectoryProperty

    @get:Input
    abstract val cmakeExecutable: Property<String>

    @get:OutputDirectory
    abstract val cmakeBuildDir: DirectoryProperty

    @get:OutputDirectory
    abstract val cmakeExportDir: DirectoryProperty

    @get:OutputDirectory
    abstract val javaOutputDir: DirectoryProperty

    @get:OutputDirectory
    abstract val resourcesOutputDir: DirectoryProperty

    @get:OutputFile
    abstract val manifestOutputFile: RegularFileProperty

    @TaskAction
    fun generate() {
        val repoRoot = repoRootDir.get().asFile
        val cmakeBuild = cmakeBuildDir.get().asFile
        val cmakeExport = cmakeExportDir.get().asFile
        val javaOutput = javaOutputDir.get().asFile
        val resourcesOutput = resourcesOutputDir.get().asFile
        val manifestOutput = manifestOutputFile.get().asFile

        deleteRecursively(javaOutput)
        deleteRecursively(resourcesOutput)
        manifestOutput.parentFile.mkdirs()

        execOperations.exec {
            commandLine(
                cmakeExecutable.get(),
                "-S", repoRoot.absolutePath,
                "-B", cmakeBuild.absolutePath,
                "-DANDROID=ON",
                "-DBUILD_TESTING=OFF",
                "-DEJS_ENGINE=stub",
                "-DEJS_RUNTIME_LOOP=stub",
                "-DEJS_ANDROID_MODULES_EXPORT_DIR=${cmakeExport.absolutePath}"
            )
        }

        execOperations.exec {
            commandLine(
                cmakeExecutable.get(),
                "--build", cmakeBuild.absolutePath,
                "--target", "ejs_android_modules_export"
            )
        }

        val javaRoots = readLines(File(cmakeExport, "java_source_roots.txt")).map(::File)
        val javaSources = readLines(File(cmakeExport, "java_sources.txt")).map(::File)
        val resourceDirs = readLines(File(cmakeExport, "resource_dirs.txt")).map(::File)
        val platformJavaRoot = File(repoRoot, "platform/android/java")

        copyJavaTree(platformJavaRoot, platformJavaRoot, javaOutput)
        for (source in javaSources) {
            val root = javaRoots.firstOrNull { source.toPath().startsWith(it.toPath()) }
                ?: throw IllegalStateException("No exported Java root contains $source")
            copyJavaFile(root, source, javaOutput)
        }

        for (resourceDir in resourceDirs) {
            copyTree(resourceDir, resourcesOutput)
        }

        val manifestSnippet = File(cmakeExport, "AndroidManifest.permissions.xml")
        if (manifestSnippet.isFile) {
            Files.copy(manifestSnippet.toPath(), manifestOutput.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } else {
            manifestOutput.writeText("<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" />\n")
        }
    }

    private fun readLines(file: File): List<String> {
        if (!file.isFile) return emptyList()
        return file.readLines().map(String::trim).filter(String::isNotEmpty)
    }

    private fun copyJavaTree(root: File, sourceRoot: File, outputRoot: File) {
        if (!root.isDirectory) return
        root.walkTopDown()
            .filter { it.isFile && it.extension == "java" }
            .forEach { copyJavaFile(sourceRoot, it, outputRoot) }
    }

    private fun copyJavaFile(sourceRoot: File, source: File, outputRoot: File) {
        val relative = sourceRoot.toPath().relativize(source.toPath()).toString()
        val destination = File(outputRoot, relative)
        destination.parentFile.mkdirs()
        Files.copy(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }

    private fun copyTree(sourceRoot: File, outputRoot: File) {
        if (!sourceRoot.isDirectory) return
        sourceRoot.walkTopDown()
            .filter(File::isFile)
            .forEach { source ->
                val relative = sourceRoot.toPath().relativize(source.toPath()).toString()
                val destination = File(outputRoot, relative)
                destination.parentFile.mkdirs()
                Files.copy(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
    }

    private fun deleteRecursively(file: File) {
        if (!file.exists()) return
        file.walkBottomUp().forEach { it.delete() }
    }
}

val generateEjsAndroidPackaging = tasks.register<GenerateEjsAndroidPackaging>("generateEjsAndroidPackaging") {
    repoRootDir.set(repoRoot)
    cmakeExecutable.set(providers.gradleProperty("ejsCmakeExecutable").orElse("cmake"))
    cmakeBuildDir.set(layout.buildDirectory.dir("generated/ejs/cmake/build"))
    cmakeExportDir.set(layout.buildDirectory.dir("generated/ejs/cmake/export"))
    javaOutputDir.set(generatedJavaDir)
    resourcesOutputDir.set(generatedResourcesDir)
    manifestOutputFile.set(generatedManifest)
}

tasks.matching {
    it.name == "preBuild" ||
        it.name.startsWith("compile") && it.name.endsWith("JavaWithJavac") ||
        it.name.startsWith("generate") && it.name.endsWith("Sources") ||
        it.name.endsWith("SourcesJar")
}.configureEach {
    dependsOn(generateEjsAndroidPackaging)
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = propertyString("ejsAndroidArtifactGroup", "com.ejs")
                artifactId = propertyString("ejsAndroidArtifactId", "ejs-android")
                version = propertyString("ejsAndroidVersion", "0.1.0-SNAPSHOT")
            }
        }
        repositories {
            maven {
                name = "ejsLocal"
                url = layout.buildDirectory.dir("repo").get().asFile.toURI()
            }
        }
    }
}
