<p align="center">
  <img
    src="https://cloud.dingdangnao.com/260712/d2ea199a-1322-4921-9015-829fb8c594d2.png"
    alt="Snoopy Screensaver Preview"
    width="600"
  />
</p>

<p align="center">
  <a href="./README.md">English</a> |
  <strong>简体中文</strong>
</p>

# Snoopy Screensaver for macOS

将 Apple TV 上的史努比屏幕保护程序适配到 macOS。

> 非官方项目，与 Apple、Peanuts Worldwide 或相关权利人无关。

**Created by 叮噹鬧 | DINGDANGNAO**

整个项目主要使用 Codex 编写 😂

---

## 下载最新版

下载已构建完成的最新版 **Snoopy Screensaver for macOS**：

* [Google Drive](https://drive.google.com/file/d/1xeIGd-na8fgRbtPliKTqP6ZnWVftGzr4/view?usp=sharing)
* [百度网盘](https://pan.baidu.com/s/1iUb5QOQVEUUUVpUHGfWW6w?pwd=4xvm)  提取码：`4xvm`

---

## 项目内容

本仓库包含：

* 屏幕保护程序播放引擎
* Xcode 工程
* 素材加载与播放逻辑

本仓库不直接托管史努比视频、图片或其他媒体素材。

运行本项目需要额外下载约 **7.2 GB** 的素材包。下载并解压后，将 `SnoopyAssets` 文件夹放入项目的 `Resources` 目录。


目录结构示例：

```text
SnoopyTVScreenSaver/
├── Resources/
│   └── SnoopyAssets/
├── SnoopyTVScreenSaver.xcodeproj
└── ...
```

### 素材包下载

* [Google Drive](https://drive.google.com/file/d/1nMUCcU_zkRBOaJ5IQS8BWdLUJLnOv4Ai/view?usp=sharing)
* [夸克网盘](https://pan.quark.cn/s/554975cdd205?pwd=vKiR)，提取码：`vKiR`
* [百度网盘](https://pan.baidu.com/s/1sfme9oQ2ruLxBNSkK5SFOg)，提取码：`53cm`

下载链接仅用于项目兼容性测试和技术研究。链接的可用性及文件完整性不作保证。

---


## 系统要求

* macOS 14 或更高版本
* Xcode
* Apple Silicon 或 Intel Mac

---

## 构建

项目包含 `SnoopyTVScreenSaver.xcodeproj`，并提供一个 Screen Saver target。

```sh
xcodebuild \
  -project SnoopyTVScreenSaver.xcodeproj \
  -scheme SnoopyTVScreenSaver \
  -configuration Release \
  ONLY_ACTIVE_ARCH=NO \
  build
```

支持的处理器架构以项目中的 Xcode Build Settings 和实际构建产物为准。

如果项目已配置构建后安装脚本，构建成功后会将 `Snoopy TV.saver` 安装到：

```text
~/Library/Screen Savers/
```

也可以手动双击 `.saver` 文件进行安装。

---

## 版权与免责声明

Snoopy、Peanuts、Apple TV 及相关名称、角色、商标和媒体资源归各自权利人所有。

本项目是非官方的技术研究与兼容播放实现，与 Apple、Peanuts Worldwide 或其他相关权利人不存在授权、赞助、认可或合作关系。

第三方媒体素材不属于本项目作者，其下载、使用和保存行为由使用者自行负责，并应遵守适用的法律法规及相关权利人的要求。

Copyright © 2026 DINGDANGNAO. All rights reserved.