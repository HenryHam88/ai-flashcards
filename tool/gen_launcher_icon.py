"""生成启动图标图层（1024px 源图）：python3 tool/gen_launcher_icon.py，输出到 build/icon_src/。
需要 google-chrome；之后用 PIL 缩放到各 mipmap 密度。
桌面图标：python3 tool/gen_desktop_icons.py（用 legacy / mac 两张源图）。"""
import os, subprocess
OUT = 'build/icon_src'
os.makedirs(OUT, exist_ok=True)
# 卡片图形，定义在 512 坐标系，中心约 (256,276)
DEFS = '''
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#A9BCA5"/><stop offset="1" stop-color="#7E9688"/></linearGradient>
<linearGradient id="c1" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#F1ECE4"/></linearGradient>
<filter id="s" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#3E4A3C" flood-opacity=".28"/></filter>
'''
CARDS = '''
<g transform="rotate(-10 256 270)"><rect x="130" y="150" width="230" height="290" rx="34" fill="#D9CBB4" filter="url(#s)"/></g>
<g transform="rotate(6 256 256)"><rect x="150" y="120" width="230" height="290" rx="34" fill="url(#c1)" filter="url(#s)"/>
<rect x="188" y="176" width="120" height="16" rx="8" fill="#8FA68B"/>
<rect x="188" y="212" width="154" height="12" rx="6" fill="#C9C3BA"/>
<rect x="188" y="238" width="134" height="12" rx="6" fill="#C9C3BA"/>
<path d="M300 300 l10 26 l26 10 l-26 10 l-10 26 l-10 -26 l-26 -10 l26 -10z" fill="#C79B9B"/></g>
'''
MONO = '''
<mask id="m"><rect width="512" height="512" fill="black"/>
<g transform="rotate(-10 256 270)"><rect x="130" y="150" width="230" height="290" rx="34" fill="#777"/></g>
<g transform="rotate(6 256 256)"><rect x="142" y="112" width="246" height="306" rx="40" fill="black"/>
<rect x="150" y="120" width="230" height="290" rx="34" fill="white"/>
<rect x="188" y="176" width="120" height="16" rx="8" fill="black"/>
<rect x="188" y="212" width="154" height="12" rx="6" fill="black"/>
<rect x="188" y="238" width="134" height="12" rx="6" fill="black"/>
<path d="M300 300 l10 26 l26 10 l-26 10 l-10 26 l-10 -26 l-26 -10 l26 -10z" fill="black"/></g></mask>
<rect width="512" height="512" fill="white" mask="url(#m)"/>
'''
# 自适应图标：108dp 画布，安全区直径 66dp。卡片组外接框约 260x330（512 坐标），
# 对角线约 420 → 缩放到 66/108 画布内：在 512 画布上整体缩放 s，使对角线 ≤ 0.61*512
FG_SCALE = 0.60 * 512 / 420  # ≈0.73，对角线占画布 60%，落在安全圆内
def fg_group(inner):
    # 把卡片中心 (256,276) 移到画布中心并缩放
    return f'<g transform="translate(256 256) scale({FG_SCALE:.4f}) translate(-256 -276)">{inner}</g>'
svgs = {
 'full': f'<rect x="0" y="0" width="512" height="512" rx="0" fill="url(#bg)"/>' ,
 'legacy': f'<rect x="16" y="16" width="480" height="480" rx="112" fill="url(#bg)"/><g transform="translate(256 256) scale(0.92) translate(-256 -270)">{CARDS}</g>',
 'fg': fg_group(CARDS),
 'bg': '<rect width="512" height="512" fill="url(#bg)"/>',
 # macOS 图标网格：824/1024 圆角方块居中，留出系统阴影的边距
 'mac': f'<rect x="50" y="50" width="412" height="412" rx="92" fill="url(#bg)"/><g transform="translate(256 256) scale(0.8) translate(-256 -270)">{CARDS}</g>',
 'mono': fg_group(MONO),
}
for name, body in svgs.items():
    html = f'<html><body style="margin:0;background:transparent"><svg width="1024" height="1024" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg"><defs>{DEFS}</defs>{body}</svg></body></html>'
    open(os.path.join(OUT, f'{name}.html'),'w').write(html)
    subprocess.run(['google-chrome','--headless=new','--no-sandbox','--disable-gpu','--hide-scrollbars','--default-background-color=00000000','--window-size=1024,1024','--screenshot=' + os.path.join(OUT, f'{name}_1024.png'),'file://' + os.path.abspath(os.path.join(OUT, f'{name}.html'))],stderr=subprocess.DEVNULL,stdout=subprocess.DEVNULL)
print('done')
