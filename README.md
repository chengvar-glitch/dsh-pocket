# DSH Pocket

把自部署的 `dsh web` 装进 Android / macOS 的 WebView 壳。

**私用项目，随手开源。** 它配合一个自己搭的 dsh web 服务端用，
单独 clone 下来没有服务端可连。没有文档站、没有 support、不追新。

## 做什么

- 记住入口地址，下次打开直接进，不用重复点连接
- 自签证书**只对白名单 host 放行**，其余拒绝
- 自己应答 HTTP Basic 挑战（插件不处理会静默黑屏）
- 启动令牌只在内存里用一次，不落盘
- 出错给可重试的页面，不留白屏

不做账号体系、不存令牌、不做离线模式。

## 构建

连接信息全部构建时注入，仓库里不含任何真实地址：

```bash
flutter build apk --release --target-platform android-arm64 \
  --dart-define=DSH_DEFAULT_URL=https://dsh.example.com/ \
  --dart-define=DSH_KNOWN_HOSTS=dsh.example.com \
  -P dshCleartextHost=10.0.0.5
```

全部可选。不传就是空的（首次打开手动填地址）、且不放行任何自签证书。

| 参数 | 作用 | 不传时 |
|---|---|---|
| `DSH_DEFAULT_URL` | 首屏预填地址 | 空 |
| `DSH_KNOWN_HOSTS` | 证书放行白名单，逗号分隔 | 空 = 不放行自签证书 |
| `DSH_BASIC_USER` / `DSH_BASIC_HINT` | 凭据框预填与提示 | `dsh` / 通用文案 |
| `-P dshCleartextHost` | 允许明文 HTTP 的那一个 host | `invalid.invalid` |

macOS 用 `flutter run -d macos`（需要 Xcode，开发机没法交叉编译）。
Linux 只用来在开发机上冒烟测试，WebView 支持不完整。

```bash
flutter analyze && flutter test    # 40 个用例
python3 tool/make_icons.py         # 改图标后跑，然后自检居中
```

## 许可

[MIT](LICENSE)

开发笔记和踩过的坑记在 [AGENTS.md](AGENTS.md)。
