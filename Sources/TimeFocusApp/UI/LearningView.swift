import FocusCore
import SwiftUI

struct LearningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("למידה ומודלים").font(.largeTitle.bold())
                Text("כל הלמידה מתבצעת על המחשב הזה. מודלים כבדים נטענים רק כשהמחשב פנוי ומשוחררים מהזיכרון ברגע שחוזרים לעבוד.")
                    .foregroundStyle(.secondary)
                statusCard
                architectureCard
                embeddingCard
                llmCard
            }
            .padding(20)
        }
        .onAppear { model.refreshEnvironment() }
    }

    private var statusCard: some View {
        let l = model.learning
        return Card(title: "מצב הלמידה", systemImage: "brain") {
            HStack(spacing: 10) {
                StatTile(title: "שלב", value: phaseName(l.phase))
                StatTile(title: "פעילויות שנאספו", value: "\(l.counts.contexts)")
                StatTile(title: "הוטמעו (embeddings)", value: "\(l.counts.embedded)")
                StatTile(title: "תוארו ע״י LLM", value: "\(l.counts.described)")
                StatTile(title: "סווגו", value: "\(l.counts.assigned)")
            }
            HStack(spacing: 10) {
                StatTile(title: "דיוק הרשת (אימות)", value: l.studentAccuracy.map { Fmt.percent(Double($0)) } ?? "—", color: Theme.accent)
                StatTile(title: "התאמה סמנטית", value: l.studentSemanticCosine.map { String(format: "%.2f", $0) } ?? "—")
                StatTile(title: "למידה אחרונה", value: Fmt.relative(l.lastRun))
                StatTile(title: "זיכרון האפליקציה", value: Fmt.bytes(Int64(model.memoryBytes)),
                         subtitle: "מתוך \(Fmt.bytes(Int64(SystemSignals.physicalMemoryBytes)))")
            }
            if l.running {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stageName(l.stage)) \(l.detail)").font(.callout)
                    ProgressView(value: l.progress)
                }
            } else {
                HStack {
                    Text(schedulerText).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.runLearningNow() } label: { Label("למד עכשיו", systemImage: "play.circle") }
                        .help("מריץ את כל שלבי הלמידה מיד, גם אם המחשב בשימוש (צורך זיכרון בזמן הריצה).")
                }
            }
            if let note = l.llmNote { Text("LLM: \(note)").font(.caption).foregroundStyle(.orange) }
            if let o = l.lastOutcome, o != "ok", o != "cancelled" { Text("הריצה האחרונה: \(o)").font(.caption).foregroundStyle(.red) }
        }
    }

    private var schedulerText: String {
        switch model.schedulerState {
        case .running: return "לומד כעת…"
        case .waiting(let reason):
            if reason.hasPrefix("idle") { return "ממתין שהמחשב יהיה פנוי \(Int(model.settings.learningIdleMinutes)) דקות (\(reason.replacingOccurrences(of: "idle ", with: "")))" }
            switch reason {
            case "media playing": return "ממתין — מתנגן וידאו"
            case "on battery": return "ממתין לחיבור לחשמל"
            case "battery low": return "ממתין — סוללה חלשה"
            case "thermal": return "ממתין — המחשב חם"
            case "recently learned": return "למד לאחרונה; הריצה הבאה כשהמחשב יהיה פנוי שוב"
            default: return "ממתין לזמן פנוי"
            }
        }
    }

    private var architectureCard: some View {
        Card(title: "איך זה עובד", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 6) {
                bullet("1", "מעקב: אפליקציה, כותרת חלון, אתר וטקסט גלוי (דרך Accessibility, ובאופן אופציונלי OCR) + קצב הקלדה/גלילה — בלי תוכן הקשות.")
                bullet("2", "רשת \"תלמיד\" קטנה (embedding bag + MLP) מסווגת כל כמה שניות, תוך פחות ממילישנייה, בלי מודל כבד בזיכרון.")
                bullet("3", "כשהמחשב פנוי: טרנספורמר רב-לשוני (multilingual-e5, 118M פרמטרים) יוצר ייצוג סמנטי, ומודל שפה מקומי מתאר כל פעילות באופן מופשט (\"לימודים: אלגברה לינארית\").")
                bullet("4", "אשכול היררכי (average-linkage) + החלקה על גרף המעברים בין חלונות מגלה את סוגי הפעילות; אב-טיפוסים מרובים לכל סוג מאפשרים לו לגדול כשהתוכן משתנה.")
                bullet("5", "הרשת הקטנה לומדת מחדש מהמורה (distillation) ומהתיקונים שלך — כך \"יחידה 5\" של קורס מזוהה כמו \"יחידה 1\", ופרויקט חדש כמו עבודה.")
            }
        }
    }

    private func bullet(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.caption.bold()).frame(width: 18, height: 18).background(Circle().fill(Theme.accent.opacity(0.18)))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var embeddingCard: some View {
        Card(title: "מודל ייצוג סמנטי (Embeddings)", systemImage: "cube.transparent") {
            Text("פעיל: \(model.learning.embeddingModel.isEmpty ? model.settings.embeddingModelID : model.learning.embeddingModel)")
                .font(.callout)
            ForEach(ModelCatalog.embeddingModels) { m in
                ModelRow(model: m, selected: model.settings.embeddingModelID == m.id,
                         onSelect: { model.updateSettings { $0.embeddingModelID = m.id } })
            }
            Text("ללא מודל מותקן, המערכת משתמשת בייצוג hashing פשוט (עובד, אבל פחות חכם).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var llmCard: some View {
        Card(title: "מודל שפה מקומי (LLM) — רק כשהמחשב פנוי", systemImage: "text.bubble") {
            Picker("מנוע", selection: Binding(get: { model.settings.llmBackend }, set: { v in model.updateSettings { $0.llmBackend = v } })) {
                Text("אוטומטי").tag(LLMBackendKind.automatic)
                Text("Apple Intelligence").tag(LLMBackendKind.appleIntelligence)
                Text("llama.cpp (מודל פתוח)").tag(LLMBackendKind.llamaServer)
                Text("שרת מקומי תואם OpenAI").tag(LLMBackendKind.openAICompatible)
                Text("ללא").tag(LLMBackendKind.none)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360)

            HStack(alignment: .top) {
                Image(systemName: model.appleIntelligence.available ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(model.appleIntelligence.available ? Theme.focusGreen : .secondary)
                VStack(alignment: .leading) {
                    Text("Apple Intelligence (על המכשיר)")
                    Text(model.appleIntelligence.available ? "זמין" : model.appleIntelligence.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(alignment: .top) {
                Image(systemName: model.llamaBinary != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(model.llamaBinary != nil ? Theme.focusGreen : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("llama.cpp — מריץ מודלים פתוחים (Gemma, Qwen) על ה-GPU של ה-Mac")
                    if let b = model.llamaBinary {
                        Text(b.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text("לא מותקן. אפשר להתקין מכאן (הורדה רשמית מ-GitHub, ~30MB) או ב-Terminal: brew install llama.cpp")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("התקן את llama.cpp") { model.installLlamaRuntime() }
                            if let p = model.downloads["llama-runtime"] {
                                if let e = p.error { Text(e).font(.caption).foregroundStyle(.red) }
                                else if !p.finished { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }
            }
            ForEach(ModelCatalog.llmModels) { m in
                ModelRow(model: m, selected: model.settings.llmModelFile == m.id,
                         onSelect: { model.updateSettings { $0.llmModelFile = m.id } })
            }
            Divider()
            DisclosureGroup("שרת מקומי תואם OpenAI (Ollama / LM Studio)") {
                TextField("כתובת (רק localhost)", text: Binding(get: { model.settings.openAIBaseURL }, set: { v in model.updateSettings { $0.openAIBaseURL = v } }))
                TextField("שם מודל", text: Binding(get: { model.settings.openAIModel }, set: { v in model.updateSettings { $0.openAIModel = v } }))
                Text("האפליקציה מסרבת לשלוח נתונים לכל כתובת שאינה המחשב הזה.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func phaseName(_ p: LearningPhase) -> String {
        switch p { case .collecting: return "איסוף"; case .naming: return "מתן שמות"; case .active: return "פעיל" }
    }

    private func stageName(_ s: LearningStatus.Stage) -> String {
        switch s {
        case .embedding: return "מחשב ייצוגים סמנטיים"
        case .describing: return "מודל השפה מתאר פעילויות"
        case .clustering: return "מאשכל סוגי פעילות"
        case .naming: return "מציע שמות"
        case .training: return "מאמן את הרשת בזמן אמת"
        default: return ""
        }
    }
}

struct ModelRow: View {
    @EnvironmentObject var app: AppModel
    let model: CatalogModel
    let selected: Bool
    var onSelect: () -> Void

    var body: some View {
        let installed = app.isInstalled(model)
        let progress = app.downloads[model.id]
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Theme.accent : .secondary)
                .onTapGesture(perform: onSelect)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.title).bold()
                    if model.recommended { Text("מומלץ").font(.caption2.bold()).foregroundStyle(Theme.accent) }
                    Text(Fmt.bytes(model.approxBytes)).font(.caption).foregroundStyle(.secondary)
                }
                Text(model.details).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let p = progress, !p.finished {
                    ProgressView(value: p.fraction) { Text("\(Fmt.bytes(p.bytes)) / \(Fmt.bytes(p.total))").font(.caption2) }
                }
                if let e = progress?.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if installed {
                Label("מותקן", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.focusGreen).font(.caption)
                Button(role: .destructive) { app.deleteModel(model) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            } else if progress == nil || progress?.finished == true {
                Button("הורד") { app.download(model) }
            }
        }
        .padding(.vertical, 4)
    }
}
