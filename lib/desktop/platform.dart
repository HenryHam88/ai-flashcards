import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 应用自己的文件（资料、照片、导出、备份临时文件）放在哪里。
/// 手机：应用文档目录（和以前一样）。桌面：应用数据目录，不往用户的「文档」文件夹里乱放东西。
Future<Directory> appFilesDirectory() =>
    Desk.platform ? getApplicationSupportDirectory() : getApplicationDocumentsDirectory();

/// 桌面版（Windows / Linux / macOS）相关的判断。
///
/// 只看 [defaultTargetPlatform]（测试里默认是 Android），所以手机版和现有测试的界面完全不变。
class Desk {
  Desk._();

  /// 当前是不是桌面系统。
  static bool get platform {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
      _ => false,
    };
  }

  /// 桌面外壳（左侧栏 + 主区）是否正在显示。底部面板据此改成对话框 / 右侧栏。
  static bool active = false;

  /// 窗口够宽时才用桌面布局（窗口有最小尺寸，一般总是成立）。
  static const double breakpoint = 760;

  static bool get isLinux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  static bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  static bool get isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// 文案里怎么称呼这台设备：桌面是「电脑」，手机版仍是「手机」（文字和以前完全一样）。
  static String get device => platform ? '电脑' : '手机';

  /// 修饰键的显示名：macOS 是 ⌘，其他是 Ctrl。
  static String get mod => isMac ? '⌘' : 'Ctrl';

  /// GitHub Releases 里对应当前系统的安装包后缀；手机返回 null（沿用原来的下载页）。
  static String? get releaseAssetSuffix {
    if (isLinux) return '-linux-x64.tar.gz';
    if (isWindows) return '-windows-x64.zip';
    if (isMac) return '-macos.zip';
    return null;
  }

  static String get osName => isMac ? 'macOS' : (isWindows ? 'Windows' : (isLinux ? 'Linux' : ''));
}
