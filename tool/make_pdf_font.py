# 用法（在仓库根目录）：pip install fonttools && python tool/make_pdf_font.py
# 生成 PDF 导出用的中文字体子集（GB2312 全部汉字 + 常用符号），由 test/fonts/NotoSansSC.ttf（可变字体）实例化。
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools import subset
src='test/fonts/NotoSansSC.ttf'
chars=set()
for hi in range(0xA1,0xF8):
    for lo in range(0xA1,0xFF):
        try: chars.add(bytes([hi,lo]).decode('gb2312'))
        except Exception: pass
cps={ord(c) for c in chars}
for a,b in [(0x20,0x7E),(0xA0,0xFF),(0x370,0x3FF),(0x2000,0x206F),(0x2100,0x214F),(0x2150,0x218F),(0x2190,0x21FF),(0x2200,0x22FF),(0x2460,0x24FF),(0x25A0,0x25FF),(0x3000,0x303F),(0xFF00,0xFFEF)]:
    cps.update(range(a,b+1))
for w,name in [(400,'Regular')]:
    f=TTFont(src)
    f=instancer.instantiateVariableFont(f,{'wght':w})
    opts=subset.Options(); opts.layout_features=['*']; opts.name_IDs=['*']; opts.notdef_outline=True; opts.hinting=False
    s=subset.Subsetter(opts); s.populate(unicodes=cps); s.subset(f)
    out=f'assets/fonts/NotoSansSC-{name}-subset.ttf'
    f.save(out); print(out)
