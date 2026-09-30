import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
// 下面是 webview_flutter 的传递依赖（平台实现），这里为了在 SSL 回调里
// 拿到平台特有的 host/url 字段而直接引用它们的类型。见 [_hostOfSslError]。
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'config.dart';
import 'entry_parser.dart';

/// WebView 页：真正把 dsh web 显示出来的地方。
///
/// 设计要点（每一条都对应 AGENTS.md 里的雷区）：
/// - **证书只对白名单 host 放行**（雷区 1）——见 [_onSslAuthError]
/// - **自己应答 HTTP Basic 挑战**（见 [_onHttpAuthRequest]），否则请求被静默取消
/// - **不把 URL 写日志**（雷区 5）
/// - 出错给可重试的页面，不留白屏
/// - **UI 不长得像浏览器**：没有地址栏、没有 URL 文本，只有进度和两个按钮
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({
    super.key,
    required this.entry,
    this.onOpenSettings,
    this.onChangeAddress,
  });

  /// 解析好的入口。带着可选的启动令牌（[EntryParseOk.token]）。
  final EntryParseOk entry;

  /// 打开设置页的回调，由上层注入（这层不关心路由怎么走）。
  final VoidCallback? onOpenSettings;

  /// 退回输入框改地址。只在错误页出现。
  ///
  /// 有它的原因：启动时会自动进入上次的地址，所以"服务端没开/地址过期"时
  /// 用户会直接落到错误页 —— 没有这条退路就出不去了。
  final VoidCallback? onChangeAddress;

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;

  int _progress = 0;

  /// 非 null 表示当前处于错误状态，UI 显示重试页而不是 WebView。
  String? _error;

  /// 记录是否已经放行过一次证书。
  ///
  /// 只用来在 UI 上给一次提示，**不参与放行判断** —— 放行判断永远是 host 白名单。
  bool _certificateAccepted = false;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
    unawaited(_controller.loadRequest(widget.entry.launchUri));
  }

  WebViewController _buildController() {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 用白色而不是黑色：dsh web 是浅色页面，黑色底会让"还没渲染出来"
      // 和"渲染了但内容没到"看起来一样，排查时很难分辨（踩过一次）。
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (!mounted) return;
            setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _error = null;
              _progress = 0;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _progress = 100);
          },
          onWebResourceError: _onWebResourceError,
          onSslAuthError: _onSslAuthError,
          onHttpAuthRequest: _onHttpAuthRequest,
          // 仍然**不**注册 onHttpError：那是"已经拿到响应"之后的回调，
          // 而 401 是在此之前由 WebView 抛出 auth 挑战，走 onHttpAuthRequest。
        ),
      );
  }

  /// 处理 HTTP Basic 挑战。
  ///
  /// ⚠️ **这里必须自己弹框，不能指望 WebView 原生 UI。**
  /// AGENTS.md 原本写的是"让 WebView 自己处理 401，会弹原生口令框"，
  /// 但那是错的：`webview_flutter_android` 在原生层**重写**了
  /// `WebViewClient.onReceivedHttpAuthRequest`，把它转发给 Dart；
  /// 而 Dart 侧若没注册这个回调，插件的 `else` 分支直接
  /// `httpAuthHandler.cancel()`（见 android_webview_controller.dart:1553）。
  /// 结果是加载被静默取消 —— 没有错误、没有回调、只有一片空白，
  /// 正是"进入后黑屏"的原因。
  ///
  /// 所以这里自己弹框收口令，再用 `onProceed` 交给 WebView。
  /// 口令只存在于这次回调的局部变量里，**不落盘、不打日志**。
  Future<void> _onHttpAuthRequest(HttpAuthRequest request) async {
    if (!mounted) {
      request.onCancel();
      return;
    }

    final _Credential? credential = await showDialog<_Credential>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => _BasicAuthDialog(host: request.host),
    );

    if (credential == null) {
      request.onCancel();
      return;
    }

    request.onProceed(
      WebViewCredential(
        user: credential.user,
        password: credential.password,
      ),
    );
  }

  /// SSL 证书错误的处理 —— **本项目唯一的安全判断点**。
  ///
  /// 自签证书系统默认不信任（常见于自建部署，SAN 里可能直接写 IP）。
  /// 但无脑 `proceed()` 等于对**任何**证书放行（包括中间人），因此这里：
  ///
  /// 1. 想办法拿到出错的 host（见 [_hostOfSslError]）
  /// 2. 只有它在 [kKnownHosts] 白名单里才 `proceed()`
  /// 3. 其余一律 `cancel()` 并把错误呈现给用户
  ///
  /// 这是有意的取舍：宁可让用户看到一次明确的拒绝，也不做全局放行。
  Future<void> _onSslAuthError(SslAuthError error) async {
    final String? host = _hostOfSslError(error);

    if (host != null && kKnownHosts.contains(host)) {
      await error.proceed();
      if (mounted && !_certificateAccepted) {
        setState(() => _certificateAccepted = true);
      }
      return;
    }

    // 不在白名单（或拿不到 host）—— 拒绝，并告诉用户为什么。
    await error.cancel();
    if (!mounted) return;
    setState(() {
      _error = host == null
          ? '证书校验失败，但无法确定是哪个主机。\n'
              '为避免中间人攻击，App 不会在无法判定主机时放行自签证书。'
          : '证书校验失败：$host 不在已知入口列表里。\n'
              '为避免中间人攻击，App 不会对未知主机放行自签证书。\n'
              '如果你确实要连这台机器，请先安装它的 CA 证书到系统信任。';
    });
  }

  /// 从 SSL 错误里取出出错的 host。
  ///
  /// 这里必须反射到平台实现：`webview_flutter` 的公共层 [SslAuthError] **只**暴露
  /// `certificate` / `description` / `proceed` / `cancel`，**没有 host 或 url**
  /// （已核对 4.14.1 的 `navigation_delegate.dart:231` 与
  /// `platform_ssl_auth_error.dart`）。而两个平台的实现各自加了自己的字段：
  ///
  /// - Android（`AndroidSslAuthError`）：有 `url`
  /// - WKWebView（`WebKitSslAuthError`）：有 `host` / `port`
  ///
  /// 所以按字段名动态取。**取不到就返回 null**，调用方会拒绝放行 ——
  /// 失败方向是"更安全"的那一侧，这正是我们要的。
  ///
  /// 代价：这依赖两个平台插件的内部字段名。它们改名时不会编译报错，只会
  /// 静默退化成"拒绝放行"。所以这条路径**必须在真机验一次**（见交付清单）。
  /// 之所以不用 `dynamic` 硬解包而是留这个兜底，是因为最坏情况只是连不上，
  /// 而不是悄悄信任了一个坏证书。
  String? _hostOfSslError(SslAuthError error) {
    final Object platform = error.platform;

    // WKWebView 走这条：直接有 host。
    if (platform is WebKitSslAuthError) {
      return platform.host;
    }

    // Android 走这条：只有 url，从中解出 host。
    if (platform is AndroidSslAuthError) {
      return Uri.tryParse(platform.url)?.host;
    }

    return null;
  }

  /// 只在"主文档加载失败"时显示错误页。
  ///
  /// 子资源失败（图片、字体、埋点请求）不该把整个页面顶掉 —— 那是很常见的噪音，
  /// 用 `request?.isForMainFrame` 区分。
  void _onWebResourceError(WebResourceError error) {
    if (!mounted) return;

    final bool isMainFrame = error.isForMainFrame ?? true;
    if (!isMainFrame) return;

    setState(() {
      _error = _describeError(error);
    });
  }

  String _describeError(WebResourceError error) {
    final String detail = error.description;
    return switch (error.errorType) {
      WebResourceErrorType.hostLookup =>
        '找不到主机 ${widget.entry.uri.host}。\n确认手机网络是否正常、地址是否写对。',
      WebResourceErrorType.connect =>
        '连不上 ${widget.entry.uri.host}:${widget.entry.uri.port}。\n'
            '服务端可能没开或不可达，也可能换了端口。',
      WebResourceErrorType.timeout => '连接超时。\n服务端可能没开，或者网络不通。',
      WebResourceErrorType.failedSslHandshake =>
        'TLS 握手失败。\n如果服务端换了证书，可能需要重新确认这个入口。',
      _ => '加载失败：$detail',
    };
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    await _controller.loadRequest(widget.entry.launchUri);
  }

  @override
  Widget build(BuildContext context) {
    final String? error = _error;

    return Scaffold(
      // 刻意做得**不像浏览器**：没有地址栏、不显示 URL、没有前进/后退。
      // 这是个套壳 App，用户要的是"打开就是 dsh"，不是"又一个浏览器"。
      // 标题位置放 logo（跟首屏一致），信息性的东西（当前入口、清 Cookie）
      // 都收进设置页。
      appBar: AppBar(
        toolbarHeight: 48,
        titleSpacing: 16,
        centerTitle: false,
        title: Image.asset('assets/brand/logo_white.png', height: 22),
        bottom: error == null && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress / 100),
              )
            : null,
        actions: <Widget>[
          // 加载中转圈，比刷新按钮更有信息量；加载完才换成可点的刷新。
          if (_progress < 100 && error == null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
          if (widget.onOpenSettings != null)
            IconButton(
              onPressed: widget.onOpenSettings,
              icon: const Icon(Icons.settings),
              tooltip: '设置',
            ),
        ],
      ),
      body: error != null ? _buildErrorView(error) : _buildWebView(),
    );
  }

  Widget _buildWebView() {
    return Column(
      children: <Widget>[
        if (_certificateAccepted)
          MaterialBanner(
            content: Text('已放行 ${widget.entry.uri.host} 的自签证书'),
            leading: const Icon(Icons.lock_outline),
            actions: <Widget>[
              TextButton(
                onPressed: () => setState(() => _certificateAccepted = false),
                child: const Text('知道了'),
              ),
            ],
          ),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    );
  }

  Widget _buildErrorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.cloud_off, size: 56),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
            const SizedBox(height: 12),
            // 自动进入之后，这个错误页就是用户唯一能落脚的地方 ——
            // 所以必须给一条回输入框的路，否则地址变了/服务端没开时会被困住。
            if (widget.onChangeAddress != null)
              TextButton.icon(
                onPressed: widget.onChangeAddress,
                icon: const Icon(Icons.edit_location_alt_outlined),
                label: const Text('换个地址'),
              ),
            const SizedBox(height: 8),
            // 只给 host 和入口标签，**不显示完整 URL** ——
            // 既避免泄露可能带 token 的地址，也更像 App 而不是浏览器。
            Text(
              '${widget.entry.uri.host}（${describeEntry(widget.entry.uri)}）',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 一次 Basic 认证的凭据。只在内存里活到回调结束，绝不落盘。
class _Credential {
  const _Credential(this.user, this.password);

  final String user;
  final String password;
}

/// Basic 凭据输入框。
///
/// 一个独立的 StatefulWidget 是因为要管两个 TextEditingController 的生命周期；
/// 用有状态对话框比在调用处手动 dispose 干净。
class _BasicAuthDialog extends StatefulWidget {
  const _BasicAuthDialog({required this.host});

  final String host;

  @override
  State<_BasicAuthDialog> createState() => _BasicAuthDialogState();
}

class _BasicAuthDialogState extends State<_BasicAuthDialog> {
  // 用户名从构建时配置读（[kBasicAuthUser]），默认 `dsh`。
  // 让用户少敲一次；口令永远不预填。
  final TextEditingController _userController = TextEditingController(
    text: kBasicAuthUser,
  );
  final TextEditingController _passwordController = TextEditingController();

  bool _obscure = true;

  @override
  void dispose() {
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final String user = _userController.text;
    final String password = _passwordController.text;
    if (user.isEmpty || password.isEmpty) {
      return;
    }
    Navigator.of(context).pop(_Credential(user, password));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('需要登录凭据'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '${widget.host} 要求认证。\n'
            '口令仅用于本次请求，App 不会保存它。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _userController,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: _obscure,
            autocorrect: false,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '口令',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
                tooltip: _obscure ? '显示' : '隐藏',
              ),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('连接')),
      ],
    );
  }
}
