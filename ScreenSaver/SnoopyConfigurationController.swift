import AppKit

private final class SnoopyConfigurationBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class SnoopyConfigurationController: NSObject {
    private let panel: NSPanel
    private let enabledButton = NSButton(checkboxWithTitle: "根据当地天气插播场景和动画", target: nil, action: nil)
    private let cityField = NSTextField(string: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存并更新天气", target: nil, action: nil)

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        super.init()
        buildInterface()
    }

    var window: NSWindow {
        reload()
        return panel
    }

    private func buildInterface() {
        panel.title = "SNOOPY 设置"
        // Let the host supply Aqua or Dark Aqua to the complete view tree.
        // A drawn semantic background stays in sync with the controls even in
        // legacy screen-saver hosts that override a sheet's appearance after
        // it has been created; a cached CGColor would not update here.
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = SnoopyConfigurationBackgroundView(frame: panel.contentView?.bounds ?? .zero)
        enabledButton.target = self
        enabledButton.action = #selector(toggleWeather(_:))
        cityField.placeholderString = "例如：上海、Shanghai、杭州"

        let title = NSTextField(labelWithString: "天气联动")
        title.font = .boldSystemFont(ofSize: 18)
        title.textColor = .labelColor
        let locationLabel = NSTextField(labelWithString: "所在地")
        locationLabel.font = .systemFont(ofSize: 13, weight: .medium)
        locationLabel.textColor = .labelColor
        let explanation = NSTextField(wrappingLabelWithString:
            "输入城市即可，不申请系统定位权限。天气会在后台缓存约 1 小时，只影响素材候选权重，不会打断或等待播放。"
        )
        explanation.textColor = .secondaryLabelColor
        let source = NSTextField(wrappingLabelWithString:
            "免费免密钥数据源：Open-Meteo；不会调用 WeatherKit。无法获取天气时，屏保会自动使用普通播放逻辑。"
        )
        source.textColor = .tertiaryLabelColor
        source.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        saveButton.target = self
        saveButton.action = #selector(saveAndRefresh(_:))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [
            title, enabledButton, locationLabel, cityField, explanation, statusLabel, source, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        cityField.translatesAutoresizingMaskIntoConstraints = false
        explanation.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        source.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            cityField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            source.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reload() {
        enabledButton.state = SnoopyPreferences.weatherEnabled ? .on : .off
        cityField.stringValue = SnoopyPreferences.defaults.string(forKey: SnoopyPreferences.cityNameKey) ?? ""
        if let snapshot = SnoopyPreferences.weatherSnapshot(), snapshot.isUsable {
            let time = DateFormatter.localizedString(from: snapshot.observedAt, dateStyle: .none, timeStyle: .short)
            statusLabel.stringValue = "最近更新：\(snapshot.locationName ?? cityField.stringValue) · \(snapshot.conditions.joined(separator: ", ")) · \(time)"
        } else {
            statusLabel.stringValue = "尚无可用天气缓存。保存后会立即更新。"
        }
        updateEnabledState()
    }

    @objc private func toggleWeather(_ sender: Any?) {
        updateEnabledState()
    }

    private func updateEnabledState() {
        cityField.isEnabled = enabledButton.state == .on
        saveButton.title = enabledButton.state == .on ? "保存并更新天气" : "保存"
    }

    @objc private func cancel(_ sender: Any?) {
        finish(returnCode: .cancel)
    }

    @objc private func saveAndRefresh(_ sender: Any?) {
        let enabled = enabledButton.state == .on
        if !enabled {
            SnoopyPreferences.weatherEnabled = false
            finish(returnCode: .OK)
            return
        }
        let city = cityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard city.count >= 2 else {
            statusLabel.stringValue = SnoopyWeatherError.invalidCity.localizedDescription
            NSSound.beep()
            return
        }
        setBusy(true, status: "正在解析所在地并更新天气…")
        Task {
            do {
                let client = SnoopyWeatherClient()
                let location = try await client.resolve(city: city)
                let snapshot = try await client.fetch(location: location)
                SnoopyPreferences.save(weatherLocation: location)
                SnoopyPreferences.save(weatherSnapshot: snapshot)
                SnoopyPreferences.weatherEnabled = true
                statusLabel.stringValue = "已更新：\(location.name) · \(snapshot.conditions.joined(separator: ", "))"
                setBusy(false)
                finish(returnCode: .OK)
            } catch {
                setBusy(false, status: error.localizedDescription)
                NSSound.beep()
            }
        }
    }

    private func setBusy(_ busy: Bool, status: String? = nil) {
        enabledButton.isEnabled = !busy
        cityField.isEnabled = !busy && enabledButton.state == .on
        saveButton.isEnabled = !busy
        if let status { statusLabel.stringValue = status }
    }

    private func finish(returnCode: NSApplication.ModalResponse) {
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: returnCode)
        } else {
            panel.orderOut(nil)
        }
    }
}
