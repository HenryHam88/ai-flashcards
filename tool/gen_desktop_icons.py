"""桌面图标：先运行 tool/gen_launcher_icon.py，再运行本脚本。
输出 Windows app_icon.ico、macOS AppIcon.appiconset、Linux app_icon.png。"""
from PIL import Image

legacy = Image.open('build/icon_src/legacy_1024.png').convert('RGBA')
mac = Image.open('build/icon_src/mac_1024.png').convert('RGBA')

def sized(src, n):
    return src.resize((n, n), Image.LANCZOS)

sized(legacy, 256).save('windows/runner/resources/app_icon.ico',
                        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
for n in (16, 32, 64, 128, 256, 512, 1024):
    sized(mac, n).save(f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{n}.png', optimize=True)
sized(legacy, 256).save('linux/runner/resources/app_icon.png', optimize=True)
print('done')
