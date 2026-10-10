import AppKit
import Foundation

private final class CodexFlippedView: NSView {
    override var isFlipped: Bool { true }
}

public final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: ProfileStore
    private let keychain: KeychainStore
    private let doctor: CodexManaging
    private let probe: ProviderProbe
    private var profiles: [ProviderProfile] = []
    private var selectedIndex: Int?

    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let nameField = NSTextField()
    private let baseURLField = NSTextField()
    private let modelField = NSComboBox()
    private let refreshModelsButton = NSButton(title: "读取模型", target: nil, action: nil)
    private let apiKeyField = NSSecureTextField()
    private var modelsRequestGeneration = 0
    private var formContextID = UUID()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let modelsButton = NSButton(title: "测试 models", target: nil, action: nil)
    private let responsesButton = NSButton(title: "测试 responses", target: nil, action: nil)
    private let applyButton = NSButton(title: "应用供应商", target: nil, action: nil)
    private let officialButton = NSButton(title: "官方恢复", target: nil, action: nil)
    private let newButton = NSButton(title: "新建", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let importButton = NSButton(title: "导入当前", target: nil, action: nil)

    public convenience init() {
        self.init(store: ProfileStore(), keychain: KeychainStore(), doctor: CodexDoctor(), probe: ProviderProbe())
    }

    public init(store: ProfileStore, keychain: KeychainStore, doctor: CodexManaging, probe: ProviderProbe) {
        self.store = store; self.keychain = keychain; self.doctor = doctor; self.probe = probe
        let window = NSWindow(contentRect: NSMakeRect(0, 0, 900, 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex 供应商切换器"
        window.minSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        buildUI()
        loadProfiles()
    }

    required init?(coder: NSCoder) { return nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        // Keep the window content view's frame managed by AppKit. Only the child root
        // view participates in Auto Layout; this avoids an ambiguous content frame.
        let root = CodexFlippedView()
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        let listTitle = NSTextField(labelWithString: "供应商")
        listTitle.font = NSFont.boldSystemFont(ofSize: 14)
        root.addSubview(listTitle); listTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView); scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true; scrollView.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider")); column.title = "名称"; column.width = 190
        table.addTableColumn(column); table.headerView = nil; table.delegate = self; table.dataSource = self; table.usesAlternatingRowBackgroundColors = true
        scrollView.documentView = table
        root.addSubview(newButton); root.addSubview(deleteButton); root.addSubview(importButton)
        [newButton, deleteButton, importButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.target = self }
        newButton.action = #selector(newProfile); deleteButton.action = #selector(deleteProfile); importButton.action = #selector(importCurrentProfile)

        let form = NSView(); form.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(form)
        let formTitle = NSTextField(labelWithString: "供应商配置"); formTitle.font = NSFont.boldSystemFont(ofSize: 14); formTitle.translatesAutoresizingMaskIntoConstraints = false; form.addSubview(formTitle)
        addRow(to: form, label: "名称", field: nameField, top: 34)
        addRow(to: form, label: "Base URL", field: baseURLField, top: 80)
        modelField.isEditable = true
        modelField.completes = true
        modelField.usesDataSource = false
        addModelRow(to: form, top: 126)
        baseURLField.placeholderString = "https://api.example.com/v1"
        baseURLField.delegate = self
        apiKeyField.delegate = self
        modelField.placeholderString = "填写供应商支持的模型 ID"
        addRow(to: form, label: "Secure API Key", field: apiKeyField, top: 172)
        let hint = NSTextField(labelWithString: "API Key 仅保存到当前用户钥匙串，不写入 config.toml。")
        hint.textColor = .secondaryLabelColor; hint.font = NSFont.systemFont(ofSize: 11); hint.translatesAutoresizingMaskIntoConstraints = false; form.addSubview(hint)
        form.addSubview(saveButton); form.addSubview(modelsButton); form.addSubview(responsesButton); form.addSubview(applyButton); form.addSubview(officialButton)
        [saveButton, modelsButton, responsesButton, applyButton, officialButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.target = self }
        saveButton.action = #selector(saveProfile); modelsButton.action = #selector(testModels); responsesButton.action = #selector(testResponses); applyButton.action = #selector(applyProvider); officialButton.action = #selector(restoreOfficial)
        statusLabel.lineBreakMode = .byWordWrapping; statusLabel.maximumNumberOfLines = 3; statusLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            listTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor), listTitle.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor), scrollView.topAnchor.constraint(equalTo: listTitle.bottomAnchor, constant: 8), scrollView.widthAnchor.constraint(equalToConstant: 220), scrollView.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -8),
            newButton.leadingAnchor.constraint(equalTo: root.leadingAnchor), newButton.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12), newButton.widthAnchor.constraint(equalToConstant: 100),
            deleteButton.leadingAnchor.constraint(equalTo: newButton.trailingAnchor, constant: 8), deleteButton.centerYAnchor.constraint(equalTo: newButton.centerYAnchor), deleteButton.widthAnchor.constraint(equalToConstant: 100),
            importButton.leadingAnchor.constraint(equalTo: root.leadingAnchor), importButton.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -8), importButton.widthAnchor.constraint(equalToConstant: 208),
            form.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 22), form.trailingAnchor.constraint(equalTo: root.trailingAnchor), form.topAnchor.constraint(equalTo: root.topAnchor), form.heightAnchor.constraint(equalToConstant: 300),
            formTitle.leadingAnchor.constraint(equalTo: form.leadingAnchor), formTitle.topAnchor.constraint(equalTo: form.topAnchor),
            hint.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 92), hint.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 6),
            saveButton.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 92), saveButton.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14),
            modelsButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 8), modelsButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            responsesButton.leadingAnchor.constraint(equalTo: modelsButton.trailingAnchor, constant: 8), responsesButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            applyButton.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 92), applyButton.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 14),
            officialButton.leadingAnchor.constraint(equalTo: applyButton.trailingAnchor, constant: 8), officialButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor), statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor), statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor), statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 26)
        ])
    }

    private func addModelRow(to parent: NSView, top: CGFloat) {
        let title = NSTextField(labelWithString: "模型")
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(title)
        modelField.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(modelField)
        refreshModelsButton.translatesAutoresizingMaskIntoConstraints = false
        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(refreshModels)
        parent.addSubview(refreshModelsButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            title.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
            title.widthAnchor.constraint(equalToConstant: 82),
            modelField.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            modelField.trailingAnchor.constraint(equalTo: refreshModelsButton.leadingAnchor, constant: -8),
            modelField.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            modelField.heightAnchor.constraint(equalToConstant: 24),
            refreshModelsButton.leadingAnchor.constraint(equalTo: modelField.trailingAnchor, constant: 8),
            refreshModelsButton.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            refreshModelsButton.centerYAnchor.constraint(equalTo: modelField.centerYAnchor),
            refreshModelsButton.widthAnchor.constraint(equalToConstant: 86),
            refreshModelsButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func addRow(to parent: NSView, label: String, field: NSTextField, top: CGFloat) {
        let title = NSTextField(labelWithString: label); title.alignment = .right; title.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(title)
        field.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(field)
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: parent.leadingAnchor), title.topAnchor.constraint(equalTo: parent.topAnchor, constant: top), title.widthAnchor.constraint(equalToConstant: 82), field.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: parent.trailingAnchor), field.centerYAnchor.constraint(equalTo: title.centerYAnchor), field.heightAnchor.constraint(equalToConstant: 24)])
    }

    private func loadProfiles() {
        do { profiles = try store.load(); table.reloadData(); if !profiles.isEmpty { select(index: 0) } else { clearForm() } }
        catch { setStatus("读取供应商失败：\(error.localizedDescription)") }
    }

    private func invalidateModelRequest() {
        modelsRequestGeneration += 1
        formContextID = UUID()
    }

    private func resetModelChoices(current: String) {
        modelField.removeAllItems()
        if !current.isEmpty { modelField.addItem(withObjectValue: current) }
        modelField.stringValue = current
    }

    private func clearForm() {
        invalidateModelRequest()
        selectedIndex = nil
        nameField.stringValue = ""
        baseURLField.stringValue = ""
        resetModelChoices(current: "")
        apiKeyField.stringValue = ""
        updateButtons()
    }

    private func select(index: Int) {
        guard profiles.indices.contains(index) else { clearForm(); return }
        invalidateModelRequest()
        selectedIndex = index
        let p = profiles[index]
        nameField.stringValue = p.name
        baseURLField.stringValue = p.baseURL
        resetModelChoices(current: p.model)
        apiKeyField.stringValue = ""
        updateButtons()
    }

    private func updateButtons() {
        let hasURL = !baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabled = selectedIndex != nil
        saveButton.isEnabled = true
        modelsButton.isEnabled = hasURL
        refreshModelsButton.isEnabled = hasURL
        responsesButton.isEnabled = enabled
        applyButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
    }

    private func setStatus(_ text: String) { statusLabel.stringValue = text }

    private func probeProfileFromForm() -> ProviderProfile? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4o-mini" : modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = selectedIndex.flatMap { profiles.indices.contains($0) ? profiles[$0] : nil }
        let profile = ProviderProfile(id: old?.id ?? "draft-\(formContextID.uuidString)", name: name.isEmpty ? "Draft Provider" : name, baseURL: baseURL, model: model, providerID: old?.providerID ?? "draft-provider", keychainService: old?.keychainService ?? keychain.service, keychainAccount: old?.keychainAccount ?? formContextID.uuidString)
        return (try? profile.validated())
    }

    private func apiKeyForModels() -> String? {
        let typed = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        guard let index = selectedIndex, profiles.indices.contains(index) else { return nil }
        let profile = profiles[index]
        return try? KeychainStore(service: profile.keychainService).apiKey(account: profile.keychainAccount)
    }

    private func loadModels() {
        guard let profile = probeProfileFromForm() else { setStatus("请先填写有效的 Base URL"); return }
        guard let apiKey = apiKeyForModels(), !apiKey.isEmpty else { setStatus("请先输入 API Key"); return }
        let generation = modelsRequestGeneration + 1
        modelsRequestGeneration = generation
        let context = formContextID
        let requestedURL = profile.baseURL
        setStatus("正在读取模型列表…")
        probe.testModels(profile: profile, apiKey: apiKey) { [weak self] result in
            guard let self = self, generation == self.modelsRequestGeneration, context == self.formContextID, requestedURL == self.baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            switch result {
            case .failure(let error): self.setStatus("读取模型失败：\(error.localizedDescription)")
            case .success(let response):
                guard response.succeeded else { self.setStatus("读取模型失败：\(response.message)"); return }
                var ids: [String] = []
                for id in response.modelIDs where !ids.contains(id) { ids.append(id) }
                let current = self.modelField.stringValue
                if !current.isEmpty && !ids.contains(current) { ids.append(current) }
                self.modelField.removeAllItems()
                self.modelField.addItems(withObjectValues: ids)
                if !current.isEmpty { self.modelField.stringValue = current }
                else if let first = ids.first { self.modelField.selectItem(withObjectValue: first) }
                self.setStatus("已读取 \(response.modelIDs.count) 个模型，可从下拉框选择")
            }
        }
    }

    @objc private func refreshModels() { loadModels() }

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === baseURLField || field === apiKeyField {
            invalidateModelRequest()
            updateButtons()
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { let cell = NSTableCellView(); let text = NSTextField(labelWithString: profiles[row].name); text.frame = NSRect(x: 8, y: 2, width: 195, height: 20); cell.addSubview(text); return cell }
    public func tableViewSelectionDidChange(_ notification: Notification) { select(index: table.selectedRow) }

    @objc private func newProfile() { table.deselectAll(nil); clearForm(); nameField.becomeFirstResponder(); setStatus("请输入供应商信息并保存") }
    @objc private func importCurrentProfile() {
        setStatus("正在读取当前 Codex 供应商…")
        doctor.currentProfile { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error): self.setStatus("导入失败：\(error.localizedDescription)")
            case .success(nil): self.setStatus("当前使用官方 ChatGPT Provider，无第三方配置可导入")
            case .success(let profile?):
                var profile = profile
                let previous = self.profiles
                let previousIndex = self.selectedIndex
                if let index = self.profiles.firstIndex(where: { $0.providerID == profile.providerID }) {
                    profile.id = self.profiles[index].id
                    self.profiles[index] = profile
                    self.selectedIndex = index
                } else {
                    self.profiles.append(profile)
                    self.selectedIndex = self.profiles.count - 1
                }
                do {
                    try self.store.save(self.profiles)
                    self.table.reloadData()
                    if let index = self.selectedIndex { self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); self.select(index: index) }
                    self.setStatus("已导入当前供应商。出于安全原因，API Key 仍需重新填写。")
                } catch {
                    self.profiles = previous
                    self.selectedIndex = previousIndex
                    self.setStatus("保存导入配置失败：\(error.localizedDescription)")
                }
            }
        }
    }
    @objc private func deleteProfile() {
        guard let index = selectedIndex else { return }
        let alert = NSAlert()
        alert.messageText = "删除供应商资料？"
        alert.informativeText = "只删除本应用保存的供应商资料。为避免破坏当前 Codex，API Key 会保留在钥匙串中。"
        alert.addButton(withTitle: "删除资料")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let previous = profiles
        profiles.remove(at: index)
        do {
            try store.save(profiles)
            table.reloadData(); clearForm()
            setStatus("供应商资料已删除；API Key 仍安全保留在钥匙串中")
        } catch {
            profiles = previous
            setStatus("删除失败：\(error.localizedDescription)")
        }
    }

    @objc private func saveProfile() {
        let old = selectedIndex.flatMap { profiles[$0] }
        let key = apiKeyField.stringValue
        // A replacement key always receives a fresh account. The active Codex config can
        // continue reading the old account until the user explicitly applies this profile.
        let nextKeychainAccount = key.isEmpty ? old?.keychainAccount : UUID().uuidString
        var profile = ProviderProfile(id: old?.id ?? UUID().uuidString,
                                      name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                      baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                      model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                      providerID: old?.providerID,
                                      keychainService: old?.keychainService ?? keychain.service,
                                      keychainAccount: nextKeychainAccount)
        let profileKeychain = KeychainStore(service: profile.keychainService)
        do {
            profile = try profile.validated()
            // 保存供应商资料与保存 API Key 是两个独立动作：允许先保存
            // 名称/Base URL/模型，之后再补填 API Key。
            let previous = profiles
            let previousIndex = selectedIndex
            if let index = selectedIndex { profiles[index] = profile }
            else { profiles.append(profile); selectedIndex = profiles.count - 1 }
            do { try store.save(profiles) }
            catch { profiles = previous; selectedIndex = previousIndex; throw error }
            if !key.isEmpty {
                do { try profileKeychain.setAPIKey(key, account: profile.keychainAccount) }
                catch {
                    profiles = previous; selectedIndex = previousIndex
                    try? store.save(previous)
                    throw error
                }
            }
            table.reloadData()
            if let index = selectedIndex { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            apiKeyField.stringValue = ""
            baseURLField.stringValue = profile.baseURL
            updateButtons()
            setStatus(key.isEmpty ? "供应商资料已保存；请之后填写 API Key" : "已保存：API Key 保存在钥匙串")
        } catch {
            setStatus("保存失败：\(error.localizedDescription)")
        }
    }
    private func currentProfileAndKey() -> (ProviderProfile, String)? {
        guard let i = selectedIndex, profiles.indices.contains(i) else {
            setStatus("请先选择供应商")
            return nil
        }
        let profile = profiles[i]
        // Tests may use an entered key; applying always requires an explicit save.
        let typedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty { return (profile, typedKey) }
        do {
            return (profile, try KeychainStore(service: profile.keychainService).apiKey(account: profile.keychainAccount))
        } catch {
            setStatus("请先输入或保存 Secure API Key")
            return nil
        }
    }
    @objc private func testModels() { loadModels() }
    @objc private func testResponses() {
        guard !modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let p = probeProfileFromForm(), let key = apiKeyForModels() else {
            setStatus("请先填写有效的地址、模型和 API Key")
            return
        }
        let alert = NSAlert()
        alert.messageText = "执行 responses 测试？"
        alert.informativeText = "此请求可能产生费用，将向 \(p.baseURL) 发送测试内容，模型为 \(p.model)。"
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setStatus("正在测试 responses…")
        probe.testResponses(profile: p, apiKey: key) { [weak self] result in
            switch result {
            case .success(let r): self?.setStatus("responses：\(r.message)")
            case .failure(let e): self?.setStatus("responses 测试失败：\(e.localizedDescription)")
            }
        }
    }
    @objc private func applyProvider() {
        if let i = selectedIndex, profiles.indices.contains(i) {
            let saved = profiles[i]
            if nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != saved.name ||
               baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != saved.baseURL ||
               modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != saved.model {
                setStatus("配置已修改，请先点击“保存”再应用供应商")
                return
            }
        }
        if !apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setStatus("请先点击“保存”，将 API Key 安全保存到钥匙串后再应用供应商")
            return
        }
        guard let pair = currentProfileAndKey() else { return }
        confirmSwitch(message: "应用供应商“\(pair.0.name)”？", informative: "这会备份并修改 Codex 配置。切换完成后可选择正常重启 ChatGPT。") { [weak self] in
            self?.doctor.apply(profile: pair.0, apiKey: pair.1) { [weak self] result in self?.handleApplyResult(result) }
        }
    }
    @objc private func restoreOfficial() { confirmSwitch(message: "恢复默认 OpenAI Provider？", informative: "将移除顶层供应商和模型选择，保留供应商定义及其他设置。实际登录方式取决于 Codex 已有认证状态。") { [weak self] in self?.doctor.restoreOfficial { [weak self] result in self?.handleApplyResult(result) } } }
    private func confirmSwitch(message: String, informative: String, action: @escaping () -> Void) { let alert = NSAlert(); alert.messageText = message; alert.informativeText = informative; alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消"); if alert.runModal() == .alertFirstButtonReturn { action() } }
    private func handleApplyResult(_ result: Result<Void, Error>) { switch result { case .failure(let e): setStatus("切换失败：\(e.localizedDescription)"); case .success: setStatus("切换成功。建议让 ChatGPT 正常退出并重新打开（不会强杀进程）。"); let alert = NSAlert(); alert.messageText = "切换完成"; alert.informativeText = "是否请求 ChatGPT 正常重启？"; alert.addButton(withTitle: "正常重启"); alert.addButton(withTitle: "稍后"); if alert.runModal() == .alertFirstButtonReturn, let d = doctor as? CodexDoctor { d.requestNormalRestart { [weak self] r in if case .failure(let e) = r { self?.setStatus("重启失败：\(e.localizedDescription)") } } } } }
}
