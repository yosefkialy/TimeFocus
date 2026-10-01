import FocusCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var confirmDelete = false
    @ViewState private var newExcludedHost = ""

    private func bind<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] }, set: { v in model.updateSettings { $0[keyPath: key] = v } })
    }

    var body: some View {
        Form {
            Section("הרשאות") {
                PermissionRow(title: "נגישות (Accessibility)", detail: "חובה — לקריאת כותרות חלונות, כתובות ותוכן.",
                              granted: model.hasAccessibility,
                              action: { Permissions.promptAccessibility(); Permissions.openSettings(.accessibility) })
                PermissionRow(title: "הקלטת מסך", detail: "רק לזיהוי טקסט (OCR) — אופציונלי.", granted: model.hasScreenRecording,
                              action: { Permissions.requestScreenRecording(); Permissions.openSettings(.screenRecording) })
                PermissionRow(title: "התראות", detail: "לתזכורות חזרה למיקוד.", granted: model.notificationsAuthorized,
                              action: { Permissions.openSettings(.notifications) })
            }

            Section("התערבות כשסוטים מהמיקוד") {
                Picker("רמת הקפדה", selection: bind(\.strictness)) {
                    Text("עדינה").tag(Strictness.gentle)
                    Text("רגילה").tag(Strictness.normal)
                    Text("קפדנית").tag(Strictness.strict)
                }
                let p = model.settings.strictness.profile
                Text("תזכורת אחרי \(Int(p.nudgeAfter)) שנ׳ · האטה מתחילה אחרי \(Int(p.throttleAfter)) שנ׳ · מגיעה למקסימום תוך \(Int(p.rampSeconds / 60)) דק׳")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("תזכורות", selection: bind(\.nudgeStyle)) {
                    Text("חלון צף + התראה").tag(NudgeStyle.both)
                    Text("חלון צף").tag(NudgeStyle.banner)
                    Text("התראת מערכת").tag(NudgeStyle.notification)
                    Text("ללא").tag(NudgeStyle.none)
                }
                Toggle("האטה הדרגתית של היישום המסיח", isOn: bind(\.throttlingEnabled))
                if model.settings.throttlingEnabled {
                    HStack {
                        Text("האטה מקסימלית")
                        Slider(value: bind(\.maxThrottle), in: 0.2...0.95)
                        Text(Fmt.percent(model.settings.maxThrottle)).monospacedDigit().frame(width: 44)
                    }
                    Toggle("גם החשכה הדרגתית של המסך", isOn: bind(\.dimOverlayEnabled))
                }
                Toggle("לשאול אותי על פעילות לא מוכרת", isOn: bind(\.askWhenUncertain))
                Stepper("אורך הפסקה: \(Int(model.settings.breakMinutes)) דק׳", value: bind(\.breakMinutes), in: 1...30)
                Stepper("הפסקות ביום: \(model.settings.maxBreaksPerDay)", value: bind(\.maxBreaksPerDay), in: 0...20)
                Toggle("קיצור לעצירת חירום (⌃⌥⌘.)", isOn: bind(\.emergencyHotkeyEnabled))
                Toggle("תזכורת בוקר לתכנון היום", isOn: bind(\.morningPlanPrompt))
                AppListEditor(title: "יישומים שלעולם לא יואטו", list: bind(\.neverThrottleBundleIDs))
            }

            Section("מעקב") {
                Toggle("מעקב פעיל", isOn: Binding(get: { model.settings.trackingEnabled }, set: { model.setTracking($0) }))
                Toggle("קריאת טקסט מהחלון (Accessibility)", isOn: bind(\.captureAXText))
                Toggle("כתובות אתרים בדפדפנים", isOn: bind(\.captureBrowserURLs))
                Toggle("שימוש ב-AppleScript לכתובות (Chrome/Safari)", isOn: bind(\.useAppleScriptForURLs))
                Toggle("הפעלת נגישות מלאה ביישומי Chromium/Electron", isOn: bind(\.enhanceChromiumAccessibility))
                Toggle("זיהוי טקסט (OCR) באזור התוכן של החלון", isOn: bind(\.enableOCR))
                if model.settings.enableOCR { OCRSettings(interval: bind(\.ocrIntervalSeconds)) }
                Stepper("\"לא ליד המחשב\" אחרי \(Int(model.settings.awayAfterSeconds / 60)) דק׳ ללא קלט", value: bind(\.awayAfterSeconds), in: 60...900, step: 60)
                AppListEditor(title: "יישומים מוחרגים (נרשם רק שם היישום)", list: bind(\.excludedBundleIDs))
                HStack {
                    TextField("אתר מוחרג (למשל mybank.co.il)", text: $newExcludedHost)
                    Button("הוסף") {
                        let h = newExcludedHost.trimmingCharacters(in: .whitespaces).lowercased()
                        if !h.isEmpty { model.updateSettings { $0.excludedHosts.append(h) }; newExcludedHost = "" }
                    }
                }
                ForEach(model.settings.excludedHosts, id: \.self) { h in
                    HStack { Text(h); Spacer(); Button("הסר") { model.updateSettings { $0.excludedHosts.removeAll { $0 == h } } }.buttonStyle(.link) }
                }
            }

            Section("למידה") {
                Stepper("ימי למידה לפני מתן שמות: \(model.settings.minLearningDays)", value: bind(\.minLearningDays), in: 0...14)
                Stepper("שעות שימוש מינימליות: \(Int(model.settings.minLearningHours))", value: bind(\.minLearningHours), in: 0...40)
                Stepper("למידה אחרי \(Int(model.settings.learningIdleMinutes)) דק׳ שהמחשב פנוי", value: bind(\.learningIdleMinutes), in: 2...60)
                Toggle("ללמוד רק כשמחובר לחשמל", isOn: bind(\.learnOnlyOnPower))
                Stepper("שמירת טקסט גולמי: \(model.settings.textRetentionDays) ימים", value: bind(\.textRetentionDays), in: 1...90)
            }

            Section("כללי ופרטיות") {
                Toggle("הפעלה עם הכניסה למחשב", isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                HStack {
                    Text("תיקיית הנתונים")
                    Spacer()
                    Button("הצג ב-Finder") { NSWorkspace.shared.open(AppPaths.default.support) }
                }
                Text("הנתונים נשמרים רק ב-~/Library/Application Support/TimeFocus. שום מידע לא נשלח מהמחשב; הגישה היחידה לרשת היא הורדת מודלים כשאתה לוחץ \"הורד\".")
                    .font(.caption).foregroundStyle(.secondary)
                Button("מחק את כל הנתונים…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("למחוק את כל הנתונים שנאספו?", isPresented: $confirmDelete) {
            Button("מחק הכל", role: .destructive) { model.deleteAllData() }
        } message: {
            Text("המעקב, סוגי הפעילות והמודלים שנלמדו יימחקו. מודלים שהורדו יישארו.")
        }
        .onAppear { model.refreshEnvironment() }
    }
}

/// OCR status: the Screen Recording permission, Hebrew OCR (Tesseract + its Hebrew model) and how often to read.
struct OCRSettings: View {
    @EnvironmentObject var model: AppModel
    @Binding var interval: Double

    var body: some View {
        let ocrModel = ModelCatalog.hebrewOCR
        let progress = model.downloads[ocrModel.id]
        let binary = TesseractOCR.binary()
        let installed = model.isInstalled(ocrModel)
        VStack(alignment: .leading, spacing: 6) {
            if !model.hasScreenRecording {
                Label("נדרשת הרשאת הקלטת מסך (למעלה, ב\"הרשאות\").", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            HStack(alignment: .top) {
                Image(systemName: binary != nil && installed ? "checkmark.circle.fill" : "character.bubble")
                    .foregroundStyle(binary != nil && installed ? Theme.focusGreen : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("עברית (Tesseract)")
                    if binary == nil {
                        Text("ה-OCR של macOS לא קורא עברית. כדי לקרוא עברית צריך את התוכנה החופשית Tesseract — ב-Terminal: brew install tesseract")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if !installed {
                        Text("התוכנה Tesseract מותקנת. חסר מודל העברית שלה (\(Fmt.bytes(ocrModel.approxBytes)), מ-GitHub של Tesseract).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("עברית ואנגלית נקראות יחד: עברית ב-Tesseract, אותיות לטיניות ב-OCR של macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let p = progress, !p.finished { ProgressView(value: p.fraction).frame(maxWidth: 220) }
                    if let e = progress?.error { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Spacer()
                if installed {
                    Button(role: .destructive) { model.deleteModel(ocrModel) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                } else if progress == nil || progress?.finished == true {
                    Button("הורד") { model.download(ocrModel) }
                }
            }
            Stepper("קריאה כל \(Int(interval)) שנ׳ לכל חלון (אם התוכן השתנה)", value: $interval, in: 20...300, step: 10)
            Text("נקרא רק אזור התוכן — בלי לשוניות, סרגל סימניות, תפריטים וסרגלי צד — ושורות שחוזרות כמעט בכל החלונות של אותו יישום או אתר מסוננות. התמונה עצמה לא נשמרת.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 18)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var action: () -> Void
    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Theme.focusGreen : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("אפשר…", action: action) }
        }
    }
}

struct AppListEditor: View {
    let title: String
    @Binding var list: [String]
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup("\(title) (\(list.count))", isExpanded: $expanded) {
            ForEach(list, id: \.self) { bid in
                HStack {
                    AppIconView(bundleID: bid, size: 16)
                    Text(appName(bid)).lineLimit(1)
                    Text(bid).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("הסר") { list.removeAll { $0 == bid } }.buttonStyle(.link)
                }
            }
            Menu("הוסף יישום פתוח") {
                ForEach(runningApps(), id: \.self) { bid in
                    Button(appName(bid)) { if !list.contains(bid) { list.append(bid) } }
                }
            }
            .fixedSize()
        }
    }

    private func appName(_ bid: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid).map { FileManager.default.displayName(atPath: $0.path) } ?? bid
    }

    private func runningApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !list.contains($0) }
            .sorted()
    }
}
