<p align="center">
  <img
    src="https://cloud.dingdangnao.com/260712/d2ea199a-1322-4921-9015-829fb8c594d2.png"
    alt="preview"
    width="600"
  >
</p>

# Snoopy Screensaver for macOS

Credits: 叮噹鬧 | DINGDANGNAO

Apple TV 史努比屏幕保护程序移植

整个项目使用 Codex 编写😂

---

## 仓库内容与素材包

GitHub 仓库只包含播放引擎、Xcode 工程，素材文件需在下方单独下载。

从网盘下载并解压后 将 `SnoopyAssets` 文件夹放到 `Resources` 文件夹中。

Google Drive
```
https://drive.google.com/file/d/1nMUCcU_zkRBOaJ5IQS8BWdLUJLnOv4Ai/view?usp=sharing
```

Quark 夸克网盘
```
链接：https://pan.quark.cn/s/554975cdd205?pwd=vKiR
提取码：vKiR
```

百度云
```
链接: https://pan.baidu.com/s/1sfme9oQ2ruLxBNSkK5SFOg
提取码: 53cm 
```

---

## 构建

项目包含 `SnoopyTVScreenSaver.xcodeproj`，只有一个 Screen Saver target。部署目标为 macOS 14，屏保构建为 `arm64e + x86_64`：

```sh
xcodebuild -project SnoopyTVScreenSaver.xcodeproj \
  -scheme SnoopyTVScreenSaver -configuration Release \
  ARCHS='arm64e x86_64' ONLY_ACTIVE_ARCH=NO build
```

共享 Scheme 在成功构建后会自动签名并安装 `Snoopy TV.saver` 到 `~/Library/Screen Savers/`。

---

## 发布说明

Snoopy、Peanuts、Apple TV 及相关名称、角色和媒体资源归各自权利人所有。本项目是非官方的技术研究与兼容播放实现，不包含也不授权分发相关媒体。公开发布前请自行选择适合源代码的许可证；在许可证确定前，仓库默认保留全部代码权利。
