#!/bin/sh
# 把「闪卡刷题」加到应用菜单（只影响当前用户）。在解压后的文件夹里运行：./install-desktop-entry.sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS"
cat > "$APPS/io.github.henryham88.ai_flashcards.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=闪卡刷题
Name[en]=AI Flashcards
Comment=上传资料，生成闪卡和练习题
Exec="$DIR/ai_flashcards"
Icon=$DIR/data/app_icon.png
Terminal=false
Categories=Education;
StartupWMClass=ai_flashcards
DESKTOP
echo "已添加到应用菜单：$APPS/io.github.henryham88.ai_flashcards.desktop"
