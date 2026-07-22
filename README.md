<p align="center">
  <img
    src="https://cloud.dingdangnao.com/260712/d2ea199a-1322-4921-9015-829fb8c594d2.png"
    alt="Snoopy Screensaver Preview"
    width="600"
  />
</p>

<p align="center">
  <strong>English</strong> |
  <a href="./README_zh-CN.md">简体中文</a>
</p>

# Snoopy Screensaver for macOS

A macOS adaptation of the Snoopy screen saver from Apple TV.

> This is an unofficial project and is not affiliated with Apple, Peanuts Worldwide, or any other relevant rights holders.

**Created by 叮噹鬧 | DINGDANGNAO**

This project was built primarily with Codex 😂

---

## Download the Latest Version

Download the latest prebuilt version of **Snoopy Screensaver for macOS**:

* [Google Drive](https://drive.google.com/file/d/1zl3f0EEWFcJw_gS6e96lo1ba6qe5-6TI/view?usp=sharing)
* [Baidu Netdisk](https://pan.baidu.com/s/1zWw7ZDcAb75JAsjp5x8G1Q?pwd=utpq)  passcode: `utpq`

After downloading, extract the archive and place the screen saver file in `~/Library/Screen Savers/`.

---

## Project Contents

This repository includes:

* The screen saver playback engine
* The Xcode project
* Asset loading and playback logic

This repository does not directly host any Snoopy videos, images, or other media assets.

An additional asset package of approximately **7.2 GB** is required to run the project. After downloading and extracting it, place the `SnoopyAssets` folder inside the project's `Resources` directory.

Example directory structure:

```text
SnoopyTVScreenSaver/
├── Resources/
│   └── SnoopyAssets/
├── SnoopyTVScreenSaver.xcodeproj
└── ...
```

### Asset Package Downloads

* [Google Drive](https://drive.google.com/file/d/1nMUCcU_zkRBOaJ5IQS8BWdLUJLnOv4Ai/view?usp=sharing)
* [Quark Cloud Drive](https://pan.quark.cn/s/554975cdd205?pwd=vKiR), passcode: `vKiR`
* [Baidu Netdisk](https://pan.baidu.com/s/1sfme9oQ2ruLxBNSkK5SFOg), passcode: `53cm`

These download links are provided solely for project compatibility testing and technical research. No guarantee is made regarding link availability or file integrity.

---

## System Requirements

* macOS 14 or later
* Xcode
* An Apple Silicon or Intel Mac

---

## Building

The project includes `SnoopyTVScreenSaver.xcodeproj` with a single Screen Saver target.

```sh
xcodebuild \
  -project SnoopyTVScreenSaver.xcodeproj \
  -scheme SnoopyTVScreenSaver \
  -configuration Release \
  ONLY_ACTIVE_ARCH=NO \
  build
```

Supported processor architectures depend on the Xcode Build Settings and the resulting build output.

If the project includes a post-build installation script, a successful build will install `SNOOPY.saver` to:

```text
~/Library/Screen Savers/
```

You can also install the screen saver manually by double-clicking the `.saver` file.

---

## Copyright and Disclaimer

Snoopy, Peanuts, Apple TV, and all related names, characters, trademarks, and media assets belong to their respective rights holders.

This is an unofficial technical research and compatibility playback project. It is not affiliated with, authorized by, sponsored by, endorsed by, or developed in cooperation with Apple, Peanuts Worldwide, or any other relevant rights holders.

Third-party media assets do not belong to the author of this project. Users are solely responsible for downloading, using, and storing such assets and must comply with all applicable laws, regulations, and requirements imposed by the relevant rights holders.

Copyright © 2026 DINGDANGNAO. All rights reserved.
