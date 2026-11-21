# 参与贡献

感谢你愿意改进闪卡刷题！

## 反馈问题

- 提交前请先搜索 [已有 Issue](https://github.com/HenryHam88/ai-flashcards/issues)，避免重复。
- 使用对应模板（问题反馈 / 功能建议），并写明应用版本、手机型号和 Android 版本。
- **不要在 Issue 中粘贴 API Key 或任何私密内容。**

## 提交代码

1. Fork 本仓库，从 `main` 创建分支，例如 `fix/quiz-grading`。
2. 环境：Flutter 3.50（stable）、Android SDK、JDK 17。
3. 提交前确保通过：

   ```bash
   flutter analyze
   flutter test
   ```

4. 涉及界面改动时，请更新截图：`flutter test test/screenshots_test.dart --update-goldens`。
5. 提交 Pull Request，说明改动内容和原因，并关联相关 Issue。

## 代码约定

- 界面文字使用简体中文，中文与英文、数字之间加空格。
- 新功能请附带测试；网络请求在测试中使用模拟实现。
- 不要提交签名密钥、`key.properties` 或任何凭据。
