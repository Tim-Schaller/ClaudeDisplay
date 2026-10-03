# Ersetzt lokale Pfade in __FILE__ (u. a. in den Log-Makros des Arduino-Cores) durch
# neutrale Präfixe, damit gebaute Firmware keine Benutzernamen oder Ordner enthält.
Import("env")

from os.path import abspath

prefixes = {
    env.subst("$PROJECT_CORE_DIR"): "pio",  # z. B. %USERPROFILE%\.platformio
    env.subst("$PROJECT_DIR"): "project",
}
for path, neutral in prefixes.items():
    path = abspath(path)
    for variant in {path, path.replace("\\", "/")}:
        env.Append(CCFLAGS=["-fmacro-prefix-map=%s=%s" % (variant, neutral)])
