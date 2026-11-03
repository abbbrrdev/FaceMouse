"""Ставит прямое подключение Apple Watch → Mac (Bluetooth). Запуск из корня FaceMouse."""
import os, shutil, sys
here = os.path.dirname(os.path.abspath(__file__))
W = "App/FaceMouseWatch Watch App"
ok = True

def write(src, dst):
    data = open(os.path.join(here, src), "rb").read()
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        b = os.path.join("_backup_2026-10-27", dst)
        os.makedirs(os.path.dirname(b), exist_ok=True)
        if not os.path.exists(b):
            shutil.copyfile(dst, b)
    with open(dst, "wb") as f:
        f.write(data)
    print("ok   ", dst)

# протокол — одинаковый в трёх местах
for dst in ["App/App/FaceProtocol.swift", "AppMac/AppMac/FaceProtocol.swift", f"{W}/FaceProtocol.swift"]:
    write("FaceProtocol.swift", dst)
# Mac
write("BLEHost.swift", "AppMac/AppMac/BLEHost.swift")
write("AppMacApp.swift", "AppMac/AppMac/AppMacApp.swift")
write("ContentView_mac.swift", "AppMac/AppMac/ContentView.swift")
# часы
write("MacLink.swift", f"{W}/MacLink.swift")
write("ContentView_watch.swift", f"{W}/ContentView.swift")
shutil.copyfile("_watch_sources/WristMotion.swift", f"{W}/WristMotion.swift"); print("ok   ", f"{W}/WristMotion.swift")
app = f"{W}/FaceMouseWatchApp.swift"
b = os.path.join("_backup_2026-10-27", app); os.makedirs(os.path.dirname(b), exist_ok=True); shutil.copyfile(app, b)
open(app, "w").write('import SwiftUI\n\n@main\nstruct FaceMouseWatchApp: App {\n    var body: some Scene {\n        WindowGroup {\n            ContentView()\n        }\n    }\n}\n'); print("ok   ", app)

def patch(path, anchor, line, marker):
    global ok
    s = open(path).read()
    if marker in s:
        print("skip ", path); return
    n = s.count(anchor)
    if n == 0:
        print("FAIL ", path, anchor); ok = False; return
    b = os.path.join("_backup_2026-10-27", path); os.makedirs(os.path.dirname(b), exist_ok=True)
    if not os.path.exists(b): shutil.copyfile(path, b)
    out = []
    for l in s.split("\n"):
        out.append(l)
        if l.strip() == anchor.strip():
            indent = l[: len(l) - len(l.lstrip())]
            out.append(indent + line)
    open(path, "w").write("\n".join(out)); print(f"ok    {path} (+{n})")

patch("App/App.xcodeproj/project.pbxproj", "INFOPLIST_KEY_WKWatchOnly = YES;",
      'INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription = "Bluetooth нужен, чтобы подключиться к Mac напрямую";',
      "NSBluetoothAlwaysUsageDescription")
patch("AppMac/AppMac.xcodeproj/project.pbxproj", 'INFOPLIST_KEY_NSLocalNetworkUsageDescription = "Чтобы найти iPhone рядом";',
      'INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription = "Bluetooth нужен, чтобы Apple Watch подключались к Mac напрямую";',
      "NSBluetoothAlwaysUsageDescription")
sys.exit(0 if ok else 1)
