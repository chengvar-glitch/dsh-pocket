import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'credential_store.dart';
import 'entry_parser.dart';
import 'entry_store.dart';
import 'settings_screen.dart';
import 'webview_screen.dart';

/// 首屏：logo + 地址输入 + 「连接」。
///
/// 只有一个职责：决定"连哪儿"，然后把地址交给 [WebViewScreen]。
/// 连接后的所有事（认证、页面）都归 WebView 管，这层不插手。
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.store,
    required this.credentials,
  });

  final EntryStore store;

  /// 透传给 WebView 页 / 设置页 —— 这层不碰凭据，只负责把依赖传下去。
  final CredentialStore credentials;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _addressController = TextEditingController();

  /// 已经解析好的入口。非 null 时直接显示 WebView。
  ///
  /// 注意持有的是整个 [EntryParseOk] 而不只是 Uri —— 它可能带着
  /// 一次性的启动令牌，WebView 首次加载要用（见 EntryParseOk.launchUri）。
  EntryParseOk? _entry;

  /// 输入框下方的错误提示（解析失败时显示）。
  String? _inputError;

  /// 非致命的提醒（例如端口超出常见区间）。
  String? _inputWarning;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restoreSavedEntry();
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  /// 启动时恢复上次的地址，并**直接进入** —— 不再让用户每次点「连接」。
  ///
  /// 为什么改成自动进入：服务端会种下长期有效的会话 Cookie，
  /// 一旦登录过，重新打开时 WebView 本来就能免口令直接进。
  /// 如果还停在首屏等用户点一下，那这个"免登录"就只做了一半 ——
  /// 用户仍然要手动操作一次，体验上跟没记住没区别。
  ///
  /// 仍然**只对已经存过的/配置好的地址**自动进入：
  /// 没有地址（开源构建）时老老实实停在输入框，让用户填。
  Future<void> _restoreSavedEntry() async {
    final Uri? saved = await widget.store.load();
    if (!mounted) return;

    if (saved == null) {
      setState(() => _loading = false);
      return;
    }

    setState(() {
      _addressController.text = saved.toString();
      // 自动进入。注意这里**不带 token** —— 凭证已经在上次登录时
      // 换成了 Cookie，由 WebView 自己带着。token 是一次性的，不该留。
      _entry = EntryParseOk(saved);
      _loading = false;
    });
  }

  void _connect() {
    final EntryParseResult result = parseEntry(_addressController.text);

    switch (result) {
      case EntryParseError(:final reason):
        setState(() {
          _inputError = reason;
          _inputWarning = null;
        });
      case EntryParseOk(:final uri, :final warning):
        setState(() {
          _inputError = null;
          _inputWarning = warning;
          // 立刻进 WebView。warning 只作为提醒，不阻塞连接 ——
          // 服务端端口会变（雷区 6），拿"端口可疑"拦住用户是本末倒置。
          _entry = result;
        });
        // 只存 origin。令牌是内存里的，绝不落盘（见 EntryParseOk.token）。
        _saveQuietly(uri);
    }
  }

  /// 保存入口（不带 token），失败也不打扰用户。
  ///
  /// 此刻用户是能正常用的，最坏后果只是下次打开要重敲地址 ——
  /// 为这种事弹错误框不值。
  void _saveQuietly(Uri uri) {
    widget.store.save(uri).catchError((Object _) {});
  }

  /// 从剪贴板粘贴地址。
  ///
  /// 走 [extractEntryFromScan] 而不是直接塞进输入框：那条路径会校验格式，
  /// 并在粘贴的是二维码原始 URL 时保留令牌。粘进来的东西不合法就给提示，
  /// 而不是让用户对着一个坏地址反复点「连接」。
  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;

    if (!mounted) return;

    if (text == null || text.trim().isEmpty) {
      setState(() {
        _inputError = '剪贴板里没有文字';
        _inputWarning = null;
      });
      return;
    }

    final EntryParseOk? parsed = extractEntryFromScan(text);
    if (parsed == null) {
      setState(() {
        _inputError = '剪贴板里的内容不是个地址';
        _inputWarning = null;
      });
      return;
    }

    setState(() {
      _addressController.text = parsed.launchUri.toString();
      _inputError = null;
      _inputWarning = parsed.warning;
    });
  }

  /// 从设置页回来后，如果地址变了，要重新连接。
  ///
  /// ⚠️ 收的是**整个** [EntryParseOk]，不是 Uri —— 设置页里粘进来的链接
  /// 通常带 `?token=`，那是这次导航唯一的机会（见认证事实 1）。
  /// 早期版本只回传 Uri 再 `EntryParseOk(updated)` 重建，令牌就这么没了，
  /// 真机上的表现是"链接粘了也进不去，服务端日志显示每次请求都没带上令牌"。
  Future<void> _openSettings() async {
    final EntryParseOk? updated = await Navigator.of(context)
        .push<EntryParseOk>(
          MaterialPageRoute<EntryParseOk>(
            builder: (_) => SettingsScreen(
              store: widget.store,
              credentials: widget.credentials,
              // 没连过就可能没有当前入口（开源构建下没配默认值）。
              // 传 null，让设置页自己显示"未设置"。
              currentEntry: _entry?.uri,
            ),
          ),
        );

    if (!mounted || updated == null) return;
    setState(() {
      _addressController.text = updated.launchUri.toString();
      _entry = updated;
    });
    // 在设置页换的地址也要记住，否则杀掉进程重开又回到旧地址
    // （只存 origin，令牌照旧不落盘）。
    _saveQuietly(updated.uri);
  }

  /// 从 WebView 错误页退回输入框，让用户改地址。
  ///
  /// **保留输入框里已有的地址**（不清空、也不清 Cookie）——
  /// 用户多半只是想把端口/入口改一下，从零重敲很烦。
  void _backToEntryForm() {
    setState(() {
      _entry = null;
      _inputError = null;
      _inputWarning = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final EntryParseOk? entry = _entry;

    if (entry != null) {
      return WebViewScreen(
        entry: entry,
        credentials: widget.credentials,
        onOpenSettings: _openSettings,
        onChangeAddress: _backToEntryForm,
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('DSH Pocket')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildEntryForm(context),
    );
  }

  Widget _buildEntryForm(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Image.asset('assets/brand/logo_white.png', height: 96),
              const SizedBox(height: 32),
              TextField(
                controller: _addressController,
                autocorrect: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _connect(),
                decoration: InputDecoration(
                  labelText: '入口地址',
                  // 没配默认值时给个格式示例，而不是空 hint。
                  hintText: kDefaultEntryUrl.isEmpty
                      ? 'https://example.com:7010/?token=...'
                      : kDefaultEntryUrl,
                  border: const OutlineInputBorder(),
                  errorText: _inputError,
                  // 从二维码复制来的地址通常很长且带令牌，
                  // 手敲不现实。粘贴是主要输入方式。
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste),
                    tooltip: '从剪贴板粘贴',
                    onPressed: _pasteFromClipboard,
                  ),
                ),
              ),
              if (_inputWarning != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _inputWarning!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _connect,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('连接'),
                ),
              ),
              // 构建时配了内网入口就给个一键切换 —— 否则这个配置项没人用得上
              // （用户不可能记得住 https 前缀和端口）。
              if (kInternalEntryUrl.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    _addressController.text = kInternalEntryUrl;
                    setState(() {
                      _inputError = null;
                      _inputWarning = null;
                    });
                  },
                  child: const Text('用内网入口'),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                '首次连接可能会要求输入凭据（$kBasicAuthHint）。\n'
                '口令只用于本次请求，App 不会保存它。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
