# 参与贡献

感谢你愿意改进闪卡刷题。

## 反馈问题

- 提交前请先搜索 [已有 Issue](https://github.com/HenryHam88/ai-flashcards/issues)，避免重复。
- 使用对应模板（问题反馈 / 功能建议），并写明应用版本和系统（Android 请加上机型；电脑版请写 Windows / macOS / Linux 及版本）。
- 不要在 Issue 中粘贴 API Key 或其他私密内容。

## 提交代码

1. Fork 本仓库，从 `main` 创建分支，例如 `fix/quiz-grading`。
2. 环境：Flutter 3.50（stable）。Android 构建还需要 Android SDK 和 JDK 17。
3. 提交前请运行：

   ```bash
   flutter analyze
   flutter test
   ```

4. 涉及界面改动时，请更新截图：`flutter test test/screenshots_test.dart --update-goldens`。
5. 提交 Pull Request，说明改了什么、为什么改，并关联相关 Issue。

## 从源码构建

```bash
git clone https://github.com/HenryHam88/ai-flashcards.git
cd ai-flashcards
flutter pub get
flutter test
```

```bash
# Android
flutter build apk --release --split-per-abi

# 电脑版（在对应系统上）
flutter build windows
flutter build macos
flutter build linux
```

构建 Linux 版需要：`clang`、`cmake`、`ninja-build`、`pkg-config`、`libgtk-3-dev`、`libsecret-1-dev`。

推送版本标签后，GitHub Actions 会构建三个电脑版安装包，并附加到对应的 Release。

### Android 发布签名

发布签名从 `android/key.properties` 读取，也可以用环境变量 `AI_FLASHCARDS_KEY_PROPERTIES` 指向这个文件。没有配置时，release 构建会用 debug 签名。

1. 第一次发布时生成密钥库，之后一直用同一个。丢了就无法覆盖安装已发布的版本：

   ```bash
   keytool -genkeypair -v -keystore ~/keys/ai-flashcards-release.jks \
     -alias ai-flashcards -keyalg RSA -keysize 4096 -validity 10000
   ```

2. 复制 `android/key.properties.example` 为 `android/key.properties`，填写路径、别名和两个密码。
   `key.properties`、`*.jks`、`*.keystore` 已在 `.gitignore` 里，不要提交。密钥库请另外备份。
3. 构建后用 `apksigner verify --print-certs <apk>` 核对证书指纹，需与 README「下载」一节公布的一致。

## 代码约定

- 界面文字使用简体中文，中文与英文、数字之间加空格。
- 新功能请附带测试；网络请求在测试中使用模拟实现。
- 不要提交签名密钥、`key.properties` 或任何凭据。
