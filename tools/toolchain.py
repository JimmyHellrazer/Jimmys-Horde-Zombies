import glob
import os
import platform
import re
import shutil
import subprocess
import sys

WINDOWS = platform.system() == "Windows"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "addon")


def steam_roots():
    roots = [os.environ["STEAM_DIR"]] if os.environ.get("STEAM_DIR") else []
    if WINDOWS:
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                roots.append(winreg.QueryValueEx(key, "SteamPath")[0])
        except OSError:
            pass
        roots.append(r"C:\Program Files (x86)\Steam")
    else:
        home = os.path.expanduser("~")
        roots += [os.path.join(home, ".local", "share", "Steam"), os.path.join(home, ".steam", "steam"),
            os.path.join(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam")]
    return [r for r in roots if os.path.isdir(r)]


def steam_libraries():
    found = []
    for root in steam_roots():
        found.append(root)
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        if os.path.exists(vdf):
            text = open(vdf, encoding="utf-8", errors="replace").read()
            found += [p.replace("\\\\", "\\") for p in re.findall(r'"path"\s+"([^"]+)"', text)]
    out = []
    for lib in found:
        lib = os.path.realpath(lib)
        if lib not in out and os.path.isdir(lib):
            out.append(lib)
    return out


def find_game(folder, override=None, env=None):
    path = override or (env and os.environ.get(env))
    if path:
        return path
    for lib in steam_libraries():
        path = os.path.join(lib, "steamapps", "common", folder)
        if os.path.isdir(path):
            return path
    sys.exit(f"could not find {folder}, pass its folder{f' or set {env}' if env else ''}")


def find_program(override, env, names, patterns=()):
    path = override or os.environ.get(env)
    if path:
        return path
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    for pattern in patterns:
        hits = sorted(glob.glob(pattern))
        if hits:
            return hits[-1]
    sys.exit(f"could not find {names[0]}, pass its path or set {env}")


def find_wine():
    if WINDOWS:
        return None
    patterns = []
    for root in steam_roots():
        patterns += [os.path.join(root, "compatibilitytools.d", "*", "files", "bin", "wine"),
            os.path.join(root, "steamapps", "common", "Proton*", "files", "bin", "wine")]
    return find_program(None, "WINE", ["wine"], patterns)


def host_path(path):
    path = os.path.abspath(path)
    return path if WINDOWS else "Z:" + path.replace("/", "\\")


def run_exe(exe, args, cwd=None, log=None, env=None):
    cmd = [exe] + args if WINDOWS else [find_wine(), exe] + args
    full_env = dict(os.environ)
    full_env.setdefault("WINEDEBUG", "-all")
    full_env.update(env or {})
    result = subprocess.run(cmd, cwd=cwd, env=full_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = result.stdout.decode("utf-8", "replace")
    if log:
        open(log, "w", encoding="utf-8").write(text)
    return text


def write_gameinfo(game_dir):
    os.makedirs(game_dir, exist_ok=True)
    open(os.path.join(game_dir, "gameinfo.txt"), "w").write(
        '"GameInfo"\n{\n\tgame "build"\n\tFileSystem\n\t{\n\t\tSteamAppId 4000\n\t\tSearchPaths\n\t\t{\n'
        '\t\t\tgame |gameinfo_path|.\n\t\t}\n\t}\n}\n')
