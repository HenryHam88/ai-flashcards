<div align="center">

<img src="docs/logo.png" width="112" alt="闪卡刷题 logo">

# 闪卡刷题

**把教材变成闪卡和练习题，用科学的间隔重复记住它。**

[![Release](https://img.shields.io/github/v/release/HenryHam88/ai-flashcards?color=8FA68B&label=release)](https://github.com/HenryHam88/ai-flashcards/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/HenryHam88/ai-flashcards/total?color=A3B1BD)](https://github.com/HenryHam88/ai-flashcards/releases)
[![License](https://img.shields.io/github/license/HenryHam88/ai-flashcards?color=D9CBB4)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20Linux-8FA68B)](#下载)
[![Flutter](https://img.shields.io/badge/Flutter-3.50-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

**简体中文** | [English](README.en.md)

</div>

闪卡刷题是一款开源的学习应用，支持 Android、Windows、macOS 和 Linux，帮你把 PDF、Word 或 TXT 教材变成闪卡和练习题，并用 FSRS 算法安排复习。类似 Anki，但能用 AI 从教材自动出卡出题。公式按教材排版显示，所有学习数据只保存在你自己的设备上。

## 截图

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/1_home.png" width="190"><br><sub>项目首页</sub></td>
    <td align="center"><img src="docs/screenshots/2_flashcard.png" width="190"><br><sub>闪卡复习</sub></td>
    <td align="center"><img src="docs/screenshots/3_quiz.png" width="190"><br><sub>测验</sub></td>
    <td align="center"><img src="docs/screenshots/14_explain_markdown.png" width="190"><br><sub>AI 解释</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/25_stats_overview.png" width="190"><br><sub>学习数据</sub></td>
    <td align="center"><img src="docs/screenshots/8_wrong_mixed.png" width="190"><br><sub>错题本</sub></td>
    <td align="center"><img src="docs/screenshots/16_word_doc_list.png" width="190"><br><sub>资料管理</sub></td>
    <td align="center"><img src="docs/screenshots/15_word_doc.png" width="190"><br><sub>解析设置</sub></td>
  </tr>
</table>

<details>
<summary>更多截图</summary>

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/19_settings.png" width="190"><br><sub>设置</sub></td>
    <td align="center"><img src="docs/screenshots/23_explain_history.png" width="190"><br><sub>解释历史</sub></td>
    <td align="center"><img src="docs/screenshots/22_dark.png" width="190"><br><sub>深色模式</sub></td>
    <td align="center"><img src="docs/screenshots/21_onboarding.png" width="190"><br><sub>首次引导</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/24_quality_review.png" width="190"><br><sub>生成审核</sub></td>
    <td align="center"><img src="docs/screenshots/26_mastery.png" width="190"><br><sub>掌握度与薄弱点</sub></td>
    <td align="center"><img src="docs/screenshots/27_auto_count.png" width="190"><br><sub>自动数量</sub></td>
    <td align="center"><img src="docs/screenshots/28_chapter_view.png" width="190"><br><sub>章节内容</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/29_help_home.png" width="190"><br><sub>使用帮助</sub></td>
    <td align="center"><img src="docs/screenshots/30_help_article.png" width="190"><br><sub>帮助文章</sub></td>
    <td align="center"><img src="docs/screenshots/31_table_render.png" width="190"><br><sub>表格显示</sub></td>
    <td align="center"><img src="docs/screenshots/32_latex_text.png" width="190"><br><sub>LaTeX 文本格式</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/34_txt_doc.png" width="190"><br><sub>TXT 资料</sub></td>
    <td align="center"><img src="docs/screenshots/35_new_vs_review.png" width="190"><br><sub>新学 / 待复习</sub></td>
    <td align="center"><img src="docs/screenshots/36_card_badge.png" width="190"><br><sub>卡片标签</sub></td>
    <td align="center"><img src="docs/screenshots/37_due_by_day.png" width="190"><br><sub>每日到期卡片</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/38_chapter_reparse.png" width="190"><br><sub>按章重新解析</sub></td>
    <td align="center"><img src="docs/screenshots/42_concurrency.png" width="190"><br><sub>并发数</sub></td>
    <td align="center"><img src="docs/screenshots/43_typed_count.png" width="190"><br><sub>直接输入数量</sub></td>
  </tr>
</table>

</details>

## 主要功能

**资料与生成**
- 支持 PDF、Word（.docx / .doc）和 TXT，可批量导入，每份资料单独显示进度
- TXT 在本机读取，不联网；自动识别 UTF-8 / UTF-16 / GBK
- 扫描版 PDF 也能识别，公式保留为 LaTeX
- 自动识别章节（书签、目录、标题格式；不行时由 AI 分章），也可以手动改
- 按页查看每章原文，可搜索、复制，一键「用这章出题」
- 某一章解析不好可以只重解析这一章，逐页对比后再替换，也能恢复上次的结果
- 按整份、章节或页码范围生成；数量可直接输入（闪卡和题目各最多 1500），也可按知识点自动估算
- 并发数可调（默认 4）；遇到 429 会自动重试
- 题型：单选、多选、判断、填空、简答、计算
- 每张卡和每道题都标注出处，可回到原文
- 生成后会检查出处、公式和重复项；有问题的先自动修一次，修不好就丢弃
- 可以先审核再加入复习；也能标记「这张有问题」，之后出题会避开

**学习与 AI**
- 学习板块：每章可生成思维导图，能编辑、展开收起，也可存成图片
- 「AI 伴学」按章节或页码选资料对话，依据原文回答，可存为笔记；能发 PDF、Word、TXT 和图片（每个对话最多 5 个）
- 知识点笔记：照片、我的理解、AI 讲解、相关题目和带页码的原文；可导出 PDF
- 收藏知识点、闪卡和题目，集中复习
- AI 联网搜索默认开「深度搜索」，回答下面会列出参考网页；出闪卡和出题不联网
- 「我的 → AI 模型」可添加 DeepSeek、通义千问、智谱、Kimi、豆包、硅基流动、OpenRouter、Ollama 等；出题、解释、伴学可以各用不同模型
- 回答边生成边显示，可随时停止；对话可以复制

**复习与测验**
- FSRS 间隔重复，四档评分（没记住 / 模糊 / 记住了 / 很简单），可改上一张的评分
- 新卡和复习分开：「学新卡」「复习」「全部学习」；每日新卡默认 20 张
- 按天查看即将到期的卡片（含逾期），一键复习
- 客观题自动判分，简答和计算题由 AI 批改
- AI 解释可结合原文讲解和追问，并保存在「解释历史」
- 错题本自动收录，可按项目筛选、针对薄弱点出新题，也可导出 PDF
- 学习数据：每日概览、热力图、到期预测、各章节掌握度；可按薄弱章节复习或出题
- 每日复习提醒（本地通知，不联网）

**数据**
- 导出 `.afcbak` 备份，换设备时导入即可；可选覆盖或合并
- 单个项目也能导出分享，可选择是否带上学习进度
- 可选每周自动备份，保留最近 3 份
- 导出到 Obsidian / Notion：笔记、伴学和解释记录、收藏、错题打成 Markdown 压缩包，错题另附 CSV
- 「保存到文件夹」会打开系统的文件选择窗口
- 大文件可放到阿里云 OSS、腾讯云 COS 或 S3 兼容存储，打开时再下载；云端密钥不进备份

**体验**
- LaTeX 公式和 Markdown 排版，表格可左右滑动
- 深色模式，字体和公式大小可调
- 内置「使用帮助」（我的 → 使用帮助），离线可查；部分页面右上角的 **?** 会打开对应说明
- 电脑版有左侧栏和键盘操作：空格翻面，1–4 评分，Ctrl+K（Mac 上 ⌘K）搜索

## 下载

从 [Releases](https://github.com/HenryHam88/ai-flashcards/releases/latest) 下载最新版本。

### Android

| 安装包 | 适用设备 |
| --- | --- |
| `ai-flashcards-<版本>-arm64-v8a.apk` | **绝大多数手机，推荐** |
| `ai-flashcards-<版本>-armeabi-v7a.apk` | 较老的 32 位设备 |
| `ai-flashcards-<版本>-x86_64.apk` | 模拟器、x86 平板 |

需要 Android 7.0 及以上。第一次安装需允许「安装未知来源应用」。新版本可直接覆盖安装，数据会保留。

<details>
<summary>签名证书指纹</summary>

```
SHA-256: f5:ec:04:9f:25:ef:21:59:36:28:23:59:4a:08:49:46:f5:66:6d:cc:54:35:19:b9:9a:e1:d0:2f:be:a1:0d:59
```

用 `apksigner verify --print-certs <apk>` 核对。
</details>

### 电脑版

| 安装包 | 适用系统 |
| --- | --- |
| `ai-flashcards-<版本>-windows-x64.zip` | Windows 10 / 11（64 位） |
| `ai-flashcards-<版本>-macos.zip` | macOS 12 及以上（Apple 芯片和 Intel） |
| `ai-flashcards-<版本>-linux-x64.tar.gz` | 64 位 Linux（如 Ubuntu 22.04、Debian 12、Fedora 38） |

功能和手机版相同，用备份文件互相迁移。电脑版目前没有开发者签名，第一次打开时：

- **Windows**：解压后双击 `ai_flashcards.exe`。若出现「Windows 已保护你的电脑」，点「更多信息 → 仍要运行」。
- **macOS**：把「闪卡刷题」拖到「应用程序」，右键点它选「打开」。若没有「打开」按钮（macOS 15 及以上），先双击一次，再到「系统设置 → 隐私与安全性」点「仍要打开」。
- **Linux**：解压后运行 `ai_flashcards`。运行 `./install-desktop-entry.sh` 可把它加到应用菜单。需要 GTK 3 和 libsecret。

更新时替换旧文件即可，数据在系统的应用目录里。

## 快速开始

1. 在 [DeepSeek 开放平台](https://platform.deepseek.com/) 创建 API Key，或其他已支持的服务商也可以。
2. 打开应用，进入 **我的 → AI 模型**，添加服务商、填写密钥，点「拉取模型」或「测试连接」。
3. 新建项目，上传教材，解析完成后点「生成」。

出题、解释、伴学可以各用不同模型。接口兼容 OpenAI 格式。

## 支持的解析方式

在 **我的 → 文档解析（PDF / Word）** 中选择：

| 解析方式 | PDF | Word（.docx / .doc） | 扫描版 | 费用 |
| :-- | :-: | :-: | :-: | :-- |
| DeepSeek OCR（默认） | ✓ | ✓ | ✓ | 按页计费 |
| Kimi 文件解析 | ✓ | ✓ | — | 目前免费 |
| 本地提取文字层 | ✓ | — | — | 免费，离线 |

TXT 总是在本机直接读取，不走上面的设置。

## 隐私与数据

- 资料、卡片、错题和学习记录只保存在本机，项目没有自己的服务器。
- API Key 存放在系统安全存储里（Android 用 Keystore，电脑用系统钥匙串；没有钥匙串时加密写在应用目录）。
- 文档只会发给你配置的服务商。「本地提取」和 TXT 都不上传。
- 备份默认不含 API Key；只有勾选「包含 API 密钥」时才会写入。备份文件不加密，请勿外传。云端存储的密钥也不会进备份。

## 常见问题

<details>
<summary>需要付费吗？</summary>

应用本身免费开源。生成和解析走你自己的 API Key，费用由对应服务商收取。已经解析或生成过的内容会缓存，不会重复计费。
</details>

<details>
<summary>上传 Word 后提示「当前解析模型不支持 Word」？</summary>

「本地提取」只能读 PDF。请在解析设置里换成 DeepSeek OCR 或 Kimi，或把文档另存为 PDF。
</details>

<details>
<summary>怎么把数据搬到另一台设备？</summary>

在旧设备打开 **我的 → 导出 / 导入数据 → 导出数据**，保存 `.afcbak` 文件。若还要重新解析或查看原页，勾选「包含原始 PDF / Word」。新设备在同一页选「导入数据 → 覆盖当前数据」。API Key 默认不随备份迁移。
</details>

<details>
<summary>公式显示不正常怎么办？</summary>

在该卡片的「AI 解释」里让模型重新整理，或在测验中标记「AI 出错了」。
</details>

**已知限制**

- 生成和批改质量取决于所选模型，重要内容请对照原文。
- 用 Kimi 解析 PDF 时，出处页码可能不够准。
- 排版特殊的书，章节可能识别不准，可在「编辑章节」里改，或让 AI 重新分章。
- 手机和电脑之间用备份文件迁移，没有实时同步。

## 从源码构建

需要 Flutter 3.50（stable）。Android 还需要 Android SDK 和 JDK 17。

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

Linux 依赖、签名和 CI 说明见 [CONTRIBUTING.md](CONTRIBUTING.md#从源码构建)。

## 反馈

有问题或建议请开 [Issue](https://github.com/HenryHam88/ai-flashcards/issues)。欢迎直接提 Pull Request，见 [CONTRIBUTING.md](CONTRIBUTING.md)。更新记录在 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

本项目基于 [MIT License](LICENSE) 开源。测试所用字体 Noto Sans SC 遵循 [SIL Open Font License 1.1](test/fonts/OFL.txt)。
