import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'config.dart';
import 'entry_parser.dart';
import 'entry_store.dart';

/// 设置页：换地址、退出登录、用系统浏览器打开。
///
/// 返回一个 [Uri] 表示用户选了新入口（调用方据此重连）；返回 null 表示什么都没改。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.currentEntry,
  });

  final EntryStore store;

  /// 当前入口。为 null 表示还没连过、且构建时也没配默认值。
  final Uri? currentEntry;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentEntry?.toString() ?? '');

  String? _inputError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() {
    final EntryParseResult result = parseEntry(_controller.text);

    switch (result) {
      case EntryParseError(:final reason):
        setState(() => _inputError = reason);
      case EntryParseOk(:final uri):
        // 只返回地址，让上层决定什么时候重连。
        Navigator.of(context).pop(uri);
    }
  }

  /// "退出登录"：清掉 WebView 的 Cookie。
  ///
  /// 会话就是服务端种下的那个长期 Cookie，所以清 Cookie 等价于登出。
  /// **不去动用户的地址** —— 退出登录和忘掉地址是两件事。
  Future<void> _clearCookies() async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('退出登录'),
            content: const Text(
              '将清除 WebView 里保存的登录 Cookie。\n'
              '下次连接需要重新输入凭据。\n\n'
              '（不会清除已记住的入口地址）',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('退出'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    await WebViewCookieManager().clearCookies();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已清除登录 Cookie')));
  }

  /// 用系统浏览器打开当前入口。
  ///
  /// 存在的意义：某些登录/OAuth 流程在 WebView 里会失败，浏览器能过去。
  /// 注意**不要**把带 `?token=` 的地址存下来再从这里打开 —— 这里打开的永远
  /// 是规范化的 origin。
  Future<void> _openInBrowser() async {
    final Uri? target = widget.currentEntry;
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('还没设置入口地址')));
      return;
    }
    final bool ok = await launchUrl(target, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('打不开系统浏览器')));
    }
  }

  Future<void> _resetToDefault() async {
    await widget.store.clear();
    if (!mounted) return;
    // 没配默认值时就是清空输入框 —— 语义仍是"忘掉记住的地址"。
    _controller.text = kDefaultEntryUrl;
    setState(() => _inputError = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          kDefaultEntryUrl.isEmpty ? '已清除记住的地址' : '已恢复默认地址',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Uri? current = widget.currentEntry;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            controller: _controller,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: '入口地址',
              border: const OutlineInputBorder(),
              errorText: _inputError,
              hintText: 'https://example.com:7010/?token=...',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _apply, child: const Text('保存并连接')),
          const Divider(height: 40),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('当前入口'),
            subtitle: Text(
              current == null
                  ? '未设置'
                  : '${current.host}（${describeEntry(current)}）',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_browser),
            title: const Text('在系统浏览器打开'),
            subtitle: const Text('WebView 里登录不通时用这个'),
            onTap: _openInBrowser,
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            subtitle: const Text('清除登录 Cookie，保留入口地址'),
            onTap: _clearCookies,
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('清除记住的地址'),
            subtitle: Text(
              kDefaultEntryUrl.isEmpty ? '本构建没有内置默认地址' : kDefaultEntryUrl,
            ),
            onTap: _resetToDefault,
          ),
          const Divider(height: 40),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '关于自签证书：App 只对构建时配置的已知入口'
              '（${kKnownHosts.isEmpty ? '本构建未配置任何白名单，因此不会放行任何自签证书' : kKnownHosts.join('、')}）'
              '放行自签证书，其它主机的证书问题一律拒绝。要彻底去掉警告，'
              '可以把你的 CA 证书装进系统信任。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
