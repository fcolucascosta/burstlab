"""Generate the BurstLab iOS target without installing XcodeGen on Windows."""
import hashlib
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TARGET = "BurstLab-iOS"
SOURCES = [
    "Apple/BurstLabApp.swift",
    "Apple/ContentView.swift",
    "Apple/CameraController.swift",
    "Apple/BurstProcessor.swift",
    "Apple/BurstDiagnostics.swift",
    "Apple/CameraPreview.swift",
    "Shared/BurstConfig.swift",
]


def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def q(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def generate():
    objects = []

    def obj(key, kind, body):
        objects.append(f"{uid(key)} = {{ isa = {kind}; {body} }};")
        return uid(key)

    def array(values):
        return "(" + ", ".join(values) + ")"

    references = {}
    for source in SOURCES:
        references[source] = obj(
            source,
            "PBXFileReference",
            f"lastKnownFileType = sourcecode.swift; path = {q(source)}; sourceTree = SOURCE_ROOT;",
        )

    product = obj(
        TARGET + ".app",
        "PBXFileReference",
        f"explicitFileType = wrapper.application; path = {q(TARGET + '.app')}; sourceTree = BUILT_PRODUCTS_DIR;",
    )
    builds = [obj(TARGET + source, "PBXBuildFile", f"fileRef = {references[source]};") for source in SOURCES]
    source_phase = obj(
        TARGET + "sources",
        "PBXSourcesBuildPhase",
        f"buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;",
    )
    framework_phase = obj(
        TARGET + "frameworks",
        "PBXFrameworksBuildPhase",
        "buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
    )
    resources_phase = obj(
        TARGET + "resources",
        "PBXResourcesBuildPhase",
        "buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;",
    )

    configs = []
    for config in ["Debug", "Release"]:
        settings = {
            "SDKROOT": "iphoneos",
            "PRODUCT_NAME": TARGET,
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.lucas.burstlab.ios",
            "INFOPLIST_FILE": "Apple/Info-iOS.plist",
            "GENERATE_INFOPLIST_FILE": "NO",
            "CODE_SIGN_STYLE": "Automatic",
            "SWIFT_VERSION": "5.0",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if config == "Debug" else "",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
            "TARGETED_DEVICE_FAMILY": "1",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        }
        body = " ".join(f"{key} = {q(value)};" for key, value in settings.items())
        configs.append(obj(TARGET + config, "XCBuildConfiguration", f"buildSettings = {{ {body} }}; name = {config};"))
    config_list = obj(
        TARGET + "configs",
        "XCConfigurationList",
        f"buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;",
    )
    target = obj(
        TARGET,
        "PBXNativeTarget",
        f"buildConfigurationList = {config_list}; buildPhases = {array([source_phase, framework_phase, resources_phase])}; "
        f"buildRules = (); dependencies = (); name = {q(TARGET)}; productName = {q(TARGET)}; "
        f"productReference = {product}; productType = {q('com.apple.product-type.application')};",
    )

    info = {
        "CFBundleDisplayName": "BurstLab",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleShortVersionString": "0.2.7",
        "CFBundleVersion": "1",
        "NSCameraUsageDescription": "BurstLab usa a camera para capturar e processar fotos computacionais.",
        "NSPhotoLibraryAddUsageDescription": "BurstLab salva as fotos capturadas na sua fototeca.",
        "UILaunchScreen": {},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        "LSRequiresIPhoneOS": True,
        "UIFileSharingEnabled": True,
        "LSSupportsOpeningDocumentsInPlace": True,
    }
    (ROOT / "Apple" / "Info-iOS.plist").write_bytes(plistlib.dumps(info))

    product_group = obj("products", "PBXGroup", f"children = {array([product])}; name = Products; sourceTree = {q('<group>')};")
    group = obj("root", "PBXGroup", f"children = {array(list(references.values()) + [product_group])}; sourceTree = {q('<group>')};")
    project_configs = [
        obj("project" + name, "XCBuildConfiguration", f"buildSettings = {{ CLANG_ENABLE_MODULES = YES; }}; name = {name};")
        for name in ["Debug", "Release"]
    ]
    project_config_list = obj(
        "projectconfigs",
        "XCConfigurationList",
        f"buildConfigurations = {array(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;",
    )
    project = obj(
        "project",
        "PBXProject",
        f"attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {project_config_list}; "
        f"compatibilityVersion = {q('Xcode 14.0')}; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); "
        f"mainGroup = {group}; productRefGroup = {product_group}; projectDirPath = {q('')}; projectRoot = {q('')}; "
        f"targets = {array([target])};",
    )

    project_dir = ROOT / "BurstLab.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text(
        "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
        + "\n".join(objects)
        + f"\n}}; rootObject = {project}; }}\n",
        encoding="utf-8",
    )

    scheme_dir = project_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    reference = (
        f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" '
        f'BuildableName="{TARGET}.app" BlueprintName="{TARGET}" ReferencedContainer="container:BurstLab.xcodeproj" />'
    )
    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables /></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug" /><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES" />
</Scheme>'''
    (scheme_dir / f"{TARGET}.xcscheme").write_text(xml, encoding="utf-8")
    print(f"Generated: {project_dir}")


if __name__ == "__main__":
    generate()
