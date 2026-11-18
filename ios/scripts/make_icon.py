#!/usr/bin/env python3
"""Render the 1024px iOS app icon (stdlib only).

    python3 ios/scripts/make_icon.py

Reuses the shield renderer from web/dev/make_icons.py so the iPhone app and the web
app share one icon. iOS applies the rounded mask itself, so the PNG is a full-bleed
opaque square.
"""

import importlib.util
import os
import sys

# Importing the web renderer must not leave __pycache__ behind in web/.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WEB_RENDERER = os.path.join(ROOT, "web", "dev", "make_icons.py")
OUT = os.path.join(os.path.dirname(HERE), "ScamShield", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")


def main():
    spec = importlib.util.spec_from_file_location("make_icons", WEB_RENDERER)
    icons = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(icons)
    with open(OUT, "wb") as f:
        f.write(icons.render(1024))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
