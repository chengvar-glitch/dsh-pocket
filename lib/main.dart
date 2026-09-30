import 'package:flutter/material.dart';

import 'entry_store.dart';
import 'home_screen.dart';

void main() {
  runApp(const DshPocketApp());
}

/// App 根。只做两件事：定主题、把 [EntryStore] 注入首屏。
///
/// 没有路由表、没有状态管理库 —— 整个 App 就三个页面，
/// 用 `Navigator.push` 直接走比引一个框架更省事。
class DshPocketApp extends StatelessWidget {
  const DshPocketApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH Pocket',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4D6BFE),
          brightness: Brightness.dark,
        ),
      ),
      home: HomeScreen(store: EntryStore()),
    );
  }
}
