#!/usr/bin/env python3
"""Add tracked Screen Time sources and monitor target to the generated project."""
import json
import pathlib
import plistlib
import shutil
import subprocess
import uuid

root = pathlib.Path(__file__).resolve().parent.parent
project = root / "safari/Scrollock/Scrollock.xcodeproj/project.pbxproj"
data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project)]))
objects = data["objects"]


def add(isa, **fields):
    key = uuid.uuid4().hex[:24].upper()
    objects[key] = dict(isa=isa, **fields)
    return key


def source(path):
    ref = add("PBXFileReference", path=path, sourceTree="SOURCE_ROOT", lastKnownFileType="sourcecode.swift")
    return add("PBXBuildFile", fileRef=ref)


def configurations(target):
    return [objects[key]["buildSettings"] for key in objects[target["buildConfigurationList"]]["buildConfigurations"]]


targets = {obj["name"]: (key, obj) for key, obj in objects.items() if obj.get("isa") == "PBXNativeTarget"}
app_id, app = targets["Scrollock"]
_, extension = targets["Scrollock Extension"]
for target in (app, extension):
    for settings in configurations(target):
        settings["CODE_SIGN_ENTITLEMENTS"] = "../../native/ScreenTime.entitlements"
        settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
        settings.pop("SWIFT_DEFAULT_ACTOR_ISOLATION", None)
    phase = next(objects[key] for key in target["buildPhases"] if objects[key]["isa"] == "PBXSourcesBuildPhase")
    phase["files"].append(source("../../native/ScreenTimeStore.swift"))
    phase["files"].append(source("../../native/UnlockSchedule.swift"))

shutil.copyfile(root / "native/ViewController.swift", project.parent.parent / "Scrollock/ViewController.swift")
shutil.copyfile(root / "native/SafariWebExtensionHandler.swift", project.parent.parent / "Scrollock Extension/SafariWebExtensionHandler.swift")

product = add("PBXFileReference", path="Scrollock Monitor.appex", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.app-extension", includeInIndex="0")
settings = dict(
    CODE_SIGN_STYLE="Automatic",
    CODE_SIGN_ENTITLEMENTS="../../native/ScreenTime.entitlements",
    CURRENT_PROJECT_VERSION="1",
    MARKETING_VERSION="1.0",
    GENERATE_INFOPLIST_FILE="YES",
    INFOPLIST_FILE="../../native/Monitor-Info.plist",
    IPHONEOS_DEPLOYMENT_TARGET="17.0",
    SDKROOT="iphoneos",
    PRODUCT_BUNDLE_IDENTIFIER="ar.com.poronga.Scrollock.Monitor",
    PRODUCT_NAME="$(TARGET_NAME)",
    SKIP_INSTALL="YES",
    APPLICATION_EXTENSION_API_ONLY="YES",
    SWIFT_VERSION="5.0",
    TARGETED_DEVICE_FAMILY="1,2",
    LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
)
configs = [add("XCBuildConfiguration", name=name, buildSettings=settings.copy()) for name in ("Debug", "Release")]
config_list = add("XCConfigurationList", buildConfigurations=configs, defaultConfigurationName="Release", defaultConfigurationIsVisible="0")
sources = add("PBXSourcesBuildPhase", files=[source("../../native/ScreenTimeStore.swift"), source("../../native/UnlockSchedule.swift"), source("../../native/DeviceActivityMonitorExtension.swift")], buildActionMask="2147483647", runOnlyForDeploymentPostprocessing="0")
frameworks = add("PBXFrameworksBuildPhase", files=[], buildActionMask="2147483647", runOnlyForDeploymentPostprocessing="0")
monitor = add("PBXNativeTarget", name="Scrollock Monitor", productName="Scrollock Monitor", productReference=product, productType="com.apple.product-type.app-extension", buildConfigurationList=config_list, buildPhases=[sources, frameworks], buildRules=[], dependencies=[])
project_object = objects[data["rootObject"]]
project_object["targets"].append(monitor)
target_attributes = project_object.setdefault("attributes", {}).setdefault("TargetAttributes", {})
for target_id in (app_id, targets["Scrollock Extension"][0], monitor):
    capabilities = target_attributes.setdefault(target_id, {}).setdefault("SystemCapabilities", {})
    capabilities["com.apple.ApplicationGroups.iOS"] = {"enabled": 1}
objects[project_object["productRefGroup"]]["children"].append(product)
proxy = add("PBXContainerItemProxy", containerPortal=data["rootObject"], proxyType="1", remoteGlobalIDString=monitor, remoteInfo="Scrollock Monitor")
app["dependencies"].append(add("PBXTargetDependency", target=monitor, targetProxy=proxy))
embed = next(objects[key] for key in app["buildPhases"] if objects[key]["isa"] == "PBXCopyFilesBuildPhase")
embed["files"].append(add("PBXBuildFile", fileRef=product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]}))
project.write_bytes(plistlib.dumps(data))
print("Configured native Screen Time app, Safari bridge, and Device Activity monitor.")
