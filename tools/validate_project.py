"""Structural checks that can run on Windows; not an Apple SDK build."""
import plistlib
import xml.etree.ElementTree as ET
from pathlib import Path

from openstep_parser import OpenStepDecoder

root = Path(__file__).resolve().parent.parent
project = OpenStepDecoder.ParseFromString((root / "BurstLab.xcodeproj/project.pbxproj").read_text())
objects = project["objects"]
project_object = objects[project["rootObject"]]
for target_id in project_object["targets"]:
    target = objects[target_id]
    for phase_id in target["buildPhases"]:
        for build_id in objects[phase_id]["files"]:
            ref = objects[objects[build_id]["fileRef"]]
            if ref["sourceTree"] == "SOURCE_ROOT":
                assert (root / ref["path"]).exists(), ref["path"]
    for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
        settings = objects[config_id]["buildSettings"]
        info = plistlib.loads((root / settings["INFOPLIST_FILE"]).read_bytes())
        assert info["NSCameraUsageDescription"]
        assert info["NSPhotoLibraryAddUsageDescription"]
        assert settings["SDKROOT"] == "iphoneos"
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == "dev.lucas.burstlab.ios"
    print("Valid target references:", target["name"])
for scheme in (root / "BurstLab.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme"):
    tree = ET.parse(scheme)
    for reference in tree.findall(".//BuildableReference"):
        assert objects[reference.attrib["BlueprintIdentifier"]]["isa"] == "PBXNativeTarget"
    print("Valid scheme:", scheme.stem)
print("Structural checks only; native iPhone build happens in GitHub Actions.")
