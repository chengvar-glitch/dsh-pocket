import 'package:dsh_pocket/credential_store.dart';
import 'package:dsh_pocket/entry_parser.dart';
import 'package:dsh_pocket/entry_store.dart';
import 'package:dsh_pocket/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置页的回归测试。
///
/// **为什么专门测这一条**：用户在设置页的「入口地址」里粘进来的东西，
/// 几乎一定是从 `dsh-access.sh` 复制的那条**带 `?token=` 的完整链接** ——
/// 而令牌只活在 [EntryParseOk.launchUri] 里（见 AGENTS.md 认证事实 1）。
///
/// 早期版本 `_apply()` 只 `pop(uri)`、上层又 `EntryParseOk(updated)` 重建，
/// 令牌被丢掉。真机现象：链接粘进去了、Basic 口令也输对了，却永远停在
/// `dsh web authentication required`。这个测试就是钉死"不许再丢"。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 打开设置页 → 输入 → 点「保存并连接」 → 返回上层收到的东西。
  Future<EntryParseOk?> applyFromSettings(
    WidgetTester tester,
    String typed,
  ) async {
    EntryParseOk? popped;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<EntryParseOk>(
                  MaterialPageRoute<EntryParseOk>(
                    builder: (_) => SettingsScreen(
                      store: EntryStore(),
                      credentials: CredentialStore(),
                      currentEntry: null,
                    ),
                  ),
                );
              },
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), typed);
    await tester.tap(find.text('保存并连接'));
    await tester.pumpAndSettle();

    return popped;
  }

  testWidgets('粘带令牌的完整链接，回传的 EntryParseOk 必须保留令牌', (WidgetTester tester) async {
    final EntryParseOk? result = await applyFromSettings(
      tester,
      'https://203.0.113.9:7010/?token=SECRETTOKEN123',
    );
    expect(result == null, isFalse, reason: '合法的完整链接不该被拒');

    final EntryParseOk ok = result!;
    expect(ok.token, 'SECRETTOKEN123');
    expect(
      ok.launchUri.toString(),
      'https://203.0.113.9:7010/?token=SECRETTOKEN123',
    );
    // 但入口本身仍然只规范化到 origin：持久化那一路永远不含令牌（雷区 5）。
    expect(ok.uri.toString(), 'https://203.0.113.9:7010/');
    expect(ok.uri.query, isEmpty);
  });

  testWidgets('裸地址（没有令牌）照样能保存', (WidgetTester tester) async {
    final EntryParseOk? result = await applyFromSettings(
      tester,
      'https://203.0.113.9:7010/',
    );
    expect(result == null, isFalse);

    final EntryParseOk ok = result!;
    expect(ok.token, isNull);
    expect(ok.launchUri.toString(), 'https://203.0.113.9:7010/');
  });

  testWidgets('非法地址停在设置页报错，不回传任何东西', (WidgetTester tester) async {
    final EntryParseOk? result = await applyFromSettings(tester, 'ftp://nope');

    expect(result, isNull);
    expect(find.textContaining('只支持 http'), findsOneWidget);
  });
}
