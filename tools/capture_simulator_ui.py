"""Render the actual iPhone UI on a disposable SE2022 simulator; not camera QA."""
import json
from pathlib import Path
import subprocess
import uuid


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    app = Path("build/ios-simulator/Build/Products/Debug-iphonesimulator/BurstLab-iOS.app")
    assert app.is_dir()
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    available = [r for r in runtimes if r.get("isAvailable") and "iOS" in r["name"]]
    assert available, "No iOS simulator runtime installed"
    runtime = max(available, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"]
    device = run("xcrun", "simctl", "create", "BurstLab SE UI review",
                 "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation", runtime)
    uuid.UUID(device)  # Cleanup only the one device created by this script.
    destination = Path("build/ui-review/iphone-se-2022.png")
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        run("xcrun", "simctl", "boot", device)
        run("xcrun", "simctl", "bootstatus", device, "-b")
        run("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
        run("xcrun", "simctl", "install", device, str(app))
        run("xcrun", "simctl", "launch", device, "dev.lucas.burstlab.ios")
        # simctl launch returns before the first scene is drawn. Wait via the
        # simulator process, not a fixed multi-minute sleep on the agent.
        import time
        time.sleep(10)
        run("xcrun", "simctl", "io", device, "screenshot", str(destination))
        print("Actual SE2022 simulator UI saved:", destination)
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], check=False)
        subprocess.run(["xcrun", "simctl", "delete", device], check=False)


if __name__ == "__main__":
    main()
