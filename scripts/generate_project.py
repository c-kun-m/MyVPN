#!/usr/bin/env python3
"""Deterministic Xcode project generation using only Python's standard library."""
import hashlib
import json
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

def identifier(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def serialize(value, depth=0):
    tab = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(f"{tab}\t{serialize(str(k))} = {serialize(v, depth+1)};\n" for k,v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{tab}\t{serialize(v, depth+1)},\n" for v in value) + tab + ")"
    return json.dumps(str(value), ensure_ascii=False)

def generate():
    objects = {}
    def add(label, isa, **fields):
        key = identifier(label)
        assert key not in objects
        objects[key] = dict(isa=isa, **fields)
        return key
    config_ref = add("base-config", "PBXFileReference", lastKnownFileType="text.xcconfig", path="Config/Base.xcconfig", sourceTree="<group>")
    files = {}
    groups = []
    for folder in ["Sources/App", "Sources/AppleShared", "Sources/Tunnel", "Tests/AppleTests"]:
        children = []
        for path in sorted((ROOT / folder).glob("*.swift")):
            relative = path.relative_to(ROOT).as_posix()
            files[relative] = add("file:"+relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="<group>")
            children.append(files[relative])
        groups.append(add("group:"+folder, "PBXGroup", name=folder, children=children, sourceTree="<group>"))
    products = {}
    for name, suffix, kind in [("NPV", "app", "wrapper.application"), ("NPVTunnel", "appex", "wrapper.app-extension"), ("NPVAppleTests", "xctest", "wrapper.cfbundle")]:
        products[name] = add("product:"+name, "PBXFileReference", explicitFileType=kind, includeInIndex="0", path=name+"."+suffix, sourceTree="BUILT_PRODUCTS_DIR")
    product_group = add("products", "PBXGroup", name="Products", children=list(products.values()), sourceTree="<group>")
    main_group = add("main", "PBXGroup", children=groups+[config_ref, product_group], sourceTree="<group>")
    packages = {
        "NPVCore": add("package:core", "XCLocalSwiftPackageReference", relativePath="."),
        "WireGuardKit": add("package:wireguard", "XCLocalSwiftPackageReference", relativePath="Vendor/wireguard-apple")
    }
    def configs(label, settings):
        entries = []
        for name in ["Debug", "Release"]:
            build = dict(settings)
            build["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if name == "Debug" else "-O"
            build["DEBUG_INFORMATION_FORMAT"] = "dwarf" if name == "Debug" else "dwarf-with-dsym"
            if name == "Debug":
                build["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
                build["ENABLE_TESTABILITY"] = "YES"
                build["ONLY_ACTIVE_ARCH"] = "YES"
            entries.append(add(label+":"+name, "XCBuildConfiguration", name=name, baseConfigurationReference=config_ref, buildSettings=build))
        return add(label+":list", "XCConfigurationList", buildConfigurations=entries, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
    project_configs = configs("project-configs", {"SDKROOT":"iphoneos", "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator", "ALWAYS_SEARCH_USER_PATHS":"NO"})
    target_ids = {name: identifier("target:"+name) for name in products}
    project_id = identifier("project")
    for name, folders, package_names, product_type, bundle, info, entitlement in [
        ("NPV", ["Sources/App", "Sources/AppleShared"], ["NPVCore"], "com.apple.product-type.application", "$(NPV_BUNDLE_PREFIX)", "App", "App"),
        ("NPVTunnel", ["Sources/Tunnel", "Sources/AppleShared"], ["NPVCore", "WireGuardKit"], "com.apple.product-type.app-extension", "$(NPV_PROVIDER_BUNDLE_ID)", "Tunnel", "Tunnel"),
        ("NPVAppleTests", ["Tests/AppleTests"], [], "com.apple.product-type.bundle.unit-test", "$(NPV_BUNDLE_PREFIX).tests", None, None)
    ]:
        source_files = [add(name+":build:"+path, "PBXBuildFile", fileRef=ref) for path, ref in files.items() if str(Path(path).parent).replace("\\", "/") in folders]
        source_phase = add(name+":sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=source_files, runOnlyForDeploymentPostprocessing="0")
        package_products = []
        framework_files = []
        for package in package_names:
            product = add(name+":pkg:"+package, "XCSwiftPackageProductDependency", package=packages[package], productName=package)
            package_products.append(product)
            framework_files.append(add(name+":link:"+package, "PBXBuildFile", productRef=product))
        framework_phase = add(name+":frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=framework_files, runOnlyForDeploymentPostprocessing="0")
        phases = [source_phase, framework_phase]
        dependencies = []
        if name == "NPVTunnel":
            phase = add("bridge-phase", "PBXShellScriptBuildPhase", buildActionMask="2147483647", files=[], inputPaths=[], outputPaths=[],
                        name="Build pinned WireGuard Go bridge", shellPath="/bin/bash", shellScript='/bin/bash "$SRCROOT/scripts/build_wireguard.sh"',
                        alwaysOutOfDate="1", runOnlyForDeploymentPostprocessing="0")
            phases.insert(0, phase)
        if name in ["NPV", "NPVAppleTests"]:
            dependency_name = "NPVTunnel" if name == "NPV" else "NPV"
            proxy = add(name+":proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType="1", remoteGlobalIDString=target_ids[dependency_name], remoteInfo=dependency_name)
            dependencies.append(add(name+":dependency", "PBXTargetDependency", target=target_ids[dependency_name], targetProxy=proxy))
        if name == "NPV":
            embedded = add("embed-extension-file", "PBXBuildFile", fileRef=products["NPVTunnel"], settings={"ATTRIBUTES":["RemoveHeadersOnCopy"]})
            phases.append(add("embed-extension-phase", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="13", files=[embedded], name="Embed App Extensions", runOnlyForDeploymentPostprocessing="0"))
        settings = {"PRODUCT_NAME":"$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER":bundle}
        if info:
            settings.update({"INFOPLIST_FILE":f"Config/{info}.Info.plist", "GENERATE_INFOPLIST_FILE":"NO", "CODE_SIGN_ENTITLEMENTS":f"Config/{entitlement}.entitlements"})
            resource = add(name+":privacy", "PBXFileReference", lastKnownFileType="text.xml", path="Config/PrivacyInfo.xcprivacy", sourceTree="<group>")
            privacy_build = add(name+":privacy-build", "PBXBuildFile", fileRef=resource)
            phases.append(add(name+":resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[privacy_build], runOnlyForDeploymentPostprocessing="0"))
            objects[main_group]["children"].append(resource)
        else:
            settings.update({"GENERATE_INFOPLIST_FILE":"YES", "TEST_HOST":"$(BUILT_PRODUCTS_DIR)/NPV.app/NPV", "BUNDLE_LOADER":"$(TEST_HOST)"})
        if name == "NPVTunnel":
            settings.update({"APPLICATION_EXTENSION_API_ONLY":"YES", "SKIP_INSTALL":"YES", "LIBRARY_SEARCH_PATHS":["$(inherited)", "$(CONFIGURATION_BUILD_DIR)"]})
        add("target:"+name, "PBXNativeTarget", name=name, productName=name, productReference=products[name], productType=product_type,
            buildConfigurationList=configs(name+":configs", settings), buildPhases=phases, buildRules=[], dependencies=dependencies,
            packageProductDependencies=package_products)
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel":"YES", "LastUpgradeCheck":"1600"},
        buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings="0",
        knownRegions=["en", "zh-Hans", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="",
        packageReferences=list(packages.values()), targets=list(target_ids.values()))
    project = ROOT / "NPV.xcodeproj"
    project.mkdir(exist_ok=True)
    content = {"archiveVersion":"1", "classes":{}, "objectVersion":"56", "objects":objects, "rootObject":project_id}
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n"+serialize(content)+"\n", encoding="utf-8")
    write_plists()
    write_scheme(project, target_ids)
    return objects

def write_plists():
    common = {"CFBundleDevelopmentRegion":"$(DEVELOPMENT_LANGUAGE)", "CFBundleExecutable":"$(EXECUTABLE_NAME)",
              "CFBundleIdentifier":"$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion":"6.0", "CFBundleName":"$(PRODUCT_NAME)",
              "CFBundleShortVersionString":"$(MARKETING_VERSION)", "CFBundleVersion":"$(CURRENT_PROJECT_VERSION)",
              "NPVAppGroup":"$(NPV_APP_GROUP)", "NPVKeychainGroup":"$(NPV_KEYCHAIN_GROUP)", "NPVProviderBundleID":"$(NPV_PROVIDER_BUNDLE_ID)"}
    app = dict(common, CFBundlePackageType="APPL", CFBundleDisplayName="NPV 实验", LSRequiresIPhoneOS=True,
               UILaunchScreen={}, UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes":False},
               UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
    extension = dict(common, CFBundlePackageType="XPC!", NSExtension={"NSExtensionPointIdentifier":"com.apple.networkextension.packet-tunnel",
                                                                  "NSExtensionPrincipalClass":"$(PRODUCT_MODULE_NAME).PacketTunnelProvider"})
    entitlements = {"com.apple.developer.networking.networkextension":["packet-tunnel-provider"],
                    "com.apple.security.application-groups":["$(NPV_APP_GROUP)"], "keychain-access-groups":["$(NPV_KEYCHAIN_GROUP)"]}
    privacy = {"NSPrivacyTracking":False, "NSPrivacyTrackingDomains":[], "NSPrivacyCollectedDataTypes":[],
               "NSPrivacyAccessedAPITypes":[{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons":["C617.1"]}]}
    for name, data in {"App.Info.plist":app, "Tunnel.Info.plist":extension, "App.entitlements":entitlements, "Tunnel.entitlements":entitlements,
                       "PrivacyInfo.xcprivacy":privacy}.items():
        with (ROOT / "Config" / name).open("wb") as handle: plistlib.dump(data, handle, sort_keys=True)

def write_scheme(project, ids):
    def reference(parent, name, extension):
        ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=ids[name],
                      BuildableName=name+extension, BlueprintName=name, ReferencedContainer="container:NPV.xcodeproj")
    scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    for name, ext in [("NPV", ".app"), ("NPVAppleTests", ".xctest")]:
        entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES" if name == "NPV" else "NO",
                              buildForProfiling="YES" if name == "NPV" else "NO", buildForArchiving="YES" if name == "NPV" else "NO", buildForAnalyzing="YES")
        reference(entry, name, ext)
    test = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                         selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="NO", codeCoverageEnabled="YES")
    environment = ET.SubElement(test, "EnvironmentVariables")
    ET.SubElement(environment, "EnvironmentVariable", key="NPV_RUN_NETWORK_TESTS", value="1", isEnabled="NO")
    testable = ET.SubElement(ET.SubElement(test, "Testables"), "TestableReference", skipped="NO")
    reference(testable, "NPVAppleTests", ".xctest")
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", allowLocationSimulation="YES")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), "NPV", ".app")
    profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), "NPV", ".app")
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    path = project / "xcshareddata/xcschemes/NPV.xcscheme"
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(path, encoding="UTF-8", xml_declaration=True)

if __name__ == "__main__":
    result = generate()
    print(f"Generated NPV.xcodeproj ({len(result)} objects).")
