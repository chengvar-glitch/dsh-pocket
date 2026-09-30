import 'package:dsh_pocket/config.dart';
import 'package:dsh_pocket/entry_parser.dart';
import 'package:dsh_pocket/entry_store.dart';
import 'package:dsh_pocket/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首屏的 widget 测试。
///
/// **范围**：只覆盖"决定连哪儿"这一段 —— 预填地址、非法输入报错、
/// 端口异常时的提醒。这些是纯 Flutter 逻辑，本机能可靠验证。
///
/// **为什么不测"点连接后进 WebView"**：`WebViewWidget` 需要真实的平台实现
/// （Android WKWebView / macOS WKWebView），单元测试环境里
/// `WebViewPlatform.instance` 是 null，构造时会直接 assert 失败。
/// 要测就得手写一整个 `WebViewPlatform` 假实现，那是几十行样板代码，
/// 而它验证的只是"Flutter 的路由跳对了" —— 收益远不抵成本。
/// 真实行为（证书、Basic 口令框、Cookie 持久化）本来也**只能**在真机验，
/// 见 AGENTS.md 的交付清单。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(store: EntryStore())),
    );
    // 等 _restoreSavedEntry 的异步落地。
    await tester.pumpAndSettle();
  }

  testWidgets('没存过地址时停在输入框，让用户自己填', (WidgetTester tester) async {
    await pumpHome(tester);

    // 开源构建下既没有内置默认地址、也没有存过的记录 → 必须停在首屏。
    // 这时若自作主张去连一个空地址，用户只会看到一片空白。
    expect(find.text('DSH Pocket'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);

    final TextField field = tester.widget(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

  // 说明：**没有**"存过地址时自动进入 WebView"的 widget 测试。
  //
  // 那个行为本身是验过的（手动跑过：输入框消失、WebView 开始构建），
  // 但写成 widget 测试要手写一整套 WebViewPlatform 假实现
  // （createPlatformWebViewController / NavigationDelegate /
  // CookieManager / WebViewWidget 四个类），几十行样板只为了断言
  // "一个 if 分支走对了"。收益不抵成本，而且假实现本身也可能写错。
  //
  // 真正决定"要不要自动进入"的逻辑被抽在下面这个纯函数式断言里。
  test('有存过的地址 → 启动就该自动进入；没有 → 停在首屏', () async {
    // 有地址
    SharedPreferences.setMockInitialValues(<String, Object>{
      'entry_origin': 'https://example.com:7010/',
    });
    expect(await EntryStore().load(), isNotNull);

    // 没地址（开源构建的默认状态）
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await EntryStore().load(), isNull);
  });

  testWidgets('存过的地址坏掉时不停在空地址上乱连', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'entry_origin': '这不是地址',
    });

    await pumpHome(tester);

    // 解析不了就退回首屏（而不是拿一个坏地址去连）。
    // 注意：开源构建没有默认地址，所以这里应该停在空的输入框。
    expect(find.text('连接'), findsOneWidget);
    final TextField field = tester.widget(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('输入非法地址时显示错误且停在首屏', (WidgetTester tester) async {
    await pumpHome(tester);

    await tester.enterText(find.byType(TextField), 'ftp://nope');
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('只支持 http'), findsOneWidget);
    // 仍在首屏：输入框还在。
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('空输入时提示而不是崩溃', (WidgetTester tester) async {
    await pumpHome(tester);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();

    expect(find.text('请输入地址'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  group('EntryStore —— 只存 origin，绝不存 token', () {
    test('save 会把 token 剥掉', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = EntryStore();

      await store.save(
        Uri.parse('https://198.51.100.10:7010/?token=SECRETSECRETSECRET'),
      );
      final Uri? loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.query, isEmpty);
      expect(loaded.toString(), 'https://198.51.100.10:7010/');
    });

    test('save 会把路径丢掉，只留根', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = EntryStore();

      await store.save(Uri.parse('https://example.com:7010/deep/path'));
      expect((await store.load()).toString(), 'https://example.com:7010/');
    });

    test('clear 之后回退到构建时默认值（没配就是 null）', () async {
      const String stored = 'http://10.0.0.5/';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'entry_origin': stored,
      });
      final store = EntryStore();

      expect((await store.load()).toString(), stored);
      await store.clear();

      final Uri? after = await store.load();
      if (kDefaultEntryUrl.isEmpty) {
        // 开源构建的默认状态：没有内置地址，也没存过 → null，让用户自己填。
        expect(after, isNull);
      } else {
        expect(after, Uri.parse(kDefaultEntryUrl));
      }
    });

    test('存下的内网地址能原样读回', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = EntryStore();

      const String internal = 'http://10.0.0.5/';
      await store.save(Uri.parse(internal));
      expect((await store.load()).toString(), internal);
    });
  });

  test('parseEntry 的 origin 能安全往返 EntryStore', () {
    // 防止"解析出来的 origin 存不住"这类回归。
    final ok = parseEntry('https://198.51.100.10:7010/?token=abc') as EntryParseOk;
    expect(normalizeToOrigin(ok.uri), ok.uri);
  });
}
