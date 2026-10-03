#!/usr/bin/env python3
"""生成无第三方构建依赖的 Xcode 工程；新增 Swift 文件后重新运行。"""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent.parent
project = root / "WiFiSync.xcodeproj"
project.mkdir(exist_ok=True)

def uid(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(value, ensure_ascii=False)

sources = sorted(p.relative_to(root).as_posix() for p in (root / "Sources").rglob("*.swift"))
resource = "THIRD_PARTY_NOTICES.md"
objects = []

def obj(key, value):
    objects.append(f"\t\t{uid(key)} = {{ {value} }};")

for path in sources:
    obj("file:" + path, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(path)}; sourceTree = SOURCE_ROOT;")
    obj("build:" + path, f"isa = PBXBuildFile; fileRef = {uid('file:' + path)};")
obj("license-file", f"isa = PBXFileReference; lastKnownFileType = text; path = {resource}; sourceTree = SOURCE_ROOT;")
obj("license-build", f"isa = PBXBuildFile; fileRef = {uid('license-file')};")
obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = WiFiSync.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("products", f"isa = PBXGroup; children = ({uid('product')}); name = Products; sourceTree = \"<group>\";")
obj("group", "isa = PBXGroup; children = (" + ",".join(uid("file:" + p) for p in sources) + f",{uid('license-file')},{uid('products')}); sourceTree = \"<group>\";")
obj("sources", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" + ",".join(uid("build:" + p) for p in sources) + "); runOnlyForDeploymentPostprocessing = 0;")
obj("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid('license-build')}); runOnlyForDeploymentPostprocessing = 0;")
obj("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
obj("target", f"isa = PBXNativeTarget; buildConfigurationList = {uid('target-configs')}; buildPhases = ({uid('sources')},{uid('frameworks')},{uid('resources')}); buildRules = (); dependencies = (); name = WiFiSync; productName = WiFiSync; productReference = {uid('product')}; productType = \"com.apple.product-type.application\";")
for mode in ["Debug", "Release"]:
    settings = {
        "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "SWIFT_VERSION": "5.0",
        "ARCHS": "arm64", "ONLY_ACTIVE_ARCH": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": "cn.local.WiFiSync", "PRODUCT_NAME": "WiFiSync",
        "INFOPLIST_FILE": "Resources/Info.plist", "CODE_SIGN_ENTITLEMENTS": "Resources/WiFiSync.entitlements",
        "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-", "DEVELOPMENT_TEAM": "",
        "ENABLE_APP_SANDBOX": "YES", "GENERATE_INFOPLIST_FILE": "NO",
        "OTHER_LDFLAGS": "$(inherited) -lsqlite3", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        "SWIFT_EMIT_LOC_STRINGS": "NO", "CLANG_ENABLE_MODULES": "YES",
    }
    body = " ".join(f"{key} = {quoted(value)};" for key, value in settings.items())
    obj("target-" + mode, f"isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ {body} }};")
    obj("project-" + mode, f"isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ }};")
for level in ["target", "project"]:
    obj(level + "-configs", f"isa = XCConfigurationList; buildConfigurations = ({uid(level + '-Debug')},{uid(level + '-Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;")
obj("project", f"isa = PBXProject; attributes = {{ LastUpgradeCheck = 1620; }}; buildConfigurationList = {uid('project-configs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN,en,Base); mainGroup = {uid('group')}; productRefGroup = {uid('products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({uid('target')});")
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {uid('project')};\n}}\n")
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="WiFiSync.app" BlueprintName="WiFiSync" ReferencedContainer="container:WiFiSync.xcodeproj"/>'
(schemes / "WiFiSync.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1620" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("已生成 WiFiSync.xcodeproj")
