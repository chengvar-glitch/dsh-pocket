# AGENTS.md

本目录（`~/dev/dsh-pocket`）中 agent 的工作指南：**Flutter 套壳 WebView 客户端**，
目标是在 **Android 手机**和 **macOS（Apple Silicon）** 上打开就能连上 `dsh web`。

> 状态：**业务代码已写完 + 47 个测试通过 + APK 可构建**；
> Android 真机已跑过（发现并修掉了两个"静默失败"级 bug，见认证事实第 1、2 条），
> **但凭据记忆、Cookie 持久化、证书白名单、内网直连仍未验；macOS 完全未验**（见 §8 清单）。
> 先读完本文件再动手；尤其先读「认证模型」和「雷区」。
>
> ⚠️ 本文件的 §4、雷区 2、3，以及认证事实第 1、2 条，都曾被真机实测证伪并已改写。
> 若你在别处看到旧说法，以本文件为准。

---

## 1. 这是什么 / 不是什么

- **是**：一个极薄的壳。核心就是 `webview_flutter` 加载 `dsh web` 的地址，
  外加"地址记忆、自签证书放行、扫码导入、外部浏览器打开"这几件让它在手机上真的好用的事。
- **不是**：不是 dsh 的重写版，不实现聊天/终端/文件 UI，不做本地后端。
  **一切功能都在 dsh web 里，壳只负责把它显示好。** 想加功能先问：这是不是该在服务端做？
- **不做**：不做账号体系、不存令牌、不做离线模式、不内嵌 Node/dsh 运行时。

### 与服务端的关系

本项目是**客户端**。服务端（`dsh web`）是**另一个独立部署的服务**，
有自己的仓库和运维方式。改本项目**不需要**动服务端。

**本仓库刻意不描述服务端的任何内部实现** —— 拓扑、端口、反向代理、
认证分层、Cookie 细节都属于服务端私有信息，不放进公开仓库。
客户端只依赖下面这些**抽象的**行为契约。

---

## 2. 认证模型（客户端必须理解的抽象行为）

服务端可能要求**两层**认证。客户端不需要知道它们具体怎么实现，
但必须正确处理这两种挑战 —— 因为处理错了都会**静默失败**：

| 层 | 客户端怎么知道 | 客户端该做什么 |
|---|---|---|
| **HTTP Basic 挑战** | WebView 回调 `onHttpAuthRequest` | 用**记住的凭据**自动应答；没有才弹框。见认证事实 2 |
| **URL 里的启动令牌** | 用户粘贴的地址带 `?token=…` | 用它走**一次**导航，换回长期 Cookie。见认证事实 1 |

⚠️ **Cookie 不能替代 Basic 凭据** —— 这条是实测出来的，别搞反：

```
带有效的会话 Cookie、但不带 Basic 凭据 → 401
```

Basic 挑战是**每个请求**都查的（实测过：同一 Cookie 连发两次，两次都 401）。
所以"第二次打开免口令"**只能**靠记住凭据（见认证事实 2），
Cookie 只解决"会话"那一层。

### 三个必须记住的认证事实

1. **启动令牌是必需的，但绝不能持久化。**
   令牌短期有效、重启即变，只能来自用户粘贴/扫码的 URL。
   ⚠️ 但**也不能扔掉它**（早期版本扔掉了，结果粘完地址照样连不上，真机证伪）。
   正确做法是分成两个 Uri：
   - `EntryParseOk.uri` —— 规范化 origin，**唯一会被持久化**的东西，不含 token
   - `EntryParseOk.launchUri` —— 拼回 `?token=…`，**只用于 WebView 首次导航**

   见 `lib/entry_parser.dart`。令牌活在内存里，`EntryStore` 永远只写 origin。
2. **Basic 挑战必须由 App 自己应答 —— 不要指望 WebView 的原生对话框。**
   本文件原本写的是"WebView 会自己弹原生口令框，App 不用管"，**这是错的，已在真机证伪**：
   `webview_flutter_android` 在原生层重写了 `WebViewClient.onReceivedHttpAuthRequest`
   并转发给 Dart，而 Dart 侧没注册 `onHttpAuthRequest` 时，插件直接走
   `httpAuthHandler.cancel()`（`android_webview_controller.dart:1553` 的 `else` 分支）。
   **症状：页面静默死掉 —— 没有错误页、没有回调、一片空白，加载进度卡住。**
   正确做法见 `lib/webview_screen.dart` 的 `_onHttpAuthRequest`（自己弹框 + `onProceed`）。
3. **服务端会种长期 Cookie，但它只顶替会话层，顶替不了 Basic 凭据。**
   → "第二次打开不用输口令"靠的是 **`CredentialStore` 记住凭据**：
   挑战来了先自动应答（`lib/webview_screen.dart` 的 `_onHttpAuthRequest`），
   用户看不到框；没有记住的才弹框。
   凭据存在系统密钥库（`flutter_secure_storage`），**不是** shared_preferences
   （那是明文，口令放进去等于裸奔）。

   **注意**：Android WebView 默认就接受 Cookie 并落盘，插件**没有**开关给你开
   （详见雷区 3 —— 原文档这里写的 API 不存在）。

---

## 3. 技术选型（已定，别随手换）

| 选择 | 原因 |
|---|---|
| `webview_flutter` ^4.14.1 | 官方插件，Android/macOS 一套 API；macOS 端用 WKWebView |
| `url_launcher` | "用系统浏览器打开"（某些登录/OAuth 场景 WebView 会失败） |
| `shared_preferences` | 记住上次地址，轻量够用，不引数据库 |
| `flutter_secure_storage` | 记住 Basic 凭据。**口令不能进 shared_preferences**（明文） |
| **不自绘 WebView** | PlatformView 的坑远多于收益 |

**平台范围**：`android` + `macos`（+ `linux` 仅因本机是 Linux，方便在开发机上冒烟测试）。
**iOS 暂不做**：本机没有 Xcode，无法验证；将来要加就 `flutter create --platforms=ios .` 补。
**Web/Windows 不做**。

---

## 4. 本机开发环境的真实约束（重要）

**这台开发机是 Ubuntu 26.04 x86_64，不是 Mac。**

| 能力 | 状态 |
|---|---|
| Flutter | ✅ 3.47.4 stable，在 `/opt/flutter` |
| Dart | ✅ 3.13.3 |
| Linux desktop 构建 | ✅ 可用（本机唯一能真跑的目标） |
| Android 构建 | ✅ **可用**。SDK 在 `/opt/android-sdk`（platform 36 / build-tools 36.0.0）；需要一个 JDK 17+（本机是 `~/.jdks/TencentKona-21.0.12.b1`）。`JAVA_HOME` 没配进 shell，所以每条命令都要带上前缀，见 §8 |
| **macOS 构建** | ❌ **完全不可能**（没有 Xcode、不是 macOS） |
| iOS 构建 | ❌ 同上 |

**推论**（写代码时必须接受）：
- 我**无法在本机验证 macOS 产物**，macOS 相关代码是"声称正确"，必须由用户在自己的
  M 芯片 Mac 上 `flutter run -d macos` 实测。
- Android 侧在装好 JDK 后**可以**在本机编译，但也只能在真机/模拟器上验行为。
- 因此：**任何改动都要明确标注"已在本机验证"还是"未验证、需在目标机验证"**。

### 本机可用的冒烟测试

```bash
cd ~/dev/dsh-pocket
flutter analyze                       # 静态检查，必跑
flutter test                          # 单元/widget 测试
flutter run -d linux                  # 本机能真跑，用来验 UI 和 WebView 逻辑
```
Linux 端 WebView 支持不完整，**不要把 Linux 跑通当成 Android/macOS 也通了**。

---

## 5. 目录结构

```
dsh-pocket/
├── AGENTS.md                  ← 本文件
├── README.md                  ← 面向自己：这是什么 + 怎么构建（有意写得很短）
├── pubspec.yaml
├── assets/brand/              ← DSH 官方 logo（见下）
├── tool/make_icons.py         ← 从 SVG 生成各平台图标（纯 pycairo，无新依赖）
├── lib/                       ← 业务代码（8 个文件，见 §6 的表）
├── android/ macos/ linux/
└── test/                      ← 47 个用例：entry_parser / home_screen / credential_store
```

### 图标与品牌资源

- 源文件取自 DSH 官方前端产物：`@deepseek-ai/dsh-web-frontend/dist/favicon.svg`
  （DSH = DeepSeek Harness 的鲸鱼 logo）。黑/白两版已复制进 `assets/brand/`。
- `tool/make_icons.py` 生成 **23 个**图标：Android mipmap 五档密度（含自适应图标前景）、
  macOS `AppIcon.appiconset`（文件名严格对齐 Flutter 生成的 `Contents.json`）、
  Linux 四档、以及 App 内使用的 PNG。
- **改图标一律重跑脚本**，不要手改 PNG：
  ```bash
  python3 tool/make_icons.py
  ```
  **自检口径**（改完一定要跑，光看"生成了 23 个文件"不够）：

  ```bash
  python3 - <<'PY'
  from PIL import Image
  import glob
  bad = []
  for p in glob.glob('android/app/src/main/res/mipmap-*/ic_launcher*.png') + \
           glob.glob('macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png') + \
           ['assets/brand/logo_white.png', 'assets/brand/logo_black.png']:
      im = Image.open(p).convert('RGBA'); w, h = im.size
      bb = im.split()[3].getbbox()
      if not bb: bad.append(f'{p} 全透明'); continue
      dx = (bb[0]+bb[2])/2 - w/2; dy = (bb[1]+bb[3])/2 - h/2
      if abs(dx) > 2 or abs(dy) > 2:
          bad.append(f'{p} 未居中 偏移=({dx:+.1f},{dy:+.1f})')
  print('图标居中:', '全部通过 ✅' if not bad else bad)
  PY
  ```

  ⚠️ **踩过**：早期版本只检查"path 控制点包围盒 x[0.53,49.37] y[6.94,43.58]、
  纵横比 1.333"，那只能证明**解析器**没坏，**证明不了居中**。
  实际当时所有图标都偏上（512px 的 App 内 logo 偏 63px，约 12%），
  因为 `draw_logo` 的缩放系数由宽度决定，纵向却只平移了 -INK_TOP，
  没补上"墨迹缩放后比画布矮"的那部分。现在改成用 `ink_bounds()`
  实测墨迹包围盒再把中心对齐画布中心。**所以自检必须查偏移，不能只查比例。**
- **为什么自己写 SVG 渲染**：本机没有 cairosvg/rsvg/inkscape，系统 pip 被 PEP 668 拦，
  `python3 -m venv` 又缺 `python3-venv`。但系统自带 **pycairo**，logo 恰好是单条 flat path，
  所以自己解析 path data 填充 —— **零新依赖、零 sudo**。别为了换个图标去 `apt install`。

---

## 6. 行为规格（写代码时按这个来）

### 启动流程

1. 读 `shared_preferences` 里的上次地址；没有就用构建时注入的 `DSH_DEFAULT_URL`
   （**可能为空** —— 开源构建就是空的，此时首屏留空让用户自己填）。
   存进去的一律是规范化后的 origin（`scheme://host[:port]/`），**不含 `?token=`**。
   但用户这次粘贴进来的令牌要留在内存里，用 `launchUri` 走第一次导航（见认证事实第 1 条）。
   **有地址就直接进 WebView，不再让用户点一次「连接」**。
   要不要输口令则取决于 `CredentialStore` 里有没有这个 host 的凭据：
   有就自动应答（用户看不到框），没有才弹框。只有"没有任何地址"时才停在输入框。
   ⚠️ 因为会自动进入，[WebViewScreen] 的错误页必须有「换个地址」的退路
   （`onChangeAddress`），否则服务端没开时用户会被困在错误页出不来。
2. 建 WebView。Cookie 持久化不用手动开（见雷区 3）。
3. 处理自签证书（见雷区 1、2）→ **只对白名单 host 放行**，其余拒绝并显示原因。
4. 加载地址。**自己处理凭据**（`onHttpAuthRequest`）：
   先查 `CredentialStore` 有没有记住 → 有就直接 `onProceed`，
   没有才弹框收，收到后**存进密钥库**再 `onProceed`。
   ⚠️ 别指望 WebView 原生 UI，理由见上面「认证事实」第 2 条。
5. 凭据通过后，若 URL 带 `?token=`，服务端会把它换成长期 Cookie。

### 代码结构（`lib/`，已实现）

| 文件 | 职责 |
|---|---|
| `config.dart` | 构建时可注入的配置常量集中处 |
| `entry_parser.dart` | 地址解析/校验 + 扫码 URL 解析。**纯 Dart，无 Flutter 依赖**，被测试完整覆盖 |
| `entry_store.dart` | `shared_preferences` 持久化，只存 origin |
| `credential_store.dart` | **凭据持久化**，走系统密钥库。按 host 分开存 |
| `home_screen.dart` | 首屏：logo + 地址输入 + 连接 |
| `webview_screen.dart` | WebView、证书白名单、进度条、错误重试页 |
| `settings_screen.dart` | 换地址、退出登录（清 Cookie + 凭据）、忘掉凭据、系统浏览器打开 |
| `main.dart` | 根 App，只定主题 + 注入 `EntryStore` |

### 必须有的 UI

- 首屏：logo（用 `assets/brand/logo_white.png`）+ 地址输入框 + 「连接」按钮。
- WebView 页：**加载进度条**、**出错时的可重试提示页**（别留白屏）、返回/刷新。
- 设置：切换地址、清除 Cookie（"退出登录"）、"在系统浏览器打开"、显示当前入口。

### 明确不要做的事

- **不要拦 `onHttpError` 的 401 当错误页** —— 但**必须**实现 `onHttpAuthRequest`
  （自己弹框）。这两件事不矛盾：前者是"拿到 401 响应后别自作聪明"，
  后者是"挑战阶段必须应答，否则请求被静默取消"。见认证事实第 2 条。
- 不要把令牌写进日志/持久化。地址栏里的 `?token=` 是**一次性**的。
- 不要把凭据写日志。它**要**持久化（否则每次都要重输），但只能进系统密钥库
  （`CredentialStore`），**不要**塞进 `shared_preferences`。
- 不要 `WebViewController.loadRequest` 硬编码地址而忽略用户存的地址。

---

## 7. 雷区（踩过 / 必然会踩，动手前先读）

1. **自签证书 = 必须放行，但别放行成"信任一切"就完事。**
   自建部署常用**自签 CA 签的证书**（SAN 里可能直接写 IP 而不是域名）。
   SSL 回调里若直接 `proceed()`，等于对**任何**证书都放行（含中间人攻击）。
   正确做法：只对**白名单 host**放行，或引导用户把 CA 装进系统信任（最干净）。
   **不要**因为"用户嫌麻烦"就全局放行 —— 这是本项目唯一的安全判断点。
   实现见 `lib/webview_screen.dart` 的 `_onSslAuthError`，白名单是
   `lib/config.dart` 的 `kKnownHosts`。
2. **macOS 侧证书 —— 原描述（"WKWebView 不给 SSL 回调，必须配 ATS"）是错的，已实测证伪。**
   `webview_flutter_wkwebview` 3.26.2 **实现了** `setOnSSlAuthError`
   （见 `webkit_webview_controller.dart:1280`，走 `serverTrust` +
   `recoverableTrustFailure` 分支），所以 macOS 能和 Android 共用同一套回调，
   **不需要在 `Info.plist` 配 ATS 例外**，更不要写 `NSAllowsArbitraryLoads`。
   ⚠️ **但 macOS 端有一个真正会白屏的坑（原文档漏了）**：App 跑在沙箱里，
   `macos/Runner/*.entitlements` 必须显式加 `com.apple.security.network.client`，
   否则 WKWebView **完全发不出网络请求**。Flutter 模板默认只给
   `app-sandbox` + `network.server`，缺这一条。已补上（Debug/Release 各一处）。
   **本机无法验证 macOS 产物，仍需用户在 Mac 上实测。**
3. **Android Cookie 持久化 —— 原描述的写法做不到，别照着找 API。**
   原文档说"必须显式 `CookieManager.setAcceptCookie(true)` + 落盘"，
   但**这个 API 在 `webview_flutter_android` 4.14.1 里根本不存在**
   （整个 Dart 层 grep 不到 `setAcceptCookie`，原生侧 `CookieManagerProxyApi`
   也没暴露它）。实际行为是：Android WebView **默认就接受 Cookie**，
   且随 App 数据目录落盘，插件不需要也不提供开关。
   → 所以这条要验的不是"有没有开开关"，而是**行为**：
   杀进程重开后是否免登录。见 §8 交付清单第 2 项。
4. **不要"优化"服务端设置的 Cookie 属性。**
   Cookie 的 `SameSite` 等属性是服务端按自己的登录流程定的
   （例如为了让外部发起的顶层导航能带上 Cookie）。客户端只负责接受它。
5. **`?token=` 会被历史记录/Referer 泄漏**：服务端已加 `Referrer-Policy: no-referrer`。
   客户端**不要再把 URL 写进日志**，也不要把带 token 的 URL 持久化 ——
   令牌用完即废，存下来只会在下次启动时得到一个过期的 401。
   ⚠️ 但注意**别过度纠正**：早期版本"为了安全"把 token 整个丢掉，
   结果扫码后照样连不上（dsh 回"authentication required"）。正确做法是
   **内存里留着走一次导航、持久化时剥掉**，两个 Uri 分开，见认证事实第 1 条。
   同理，UI 上不显示完整 URL（顶栏只有 logo），既避免泄漏也更不像浏览器。
6. **端口会变**：自建部署的入口端口可能被自动分配或调整，所以客户端
   **不能假设端口是固定的** —— 地址要可编辑、要能从粘贴/扫码导入。
7. **不要在本仓库里放服务端的运维脚本或配置。** 那是另一个项目的事。
8. **凭据必须存密钥库，不要图省事用 shared_preferences。**
   后者在 Android 上是个明文 XML、在 macOS 上是明文 plist ——
   口令放进去等于裸奔。用 `flutter_secure_storage`（Android Keystore /
   macOS Keychain）。它有 `minSdk 24` 要求，与本项目一致。
9. **Android 明文流量**：内网入口通常是 `http://<内网IP>/`（明文）。Android 9+ 默认
   禁明文，要连内网必须配 `network_security_config.xml` **只对这一个内网地址**放行
   `cleartextTrafficPermitted`，**不要**全局开 `usesCleartextTraffic="true"`。
10. **别把 `flutter create` 重新跑一遍**：会覆盖 `AndroidManifest.xml`、`AppInfo.xcconfig`、
   图标等已定制的东西。要加平台用 `flutter create --platforms=xxx .` 并**先看 diff**。

---

## 8. 验证方式

没有 CI。改完按影响面做：

```bash
cd ~/dev/dsh-pocket

# 1) 静态检查（每次必跑）+ 测试
flutter analyze
flutter test                          # 47 个用例：解析器 + 首屏 + 存储

# 2) 构建 APK（必须带上 JAVA_HOME，见 §4）
JAVA_HOME=$HOME/.jdks/TencentKona-21.0.12.b1 flutter build apk --debug
#   真机装的话用 release + 单架构，体积从 154MB 降到 18MB：
JAVA_HOME=$HOME/.jdks/TencentKona-21.0.12.b1 \
  flutter build apk --release --target-platform android-arm64
#   注意 release 目前沿用 debug 签名（build.gradle.kts 模板遗留），自用可以，上架不行。

# 3) 图标：重新生成 + 自检（数量、macOS 对齐、**居中**）
python3 tool/make_icons.py            # 预期 23 个文件
python3 - <<'PY'
import json, os, glob
from PIL import Image
d = "macos/Runner/Assets.xcassets/AppIcon.appiconset"
bad = []
# 3a) macOS 图标必须和 Contents.json 逐字对齐
for im in json.load(open(f"{d}/Contents.json"))["images"]:
    p = f"{d}/{im['filename']}"
    want = int(im["size"].split("x")[0]) * int(im["scale"][0])
    if not os.path.exists(p): bad.append(f"缺失 {p}"); continue
    if Image.open(p).size != (want, want): bad.append(f"尺寸错 {p}")
# 3b) 所有图标必须墨迹居中（只查比例查不出这个，见 §5 的踩坑记录）
for p in (glob.glob("android/app/src/main/res/mipmap-*/ic_launcher*.png")
          + glob.glob(f"{d}/*.png")
          + ["assets/brand/logo_white.png", "assets/brand/logo_black.png"]):
    im = Image.open(p).convert("RGBA"); w, h = im.size
    bb = im.split()[3].getbbox()
    if not bb: bad.append(f"{p} 全透明"); continue
    dx = (bb[0]+bb[2])/2 - w/2; dy = (bb[1]+bb[3])/2 - h/2
    if abs(dx) > 2 or abs(dy) > 2:
        bad.append(f"{p} 未居中 偏移=({dx:+.1f},{dy:+.1f})")
print("图标:", "全部通过 ✅" if not bad else bad)
PY

# 4) 本机真跑（只能验 UI/逻辑，验不了 Android/macOS 的 WebView 行为）
flutter run -d linux

# 5) 端到端连通性（不开 App 也能先确认服务端活着）
curl -k -s -o /dev/null -w '入口 -> %{http_code}\n' --max-time 6 https://<你的入口>/
#    预期 401 = 服务端在（且要求认证）；返回 000 = 没开或网络不通
```

**已在本机验证**（2026-09-30）：`flutter analyze` 无问题；`flutter test` 47/47 通过；
`flutter build apk --release --target-platform android-arm64` 成功（18.3MB），
且已核验 APK 里 `INTERNET` 权限在、`networkSecurityConfig` 指向的
`cleartextTrafficPermitted` 只对 `-P dshCleartextHost` 指定的那一个 host 生效
（不传则是 `invalid.invalid`，等于不豁免）；`flutter build linux` 通过且能启动。

**必须在目标机验证的清单**（本机做不到，交付时要向用户明确列出）：
- [x] Android 真机：**连接会弹出口令框**（已验，曾因不弹框而黑屏）
- [ ] Android 真机：粘贴带 `?token=` 的二维码地址 → 输口令 → 进入 dsh 界面
      （曾经缺 token 会看到 dsh 自己的 "authentication required" 纯文本）
- [ ] Android 真机：顶栏不再显示网址，只有 logo + 进度/刷新/设置
- [ ] Android 真机：**杀进程重开，应该免输口令**（验 `CredentialStore` 生效）
      —— 第一次输完口令后，再打开不该再弹框。**这是本次改动的核心验证点**
- [ ] Android 真机：设置页「忘掉凭据」之后，下次打开应该重新弹框
- [ ] Android 真机：自签证书能"继续访问"（雷区 1）；**再试一个未知 host，应被拒绝**
      —— 这条同时验证白名单没被写成"全局放行"，是安全性的关键回归点
- [ ] Android 真机：内网 `http://<内网IP>/` 能直连（验 `-P dshCleartextHost` 生效）
- [ ] macOS（M 芯片）：`flutter run -d macos` 能起、**能连**（先验 `network.client`
      entitlement 是否补对，见雷区 2）、证书不拦

---

## 9. 已知待办

- [x] 写 `lib/` 业务代码（首屏、WebView 页、设置页）
- [x] 构建时可注入的配置常量集中到 `lib/config.dart`
- [x] 决定证书策略：**仅放行白名单 host**（`kKnownHosts`），其余拒绝
- [x] 扫码导入地址 —— **按 YAGNI 去掉了摄像头扫码**：二维码内容就是个 URL。
      「扫码导入」退化成 `extractEntryFromScan(String)` 这个纯函数
      （**不引 `mobile_scanner`、不要摄像头权限**）。
      用户路径：用任意扫码 App 扫服务端给出的二维码，
      复制文本 → App 首屏的**粘贴按钮** → 自动校验并保留令牌。
- [x] README.md（**有意保持简短**：这是私用项目，不是产品文档）
- [x] 记住 HTTP Basic 凭据（`credential_store.dart` + `flutter_secure_storage`），
      免得每次打开都要重输口令。设置页有「忘掉凭据」「退出登录」两个入口
- [ ] app 图标已生成，但**尚未在真机确认显示效果**
- [ ] Android 真机 / macOS 实测（见 §8 清单）—— **这是当前最大的未验证面**
