#!/usr/bin/env python3
"""Parse the actual PBX project and check cross-target signing/build invariants.

This is structural validation, NOT an Xcode compilation or entitlement approval.
Install: python -m pip install --target .build-support/python openstep-parser==2.0.3
"""
import json
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".build-support/python"))
try:
    from openstep_parser import OpenStepDecoder
except ImportError:
    raise SystemExit("Install openstep-parser==2.0.3 into .build-support/python; see script docstring.")

def check():
    with (ROOT / "NPV.xcodeproj/project.pbxproj").open(encoding="utf-8") as handle:
        project = OpenStepDecoder.ParseFromFile(handle)
    objects = project["objects"]
    root = objects[project["rootObject"]]
    assert root["isa"] == "PBXProject"
    targets = {objects[ref]["name"]: objects[ref] for ref in root["targets"]}
    assert set(targets) == {"NPV", "NPVTunnel", "NPVAppleTests"}
    for obj in objects.values():
        if obj["isa"] == "PBXFileReference" and obj["sourceTree"] == "<group>":
            assert (ROOT / obj["path"]).is_file(), obj["path"]
        for key in ["fileRef", "productRef", "mainGroup", "productReference", "buildConfigurationList", "baseConfigurationReference", "targetProxy", "target"]:
            if key in obj: assert obj[key] in objects, (key, obj[key])
    app = plistlib.loads((ROOT / "Config/App.Info.plist").read_bytes())
    tunnel = plistlib.loads((ROOT / "Config/Tunnel.Info.plist").read_bytes())
    app_ent = plistlib.loads((ROOT / "Config/App.entitlements").read_bytes())
    tunnel_ent = plistlib.loads((ROOT / "Config/Tunnel.entitlements").read_bytes())
    for field in ["NPVAppGroup", "NPVKeychainGroup", "NPVProviderBundleID"]: assert app[field] == tunnel[field]
    assert app_ent == tunnel_ent
    assert app_ent["com.apple.developer.networking.networkextension"] == ["packet-tunnel-provider"]
    assert app_ent["keychain-access-groups"] == [app["NPVKeychainGroup"]]
    assert app_ent["com.apple.security.application-groups"] == [app["NPVAppGroup"]]
    assert tunnel["NSExtension"]["NSExtensionPrincipalClass"] == "$(PRODUCT_MODULE_NAME).PacketTunnelProvider"
    assert "NSAppTransportSecurity" not in app
    privacy = plistlib.loads((ROOT / "Config/PrivacyInfo.xcprivacy").read_bytes())
    assert privacy["NSPrivacyTracking"] is False
    for name, target in targets.items():
        config_list = objects[target["buildConfigurationList"]]
        for ref in config_list["buildConfigurations"]:
            settings = objects[ref]["buildSettings"]
            if name == "NPVTunnel":
                assert settings["APPLICATION_EXTENSION_API_ONLY"] == "YES"
                assert "$(CONFIGURATION_BUILD_DIR)" in settings["LIBRARY_SEARCH_PATHS"]
            if name == "NPVAppleTests": assert settings["TEST_HOST"] == "$(BUILT_PRODUCTS_DIR)/NPV.app/NPV"
        phases = [objects[ref] for ref in target["buildPhases"]]
        if name == "NPVTunnel":
            assert phases[0]["isa"] == "PBXShellScriptBuildPhase"
            assert "/bin/bash" in phases[0]["shellScript"]
        if name == "NPV":
            assert any(p["isa"] == "PBXCopyFilesBuildPhase" and p["dstSubfolderSpec"] == "13" for p in phases)
            assert len(target["dependencies"]) == 1
    scheme = ET.parse(ROOT / "NPV.xcodeproj/xcshareddata/xcschemes/NPV.xcscheme")
    for ref in scheme.findall(".//BuildableReference"): assert ref.attrib["BlueprintIdentifier"] in objects
    lock = json.loads((ROOT / "scripts/dependencies.json").read_text())
    assert lock["wireguardApple"]["revision"] in (ROOT / "scripts/build_wireguard.sh").read_text()
    for file in (ROOT / "scripts").glob("*.sh"):
        assert b"\r" not in file.read_bytes(), f"Shell script must use LF: {file.name}"
    print(f"PASS: PBX syntax, {len(objects)} objects, targets, source paths, entitlements, embedding, bridge, scheme, dependency lock.")

if __name__ == "__main__": check()
