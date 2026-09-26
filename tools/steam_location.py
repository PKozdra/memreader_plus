import re
import winreg
from pathlib import Path

WARHAMMER_3_APP_ID = 1142710


def steam_dir() -> Path:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
        return Path(winreg.QueryValueEx(key, "SteamPath")[0])


def library_dirs() -> list[Path]:
    text = (steam_dir() / "steamapps" / "libraryfolders.vdf").read_text(encoding="utf-8")
    return [Path(path.replace("\\\\", "\\")) for path in re.findall(r'"path"\s+"([^"]+)"', text)]


def app_dir(app_id: int) -> Path:
    for library in library_dirs():
        manifest = library / "steamapps" / f"appmanifest_{app_id}.acf"
        if manifest.exists():
            install_dir = re.search(r'"installdir"\s+"([^"]+)"', manifest.read_text(encoding="utf-8"))
            if install_dir:
                return library / "steamapps" / "common" / install_dir.group(1)
    raise FileNotFoundError(f"Steam app {app_id} is not installed in any Steam library")


def warhammer_3_dir() -> Path:
    return app_dir(WARHAMMER_3_APP_ID)
