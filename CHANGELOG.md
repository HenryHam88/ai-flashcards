# 更新日志

本项目的所有重要变更都会记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.1.9] - 2026-11-21

### 新增

- 编辑章节：可重命名、新增、删除、与下一章合并、按页拆分、调整起始页，也可按页数一键切分。
- AI 自动分章：识别不到章节时，由出题模型根据全书大纲自动划分章节（每份资料只调用一次）；也可随时手动触发。

### 改进

- 章节识别更准确：优先读取 PDF 书签和目录页，并支持「第 1 章」「Chapter 1」「Lecture / Unit」「一、」「§1.2」「1.2.3」、Markdown 标题等格式，能容忍 OCR 产生的多余空格。
- 章节调整后，已生成的闪卡、题目会按出处页码自动归入新章节。

## [1.1.8] - 2026-11-20

### 改进

- 全新应用图标：莫兰迪配色的闪卡造型，支持 Android 8.0+ 自适应图标（各种遮罩形状）和 Android 13+ 主题图标。

## [1.1.7] - 2026-11-20

首个公开版本。

### 新增

- 项目管理：按科目建立项目，批量导入 PDF 和 Word（.docx / .doc）教材。
- 文档解析：支持 DeepSeek OCR（含扫描版与公式识别）、Kimi 文件解析和本地提取文字层。
- AI 生成：提炼知识点，生成闪卡和六种题型的练习题；可按整份、章节或页码范围生成，并设置数量、难度和侧重点。
- 闪卡复习：FSRS 间隔重复调度，滑动评分，支持上一张 / 下一张回看。
- 测验：客观题自动判分，简答题和计算题由 AI 批改。
- AI 解释：结合原文讲解并支持追问，结果本地缓存。
- 错题本：自动收录错题，支持按项目筛选、跨项目重做，以及针对知识点再出新题。
- 完整的 LaTeX 公式排版与 Markdown 格式显示。
- 学习统计页面。

[Unreleased]: https://github.com/HenryHam88/ai-flashcards/compare/v1.1.9...HEAD
[1.1.9]: https://github.com/HenryHam88/ai-flashcards/compare/v1.1.8...v1.1.9
[1.1.8]: https://github.com/HenryHam88/ai-flashcards/compare/v1.1.7...v1.1.8
[1.1.7]: https://github.com/HenryHam88/ai-flashcards/releases/tag/v1.1.7
